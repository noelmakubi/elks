# syntax=docker/dockerfile:1
# service-c - notifications (polls service-b)
#
# Multi-stage: wheels are built once, then only the virtualenv is copied into a
# slim runtime. Runs as a non-root user; the log directory is created up front so
# a bind mount from the host is writable by the same uid/gid.

FROM python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /wheels
COPY requirements.txt ./
RUN pip wheel --wheel-dir /wheels -r requirements.txt


FROM python:3.12-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    SERVICE_NAME=service-c \
    LOG_DIR=/var/log/service-c \
    PORT=5003 \
    GUNICORN_WORKERS=1 \
    GUNICORN_THREADS=8 \
    GUNICORN_TIMEOUT=60 \
    GUNICORN_GRACEFUL_TIMEOUT=30

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /wheels /wheels
COPY requirements.txt ./
RUN pip install --no-cache-dir --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels

RUN groupadd --gid 1000 app \
    && useradd --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin app \
    && mkdir -p "$LOG_DIR" \
    && chown -R 1000:1000 "$LOG_DIR" /app

COPY --chown=1000:1000 logging_utils.py app.py ./

USER 1000:1000

EXPOSE 5003

# Single worker on purpose: the poller thread is started at import time. More than
# one worker means more than one poller, which would duplicate work and rely on
# processed_orders to keep it idempotent.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS "http://localhost:${PORT}/health" || exit 1

CMD ["sh", "-c", "exec gunicorn \
     --bind 0.0.0.0:${PORT:-5003} \
     --workers ${GUNICORN_WORKERS:-1} \
     --threads ${GUNICORN_THREADS:-8} \
     --timeout ${GUNICORN_TIMEOUT:-60} \
     --graceful-timeout ${GUNICORN_GRACEFUL_TIMEOUT:-30} \
     --access-logfile - \
     --error-logfile - \
     --capture-output \
     app:app"]
