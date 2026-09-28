"""service-b - Orders service (owns its own PostgreSQL database)."""

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

DB_HOST = os.getenv("DB_HOST", "service-b-db")
DB_NAME = os.getenv("DB_NAME", "service_b")
DB_USER = os.getenv("DB_USER", "service_b_user")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

SERVICE_A_URL = os.getenv("SERVICE_A_URL", "http://service-a:5001")
SERVICE_A_TIMEOUT = float(os.getenv("SERVICE_A_TIMEOUT", "3"))
# When false (default) service-b still accepts orders if service-a is
# unreachable, which keeps this service independently deployable.
REQUIRE_USER_VALIDATION = os.getenv("REQUIRE_USER_VALIDATION", "false").lower() == "true"

_db_lock = threading.Lock()
_db_ready = False

CREATE_TABLE_SQL = """
    CREATE TABLE IF NOT EXISTS orders (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL,
        item VARCHAR(255) NOT NULL,
        quantity INTEGER NOT NULL DEFAULT 1,
        status VARCHAR(32) NOT NULL DEFAULT 'created',
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
"""


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
                    cur.execute(CREATE_TABLE_SQL)
                conn.commit()
                log_event(
                    "INFO",
                    "db_schema_ready",
                    "Table 'orders' is ready",
                    table="orders",
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


def run_query(sql, params=None, fetch=False, one=False, retries=3):
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
            table="orders",
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
            table="orders",
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


def validate_user_via_service_a(user_id):
    """
    Outgoing inter-service call to service-a. Returns (ok, detail).
    Never raises, so a dependency outage degrades rather than crashes us.
    """
    url = "{0}/users/{1}".format(SERVICE_A_URL.rstrip("/"), user_id)
    started = time.time()
    log_event(
        "INFO",
        "outgoing_request",
        "Calling service-a to validate user",
        target_service="service-a",
        url=url,
        method="GET",
        payload_summary={"user_id": user_id},
    )
    try:
        response = requests.get(url, timeout=SERVICE_A_TIMEOUT)
        duration_ms = round((time.time() - started) * 1000, 2)
        log_event(
            "INFO" if response.ok else "WARNING",
            "outgoing_response",
            "service-a responded {0}".format(response.status_code),
            target_service="service-a",
            status_code=response.status_code,
            duration_ms=duration_ms,
        )
        if response.status_code == 404:
            return False, "user {0} does not exist in service-a".format(user_id)
        if not response.ok:
            return False, "service-a returned {0}".format(response.status_code)
        return True, response.json()
    except requests.RequestException as exc:
        log_event(
            "WARNING",
            "outgoing_request_failed",
            "Could not reach service-a: {0}".format(exc),
            target_service="service-a",
            url=url,
            duration_ms=round((time.time() - started) * 1000, 2),
        )
        return False, "service-a unreachable: {0}".format(exc)


@app.route("/health", methods=["GET"])
def health():
    return (
        jsonify(
            {
                "status": "ok" if is_db_ready() else "degraded",
                "service": "service-b",
                "database": "ready" if is_db_ready() else "connecting",
                "depends_on": SERVICE_A_URL,
                "port": 5002,
            }
        ),
        200,
    )


@app.route("/orders", methods=["GET"])
def list_orders():
    try:
        rows = run_query(
            "SELECT id, user_id, item, quantity, status, created_at "
            "FROM orders ORDER BY id DESC;",
            fetch=True,
        )
        return jsonify([dict(row) for row in rows]), 200
    except Exception:
        return jsonify({"error": "database unavailable"}), 503


@app.route("/orders", methods=["POST"])
def create_order():
    data = request.get_json(silent=True) or {}
    user_id = data.get("user_id")
    item = (data.get("item") or "").strip()
    quantity = data.get("quantity", 1)

    if user_id is None or not item:
        log_event(
            "WARNING",
            "validation_error",
            "Rejected order creation: 'user_id' and 'item' are required",
            provided_fields=sorted(data.keys()),
        )
        return jsonify({"error": "'user_id' and 'item' are required"}), 400

    try:
        user_id = int(user_id)
        quantity = max(1, int(quantity))
    except (TypeError, ValueError):
        return jsonify({"error": "'user_id' and 'quantity' must be integers"}), 400

    # Loosely coupled: validate against service-a, but do not hard-fail if it
    # is down unless REQUIRE_USER_VALIDATION is explicitly enabled.
    valid, detail = validate_user_via_service_a(user_id)
    if not valid:
        if REQUIRE_USER_VALIDATION:
            log_event(
                "WARNING",
                "order_rejected",
                "Rejecting order, user validation failed: {0}".format(detail),
                user_id=user_id,
            )
            return jsonify({"error": detail}), 400
        log_event(
            "WARNING",
            "user_validation_skipped",
            "Proceeding without user validation: {0}".format(detail),
            user_id=user_id,
            strict_mode=False,
        )

    try:
        row = run_query(
            "INSERT INTO orders (user_id, item, quantity) "
            "VALUES (%s, %s, %s) RETURNING id, user_id, item, quantity, status, created_at;",
            (user_id, item, quantity),
            fetch=True,
            one=True,
        )
        order = dict(row)
        log_event(
            "INFO",
            "order_created",
            "Created order {0}".format(order["id"]),
            order_id=order["id"],
            user_id=user_id,
            item=item,
            user_validated=valid,
        )
        return jsonify(order), 201
    except Exception:
        return jsonify({"error": "database unavailable"}), 503


@app.route("/orders/<int:order_id>", methods=["GET"])
def get_order(order_id):
    try:
        row = run_query(
            "SELECT id, user_id, item, quantity, status, created_at "
            "FROM orders WHERE id = %s;",
            (order_id,),
            fetch=True,
            one=True,
        )
    except Exception:
        return jsonify({"error": "database unavailable"}), 503

    if row is None:
        log_event("WARNING", "order_not_found", "No order {0}".format(order_id), order_id=order_id)
        return jsonify({"error": "order not found"}), 404
    return jsonify(dict(row)), 200


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
                "service": "service-b",
                "file": "/var/log/service-b/app.log",
                "count": len(entries := read_recent_lines(lines)),
                "entries": entries,
            }
        ),
        200,
    )


if __name__ == "__main__":
    log_event(
        "INFO",
        "service_startup",
        "service-b starting up",
        port=5002,
        db_host=DB_HOST,
        service_a_url=SERVICE_A_URL,
        require_user_validation=REQUIRE_USER_VALIDATION,
    )
    threading.Thread(target=init_db, name="db-init", daemon=True).start()
    app.run(host="0.0.0.0", port=5002, threaded=True)
