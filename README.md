# Microservices with Database-per-Service + Live Dashboard

Three independently deployable Python/Flask microservices, each with its **own**
PostgreSQL container, its **own** log directory inside its own project folder, and
a static browser dashboard that talks to all three directly.

| Service | Purpose | Host port | Database | Own logs |
| --- | --- | --- | --- | --- |
| `service-a` | User management | 5001 | `service-a-db` (`service_a`) | `service-a/logs/app.log` |
| `service-b` | Orders | 5002 | `service-b-db` (`service_b`) | `service-b/logs/app.log` |
| `service-c` | Notifications | 5003 | `service-c-db` (`service_c`) | `service-c/logs/app.log` |
| `ui` | Static dashboard (nginx) | 8080 | – | – |

## Architecture

```
              browser
                 |
            :8080 ui (nginx)
        _________|___________
       |         |         |
   :5001     :5002     :5003
 service-a  service-b  service-c
     |           |         |
 service-a-db  ...     service-c-db
                 ^
                 |  background poll (every 15s)
          service-b --(REST)--> service-a
                  validate user_id on order create
```

* **Database-per-Service.** No service can read another service's tables. Each
  Postgres runs in its own container with its own credentials and volume.
* **Loosely coupled.** Every service boots and answers `/health` on its own.
  Inter-service calls are best-effort REST over the compose network, guarded by
  timeouts. A dependency being down degrades behaviour and logs a warning; it
  never prevents startup or crashes the caller.

## Quick start

```bash
cp .env.example .env      # then edit the three DB passwords
docker compose up -d --build
docker compose ps
```

Open <http://localhost:8080>.

Tear down (add `-v` to also delete the database volumes):

```bash
docker compose down
```

## Endpoints

### service-a — users (port 5001)

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/health` | Always `200`; `status` is `ok` or `degraded` if the DB is still connecting |
| GET | `/users` | List users |
| POST | `/users` | `{"name": "...", "email": "..."}` → `201`; `400` if missing, `409` on duplicate email |
| GET | `/users/<id>` | Single user, `404` if unknown |
| GET | `/logs?lines=N` | Last N log lines as JSON |

### service-b — orders (port 5002)

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/health` | Always `200` |
| GET | `/orders` | List orders |
| POST | `/orders` | `{"user_id": 1, "item": "widget", "quantity": 2}` → `201`; `400` if `user_id`/`item` missing |
| GET | `/orders/<id>` | Single order, `404` if unknown |
| GET | `/logs?lines=N` | Last N log lines as JSON |

`POST /orders` calls `GET /users/<id>` on service-a to validate `user_id`. If
service-a is unreachable the order is still accepted and a `user_validation_skipped`
warning is logged — set `REQUIRE_USER_VALIDATION=true` in `.env` to reject instead.

### service-c — notifications (port 5003)

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/health` | Always `200` |
| GET | `/notifications` | List notifications |
| POST | `/notifications` | `{"message": "..."}` — manual entry, handy for testing the UI |
| GET | `/logs?lines=N` | Last N log lines as JSON |

A background thread polls service-b every `POLL_INTERVAL_SECONDS` (default 15) and
creates one notification per new order. `processed_orders` makes this idempotent, so
restarts do not produce duplicates. The poller waits for its own schema before it
starts and keeps retrying while service-b is down.

### Trying it with curl

```bash
curl -X POST localhost:5001/users -H 'Content-Type: application/json' \
     -d '{"name":"Ada","email":"ada@example.com"}'

curl -X POST localhost:5002/orders -H 'Content-Type: application/json' \
     -d '{"user_id":1,"item":"keyboard","quantity":1}'

# wait one poll interval, then:
curl localhost:5003/notifications

curl "localhost:5001/logs?lines=20"
```

## Logging

Each service writes structured JSON, one object per line, to **its own** log file,
bind-mounted from the host so the file lives inside the service's project folder:

```
service-a/logs/app.log
service-b/logs/app.log
service-c/logs/app.log
```

```json
{
  "timestamp": "2026-09-28T04:14:43.71+00:00",
  "level": "INFO",
  "service_name": "service-a",
  "event_type": "http_request_completed",
  "message": "GET /users -> 200",
  "extra_fields": {
    "method": "GET", "path": "/users", "status_code": 200, "duration_ms": 0.94
  }
}
```

What is captured, all via `register_request_logging` / `register_cors` in
`logging_utils.py` so no endpoint needs manual logging calls:

* **Every HTTP request and response** — method, path, query string, source IP,
  user agent, status code, response time, response size.
* **Outgoing inter-service calls** — target service, URL, payload summary,
  response status, duration (`outgoing_request` / `outgoing_response` /
  `outgoing_request_failed`).
* **Every database operation** — statement type, table, outcome, row count, duration.
* **Lifecycle** — startup, schema creation, connection established, retries.
* **Errors and warnings** with full stack traces.
* **Background tasks** — poller start, each cycle, result, duration, stop.
* **Unhandled exceptions** per request.

Details:

* Writes are non-blocking: records go through a `QueueHandler` and a single
  background listener thread owns the file handles, so logging never stalls a request.
* Set `LOG_LEVEL=DEBUG` in `.env` to include per-cycle debug events.
* Logs also stream to stdout, so `docker compose logs -f service-a` works.
* `GET /logs?lines=N` reads only the tail of the file (capped at 1 MiB) and is
  excluded from request logging, so polling the log viewer cannot feed itself.
* **No in-app rotation.** The app appends only. Rotate on the host with logrotate,
  e.g. for `service-a/logs/app.log`:
  ```
  /path/to/microservices/service-a/logs/app.log {
      daily
      rotate 14
      compress
      delaycompress
      missingok
      notifempty
      copytruncate
  }
  ```
  `copytruncate` suits this design because it keeps the file the container holds open.

## Configuration

All configuration is environment variables; no secrets are hardcoded.
`docker-compose.yml` requires `SERVICE_A_DB_PASSWORD`, `SERVICE_B_DB_PASSWORD` and
`SERVICE_C_DB_PASSWORD` and fails fast with a clear message if they are unset.

| Variable | Default | Used by |
| --- | --- | --- |
| `LOG_LEVEL` | `INFO` | all services |
| `SERVICE_A_DB_NAME` / `_USER` / `_PASSWORD` | `service_a` / `service_a_user` / **required** | service-a + its DB |
| `SERVICE_B_DB_NAME` / `_USER` / `_PASSWORD` | `service_b` / `service_b_user` / **required** | service-b + its DB |
| `SERVICE_C_DB_NAME` / `_USER` / `_PASSWORD` | `service_c` / `service_c_user` / **required** | service-c + its DB |
| `REQUIRE_USER_VALIDATION` | `false` | service-b |
| `POLL_INTERVAL_SECONDS` | `15` | service-c |
| `SERVICE_A_URL` | `http://service-a:5001` | service-b (set in compose) |
| `SERVICE_B_URL` | `http://service-b:5002` | service-c (set in compose) |
| `LOG_DIR` | `/var/log/<service>` | all services (set in compose) |

`.env` is gitignored; `.env.example` is committed.

## Running one service on its own

Each service is standalone — its own Dockerfile, its own code, its own database:

```bash
cd service-a
docker build -t service-a .
docker run -d -p 5001:5001 \
  -e DB_HOST=host.docker.internal -e DB_NAME=service_a \
  -e DB_USER=service_a_user -e DB_PASSWORD=secret \
  -v "$(pwd)/logs:/var/log/service-a" \
  service-a
```

Swap in `service-b` (with `SERVICE_A_URL` set) or `service-c` (with `SERVICE_B_URL`
and `POLL_INTERVAL_SECONDS`) as needed. To run one service from compose:

```bash
docker compose up -d --build service-a service-a-db
```

## Dashboard

`ui/` is plain HTML/CSS/JS — no build step, no Node. nginx serves it; the browser
calls each service's API directly, which is why CORS is enabled on all three.

If your services are on different host ports, edit the `baseUrl` values in
`ui/config.js` and rebuild the UI.

## Project layout

```
.
├── docker-compose.yml
├── .env.example
├── service-a/   app.py  logging_utils.py  Dockerfile  requirements.txt  logs/app.log
├── service-b/   app.py  logging_utils.py  Dockerfile  requirements.txt  logs/app.log
├── service-c/   app.py  logging_utils.py  Dockerfile  requirements.txt  logs/app.log
└── ui/          index.html  style.css  app.js  config.js  Dockerfile
```

`logging_utils.py` is identical in all three services and copied, not shared, so no
service depends on another service's code.

## Troubleshooting

* **Port already in use** — change the host side of the mapping in `docker-compose.yml`
  and update `ui/config.js` to match.
* **A service reports `"status": "degraded"`** — its database is still starting. It
  retries on its own; no restart needed. Watch `docker compose logs -f service-a`.
* **No notifications after creating an order** — service-c polls on an interval.
  Check `docker compose logs service-c` for `background_task_completed`, and confirm
  the order was created after service-c's first poll started.
* **`Logs: directory is not writable`** — the bind mount is missing; check the
  `volumes:` entry for that service.
