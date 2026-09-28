"""
Shared logging core for each microservice.

Design goals:
  * Structured JSON, one object per line.
  * Non-blocking: handlers are fed through a QueueHandler and written by a
    single background listener thread, so request handling never waits on I/O.
  * Request/response logging registered once per app -> every HTTP call is
    logged automatically, with no logging inside individual endpoints.
  * Tail support so `GET /logs?lines=N` can serve the log back over HTTP.

This module is intentionally self-contained and copied into each service so
every service stays independently deployable.
"""

import json
import logging
import logging.handlers
import os
import queue
import threading
import time
import traceback
from datetime import datetime, timezone

SERVICE_NAME = os.getenv("SERVICE_NAME", "unknown-service")
LOG_DIR = os.getenv("LOG_DIR", "/var/log/{0}".format(SERVICE_NAME))
LOG_FILE = os.path.join(LOG_DIR, "app.log")

_listener = None


class JsonFormatter(logging.Formatter):
    """Render every record as a single JSON line."""

    def format(self, record):
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "service_name": SERVICE_NAME,
            "event_type": getattr(record, "event_type", "log"),
            "message": record.getMessage(),
        }

        extra = getattr(record, "extra_fields", None)
        if extra:
            payload["extra_fields"] = extra

        if record.exc_info:
            payload["stack_trace"] = "".join(traceback.format_exception(*record.exc_info)).strip()

        return json.dumps(payload, default=str)


def get_logger(name=None):
    """Return the service logger, wiring up async handlers on first call."""
    global _listener

    logger = logging.getLogger(name or SERVICE_NAME)
    if logger.handlers:
        return logger

    logger.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
    # We own formatting/propagation; don't duplicate via the root logger.
    logger.propagate = False

    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        file_handler = logging.FileHandler(LOG_FILE, encoding="utf-8")
    except OSError:
        # Never let a bad log path stop the service from booting.
        file_handler = logging.NullHandler()

    file_handler.setFormatter(JsonFormatter())
    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(JsonFormatter())

    # QueueHandler -> non-blocking emit. The listener owns the real handlers.
    log_queue = queue.Queue(-1)
    queue_handler = logging.handlers.QueueHandler(log_queue)
    queue_handler.setLevel(logging.DEBUG)
    logger.addHandler(queue_handler)

    _listener = logging.handlers.QueueListener(
        log_queue, file_handler, stream_handler, respect_handler_level=True
    )
    _listener.start()

    return logger


def log_event(level, event_type, message, **extra_fields):
    """Emit one structured event. `extra_fields` land in the `extra_fields` key."""
    logger = get_logger()
    logger.log(
        getattr(logging, str(level).upper(), logging.INFO),
        message,
        extra={"event_type": event_type, "extra_fields": extra_fields or None},
    )


def log_exception(event_type, message, **extra_fields):
    """Emit an ERROR event carrying the current exception's stack trace."""
    logger = get_logger()
    logger.error(
        message,
        exc_info=True,
        extra={"event_type": event_type, "extra_fields": extra_fields or None},
    )


def register_request_logging(app):
    """Log every request/response automatically, plus unhandled exceptions."""

    @app.before_request
    def _before():
        from flask import g, request

        g.log_start = time.time()

        # Never let the dashboard's log polling flood the log it is reading.
        if request.path == "/logs":
            return
        log_event(
            "INFO",
            "http_request_received",
            "{0} {1}".format(request.method, request.path),
            method=request.method,
            path=request.path,
            query_string=request.query_string.decode("utf-8", "replace"),
            source_ip=request.headers.get("X-Forwarded-For", request.remote_addr),
            user_agent=request.headers.get("User-Agent"),
        )

    @app.after_request
    def _after(response):
        from flask import g, request

        if request.path == "/logs":
            return response

        duration_ms = round((time.time() - getattr(g, "log_start", time.time())) * 1000, 2)
        level = "INFO" if response.status_code < 500 else "ERROR"
        log_event(
            level,
            "http_request_completed",
            "{0} {1} -> {2}".format(request.method, request.path, response.status_code),
            method=request.method,
            path=request.path,
            status_code=response.status_code,
            duration_ms=duration_ms,
            content_length=response.content_length,
        )
        return response

    @app.teardown_request
    def _teardown(exc):
        from flask import g, request

        if exc is None or request.path == "/logs":
            return
        log_exception(
            "unhandled_exception",
            "Unhandled exception while serving {0} {1}".format(request.method, request.path),
            path=request.path,
        )

    return app


def register_cors(app):
    """Permissive CORS so the browser dashboard can call this service directly."""

    @app.after_request
    def _cors(response):
        response.headers.setdefault("Access-Control-Allow-Origin", "*")
        response.headers.setdefault(
            "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS"
        )
        response.headers.setdefault(
            "Access-Control-Allow-Headers", "Content-Type, Authorization"
        )
        response.headers.setdefault("Access-Control-Max-Age", "600")
        return response

    return app


def read_recent_lines(lines=100, max_bytes=1024 * 1024):
    """
    Return the last `lines` log lines, reading only the tail of the file.

    Works on a file that is being appended to by the listener thread, and does
    not load the whole log into memory. Entries are returned as parsed JSON
    when possible, raw strings otherwise (e.g. for partially written lines).
    """
    lines = max(0, int(lines or 0))
    if lines == 0 or not os.path.exists(LOG_FILE):
        return []

    try:
        with open(LOG_FILE, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            position = handle.tell()
            buffer = b""
            block_size = 8192

            # Walk backwards until we have enough newlines or hit the start.
            while position > 0 and buffer.count(b"\n") <= lines and len(buffer) < max_bytes:
                step = min(block_size, position)
                position -= step
                handle.seek(position)
                buffer = handle.read(step) + buffer

        raw_lines = buffer.split(b"\n")[-lines:]
    except OSError:
        return []

    entries = []
    for raw in raw_lines:
        text = raw.decode("utf-8", "replace").strip()
        if not text:
            continue
        try:
            entries.append(json.loads(text))
        except json.JSONDecodeError:
            # Torn write at the tail, or output from a non-JSON handler.
            entries.append({"level": "RAW", "message": text})
    return entries
