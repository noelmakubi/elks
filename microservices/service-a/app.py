"""service-a - User management service (owns its own PostgreSQL database)."""

import os
import threading
import time

import psycopg2
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

DB_HOST = os.getenv("DB_HOST", "service-a-db")
DB_NAME = os.getenv("DB_NAME", "service_a")
DB_USER = os.getenv("DB_USER", "service_a_user")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

_db_lock = threading.Lock()
_db_ready = False

CREATE_TABLE_SQL = """
    CREATE TABLE IF NOT EXISTS users (
        id SERIAL PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        email VARCHAR(255) UNIQUE NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
"""


def db_connect(retries=1, delay=1.0):
    """Open a connection, retrying a configurable number of times."""
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
    """
    Create the schema. Runs in a background thread with unbounded retries so
    service-a can boot even if its database is not ready yet.
    """
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
                duration_ms = round((time.time() - started) * 1000, 2)
                log_event(
                    "INFO",
                    "db_schema_ready",
                    "Table 'users' is ready",
                    table="users",
                    operation="CREATE TABLE IF NOT EXISTS",
                    duration_ms=duration_ms,
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
    """
    Execute a statement with connection handling, retry and timing, logging
    every database operation (type, table, outcome, duration).
    """
    started = time.time()
    conn = None
    try:
        conn = db_connect(retries=retries)
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(sql, params or ())
            if fetch:
                rows = cur.fetchall() if not one else cur.fetchone()
                if one and rows is None:
                    rows = None
        conn.commit()
        duration_ms = round((time.time() - started) * 1000, 2)
        log_event(
            "INFO",
            "db_query",
            sql.strip().split()[0].upper() + " succeeded",
            table="users",
            operation=sql.strip().split()[0].upper(),
            duration_ms=duration_ms,
            row_count=(len(rows) if fetch and not one else (1 if rows else 0)) if fetch else None,
        )
        return rows
    except Exception as exc:
        if conn is not None:
            try:
                conn.rollback()
            except psycopg2.Error:
                pass
        duration_ms = round((time.time() - started) * 1000, 2)
        log_exception(
            "db_query_failed",
            "Query failed: {0}".format(exc),
            table="users",
            operation=sql.strip().split()[0].upper(),
            duration_ms=duration_ms,
        )
        raise
    finally:
        if conn is not None:
            try:
                conn.close()
            except psycopg2.Error:
                pass


@app.route("/health", methods=["GET"])
def health():
    # Always 200 so this service can be considered ready independently of its DB.
    return (
        jsonify(
            {
                "status": "ok" if is_db_ready() else "degraded",
                "service": "service-a",
                "database": "ready" if is_db_ready() else "connecting",
                "port": 5001,
            }
        ),
        200,
    )


@app.route("/users", methods=["GET"])
def list_users():
    try:
        rows = run_query(
            "SELECT id, name, email, created_at FROM users ORDER BY id DESC;",
            fetch=True,
        )
        return jsonify([dict(row) for row in rows]), 200
    except Exception:
        return jsonify({"error": "database unavailable"}), 503


@app.route("/users", methods=["POST"])
def create_user():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    email = (data.get("email") or "").strip()

    if not name or not email:
        log_event(
            "WARNING",
            "validation_error",
            "Rejected user creation: 'name' and 'email' are required",
            provided_fields=sorted(data.keys()),
        )
        return jsonify({"error": "'name' and 'email' are required"}), 400

    try:
        row = run_query(
            "INSERT INTO users (name, email) VALUES (%s, %s) RETURNING id, name, email;",
            (name, email),
            fetch=True,
            one=True,
        )
        user = dict(row)
        log_event(
            "INFO",
            "user_created",
            "Created user {0}".format(user["id"]),
            user_id=user["id"],
            email=email,
        )
        return jsonify(user), 201
    except psycopg2.errors.UniqueViolation:
        log_event("WARNING", "user_duplicate", "Duplicate email: " + email, email=email)
        return jsonify({"error": "email already exists"}), 409
    except Exception:
        return jsonify({"error": "database unavailable"}), 503


@app.route("/users/<int:user_id>", methods=["GET"])
def get_user(user_id):
    try:
        row = run_query(
            "SELECT id, name, email, created_at FROM users WHERE id = %s;",
            (user_id,),
            fetch=True,
            one=True,
        )
    except Exception:
        return jsonify({"error": "database unavailable"}), 503

    if row is None:
        log_event("WARNING", "user_not_found", "No user with id {0}".format(user_id), user_id=user_id)
        return jsonify({"error": "user not found"}), 404
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
                "service": "service-a",
                "file": "/var/log/service-a/app.log",
                "count": len(entries := read_recent_lines(lines)),
                "entries": entries,
            }
        ),
        200,
    )


def start_background_tasks():
    """
    Start the schema-init thread.

    Called at import time, not under `if __name__ == "__main__"`, because the
    production entrypoint is gunicorn (`app:app`) and that block would never
    run. Guarded so a second import in the same process cannot double-start it.
    """
    global _tasks_started
    if _tasks_started:
        return
    _tasks_started = True

    log_event(
        "INFO",
        "service_startup",
        "service-a starting up",
        port=os.getenv("PORT", "5001"),
        db_host=DB_HOST,
        log_level=os.getenv("LOG_LEVEL", "INFO"),
    )
    threading.Thread(target=init_db, name="db-init", daemon=True).start()


_tasks_started = False
start_background_tasks()

if __name__ == "__main__":
    # Local development only; production runs gunicorn from the Dockerfile.
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "5001")), threaded=True)
