"""service-c - Notifications service (owns its own PostgreSQL database)."""

import os
import threading
import time

import psycopg2
import requests
from psycopg2.extras import RealDictCursor
from flask import Flask, jsonify, request

from logging_utils import (
    log_event,
    log_exception,
    read_recent_lines,
    register_cors,
    register_request_logging,
)

app = Flask(__name__)
register_request_logging(app)
register_cors(app)

DB_HOST = os.getenv("DB_HOST", "service-c-db")
DB_NAME = os.getenv("DB_NAME", "service_c")
DB_USER = os.getenv("DB_USER", "service_c_user")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

SERVICE_B_URL = os.getenv("SERVICE_B_URL", "http://service-b:5002")
SERVICE_B_TIMEOUT = float(os.getenv("SERVICE_B_TIMEOUT", "3"))
POLL_INTERVAL_SECONDS = int(os.getenv("POLL_INTERVAL_SECONDS", "15"))

_db_lock = threading.Lock()
_db_ready = False
_stop_poller = threading.Event()

CREATE_TABLES_SQL = [
    """
    CREATE TABLE IF NOT EXISTS notifications (
        id SERIAL PRIMARY KEY,
        order_id INTEGER NOT NULL UNIQUE,
        user_id INTEGER,
        message TEXT NOT NULL,
        status VARCHAR(32) NOT NULL DEFAULT 'unread',
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    """,
    """
    CREATE TABLE IF NOT EXISTS processed_orders (
        order_id INTEGER PRIMARY KEY,
        processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    """,
]


def db_connect(retries=1, delay=1.0):
    last_error = None
    for attempt in range(1, retries + 1):
        try:
            conn = psycopg2.connect(
                host=DB_HOST,
                port=os.getenv("DB_PORT", "5432"),
                dbname=DB_NAME,
                user=DB_USER,
                password=DB_PASSWORD,
                connect_timeout=5,
            )
            log_event(
                "INFO",
                "db_connection_established",
                "Opened database connection",
                host=DB_HOST,
                database=DB_NAME,
                attempt=attempt,
            )
            return conn
        except psycopg2.Error as exc:
            last_error = exc
            log_event(
                "WARNING",
                "db_connection_retry",
                "Database connection attempt failed: {0}".format(exc),
                host=DB_HOST,
                attempt=attempt,
                max_attempts=retries,
            )
            if attempt < retries:
                time.sleep(delay)
    raise last_error


def init_db():
    """Create the schema, retrying forever so boot never depends on the DB."""
    global _db_ready
    attempt = 0
    while True:
        attempt += 1
        started = time.time()
        try:
            conn = db_connect()
            try:
                with conn.cursor() as cur:
                    for statement in CREATE_TABLES_SQL:
                        cur.execute(statement)
                conn.commit()
                log_event(
                    "INFO",
                    "db_schema_ready",
                    "Tables 'notifications' and 'processed_orders' are ready",
                    tables=["notifications", "processed_orders"],
                    operation="CREATE TABLE IF NOT EXISTS",
                    duration_ms=round((time.time() - started) * 1000, 2),
                    attempt=attempt,
                )
            finally:
                conn.close()
            with _db_lock:
                _db_ready = True
            return True
        except Exception as exc:
            log_event(
                "WARNING",
                "db_init_retry",
                "Database not ready yet, will retry: {0}".format(exc),
                attempt=attempt,
            )
            time.sleep(3)


def is_db_ready():
    with _db_lock:
        return _db_ready


def run_query(sql, params=None, fetch=False, one=False, retries=3, table="notifications"):
    started = time.time()
    conn = None
    try:
        conn = db_connect(retries=retries)
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(sql, params or ())
            rows = None
            if fetch:
                rows = cur.fetchone() if one else cur.fetchall()
        conn.commit()
        log_event(
            "INFO",
            "db_query",
            sql.strip().split()[0].upper() + " succeeded",
            table=table,
            operation=sql.strip().split()[0].upper(),
            duration_ms=round((time.time() - started) * 1000, 2),
            row_count=(len(rows) if fetch and not one else (1 if rows else 0)) if fetch else None,
        )
        return rows
    except Exception as exc:
        if conn is not None:
            try:
                conn.rollback()
            except psycopg2.Error:
                pass
        log_exception(
            "db_query_failed",
            "Query failed: {0}".format(exc),
            table=table,
            operation=sql.strip().split()[0].upper(),
            duration_ms=round((time.time() - started) * 1000, 2),
        )
        raise
    finally:
        if conn is not None:
            try:
                conn.close()
            except psycopg2.Error:
                pass


def fetch_orders_from_service_b():
    """Outgoing inter-service call. Returns (ok, orders)."""
    url = "{0}/orders".format(SERVICE_B_URL.rstrip("/"))
    started = time.time()
    log_event(
        "INFO",
        "outgoing_request",
        "Calling service-b to look for new orders",
        target_service="service-b",
        url=url,
        method="GET",
    )
    try:
        response = requests.get(url, timeout=SERVICE_B_TIMEOUT)
        duration_ms = round((time.time() - started) * 1000, 2)
        log_event(
            "INFO" if response.ok else "WARNING",
            "outgoing_response",
            "service-b responded {0}".format(response.status_code),
            target_service="service-b",
            status_code=response.status_code,
            duration_ms=duration_ms,
        )
        if not response.ok:
            return False, []
        return True, response.json()
    except (requests.RequestException, ValueError) as exc:
        log_event(
            "WARNING",
            "outgoing_request_failed",
            "Could not reach service-b: {0}".format(exc),
            target_service="service-b",
            url=url,
            duration_ms=round((time.time() - started) * 1000, 2),
        )
        return False, []


def create_notification_for_order(order):
    """Persist one notification per order, ignoring orders already handled."""
    order_id = order.get("id")
    message = "Order #{0} for user {1} ({2} x{3}) was created.".format(
        order_id, order.get("user_id"), order.get("item"), order.get("quantity", 1)
    )
    try:
        row = run_query(
            "INSERT INTO notifications (order_id, user_id, message) "
            "VALUES (%s, %s, %s) "
            "ON CONFLICT (order_id) DO NOTHING "
            "RETURNING id, order_id, user_id, message, status, created_at;",
            (order_id, order.get("user_id"), message),
            fetch=True,
            one=True,
        )
    except Exception:
        return None

    if row is None:
        log_event("DEBUG", "notification_skipped", "Order {0} already notified".format(order_id),
                  order_id=order_id)
        return None

    run_query(
        "INSERT INTO processed_orders (order_id) VALUES (%s) ON CONFLICT DO NOTHING;",
        (order_id,),
        table="processed_orders",
    )
    log_event(
        "INFO",
        "notification_created",
        "Created notification {0} for order {1}".format(row["id"], order_id),
        notification_id=row["id"],
        order_id=order_id,
        user_id=order.get("user_id"),
    )
    return dict(row)


def poll_service_b_forever():
    """Background task: poll service-b and notify on each new order."""
    log_event(
        "INFO",
        "background_task_started",
        "Order poller started",
        target_service="service-b",
        interval_seconds=POLL_INTERVAL_SECONDS,
    )
    # Wait for our own schema to exist before touching the notifications table.
    while not is_db_ready() and not _stop_poller.is_set():
        _stop_poller.wait(1)
    if _stop_poller.is_set():
        return

    while not _stop_poller.is_set():
        cycle_started = time.time()
        log_event("DEBUG", "background_task_cycle", "Polling service-b for new orders")
        try:
            ok, orders = fetch_orders_from_service_b()
            created = 0
            if ok:
                for order in orders or []:
                    if create_notification_for_order(order) is not None:
                        created += 1
            log_event(
                "INFO",
                "background_task_completed",
                "Poll cycle finished: {0} new notification(s)".format(created),
                orders_seen=len(orders or []) if ok else 0,
                notifications_created=created,
                duration_ms=round((time.time() - cycle_started) * 1000, 2),
            )
        except Exception:
            log_exception("background_task_failed", "Poll cycle raised an unexpected error")

        _stop_poller.wait(POLL_INTERVAL_SECONDS)

    log_event("INFO", "background_task_stopped", "Order poller stopped")


@app.route("/health", methods=["GET"])
def health():
    return (
        jsonify(
            {
                "status": "ok" if is_db_ready() else "degraded",
                "service": "service-c",
                "database": "ready" if is_db_ready() else "connecting",
                "depends_on": SERVICE_B_URL,
                "poll_interval_seconds": POLL_INTERVAL_SECONDS,
                "port": 5003,
            }
        ),
        200,
    )


@app.route("/notifications", methods=["GET"])
def list_notifications():
    try:
        rows = run_query(
            "SELECT id, order_id, user_id, message, status, created_at "
            "FROM notifications ORDER BY id DESC LIMIT 200;",
            fetch=True,
        )
        return jsonify([dict(row) for row in rows]), 200
    except Exception:
        return jsonify({"error": "database unavailable"}), 503


@app.route("/notifications", methods=["POST"])
def create_notification():
    """Manual notification, useful for testing the dashboard without orders."""
    data = request.get_json(silent=True) or {}
    message = (data.get("message") or "").strip()
    if not message:
        return jsonify({"error": "'message' is required"}), 400
    try:
        row = run_query(
            "INSERT INTO notifications (order_id, user_id, message) "
            "VALUES (%s, %s, %s) "
            "RETURNING id, order_id, user_id, message, status, created_at;",
            (data.get("order_id"), data.get("user_id"), message),
            fetch=True,
            one=True,
        )
        return jsonify(dict(row)), 201
    except Exception:
        return jsonify({"error": "database unavailable"}), 503


@app.route("/logs", methods=["GET"])
def logs():
    lines = request.args.get("lines", 100)
    try:
        lines = max(0, min(int(lines), 5000))
    except (TypeError, ValueError):
        lines = 100
    return (
        jsonify(
            {
                "service": "service-c",
                "file": "/var/log/service-c/app.log",
                "count": len(entries := read_recent_lines(lines)),
                "entries": entries,
            }
        ),
        200,
    )


def start_background_tasks():
    """
    Start the schema-init thread and the service-b poller.

    Called at import time, not under `if __name__ == "__main__"`, because the
    production entrypoint is gunicorn (`app:app`) and that block would never
    run. Two guards matter here:
      * _tasks_started stops a repeat import from starting a second poller in
        the same process.
      * run with a single gunicorn worker, as the Dockerfile does. A second
        worker is a second process and would poll independently.
    processed_orders keeps duplicate notifications out of the database even so.
    """
    global _tasks_started
    if _tasks_started:
        return
    _tasks_started = True

    log_event(
        "INFO",
        "service_startup",
        "service-c starting up",
        port=os.getenv("PORT", "5003"),
        db_host=DB_HOST,
        service_b_url=SERVICE_B_URL,
        poll_interval_seconds=POLL_INTERVAL_SECONDS,
    )
    threading.Thread(target=init_db, name="db-init", daemon=True).start()
    threading.Thread(target=poll_service_b_forever, name="poller", daemon=True).start()


_tasks_started = False
start_background_tasks()

if __name__ == "__main__":
    # Local development only; production runs gunicorn from the Dockerfile.
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "5003")), threaded=True)
