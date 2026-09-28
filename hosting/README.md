# Hosting on EC2

Everything needed to run this stack on an EC2 instance. There is **no CI/CD**:
you deploy by running `hosting/deploy.sh` on the server yourself.

This guide assumes the starting point: Ubuntu 22.04/24.04, reachable by public
IP, no domain yet, served over plain HTTP. The TLS steps come later and are
optional; see [Adding TLS later](#adding-tls-later).

## What gets built

```
                     internet
                        |
                      :80               host nginx (Ubuntu)
                        |               the only public entrypoint
         127.0.0.1:8080 |               binds nothing itself
                        v
                    elks-ui            nginx: static dashboard +
                        |              reverse-proxies /api/<service>/*
        +---------------+---------------+
        |               |               |
   service-a:5001   service-b:5002   service-c:5003     (no host port)
        |               |               |
   service-a-db    service-b-db     service-c-db        postgres:16-alpine
```

Only port **22** and **80** are open. The three Flask services have no host port
at all, so they are reachable only through the dashboard's nginx. That is why
the dashboard uses relative `/api/service-x` URLs in production and needs no
CORS, and why you never open 5001-5003 in the security group.

`hosting/bootstrap.sh` is idempotent: run it as many times as you like.

---

## Step 1 — the EC2 instance

> **Before you start:** this guide's Step 2 downloads `bootstrap.sh` from GitHub
> `main`. Push these changes first (`git push`), or the server will fetch the
> older version of the script. If you would rather not depend on that, clone
> the repo with `scp` and run `hosting/bootstrap.sh` from the copy on the box.

In the AWS console, when launching:

| Setting | Value | Why |
| --- | --- | --- |
| AMI | Ubuntu 22.04 or 24.04 LTS | what the bootstrap targets |
| Instance type | `t3.small` (2 vCPU, 2 GB) minimum | three Postgres + three Python services + nginx all on one box |
| Storage | 20 GB gp3 | enough; the logs are the only thing that grows |
| Key pair | your existing one, or create one | you cannot log in without it |

Then, **before** you can log in, set the security group:

| Type | Protocol | Port | Source |
| --- | --- | --- | --- |
| SSH | TCP | 22 | your IP, or `0.0.0.0/0` |
| HTTP | TCP | 80 | `0.0.0.0/0` |

That is all. **Do not open 5001, 5002, 5003 or 8080.** The stack publishes
none of them, and opening them is not a fix for anything.

Also attach an **Elastic IP** if the instance may be stopped, so the address does
not change on a restart.

Connect:

```bash
ssh -i your-key.pem ubuntu@<your-server-ip>
```

## Step 2 — clone and bootstrap

Do not install Docker by hand. `hosting/bootstrap.sh` installs Docker, Compose
v2 and everything else the host needs, then clones the repo into `/opt/elks` as
its last step.

Fetch just the script and run it:

```bash
curl -fsSL https://raw.githubusercontent.com/noelmakubi/elks/main/hosting/bootstrap.sh -o /tmp/bootstrap.sh
bash /tmp/bootstrap.sh
```

If you would rather read the script before running it, or your branch is not
`main`, clone the repo yourself. The bootstrap detects an existing checkout and
runs `git fetch` instead of cloning:

```bash
sudo git clone https://github.com/noelmakubi/elks.git /opt/elks
sudo chown -R "$USER":"$USER" /opt/elks
cd /opt/elks && bash hosting/bootstrap.sh
```

What the bootstrap does, in order:

| # | What | Notes |
| --- | --- | --- |
| 1 | Base packages | `curl git jq nginx ufw chrony logrotate` |
| 2 | Docker Engine + Compose v2 | from Docker's apt repo, and adds you to the `docker` group |
| 3 | Sysctl + 2 GB swap | a 2 GB box running three databases needs headroom |
| 4 | Time sync | so the ISO-8601 log lines are comparable |
| 5 | Log directories | owned by uid 1000, matching the containers |
| 6 | Logrotate | `/etc/logrotate.d/elks`, `copytruncate` |
| 7 | Docker log cap | `/etc/docker/daemon.json`, 10 MB x 3 per container |
| 8 | Host nginx | `/etc/nginx/sites-available/elks.conf`, proxying to the ui container |
| 9 | UFW | denies incoming, allows only 22 and 80 |
| 10 | Unattended security updates | |
| 11 | Clone the repo | into `/opt/elks`, or `git fetch` if it is already there |

**Log out and back in** (or run `newgrp docker`) when it finishes. Until you
do, every `docker` command fails with `permission denied`, and `deploy.sh`
stops with `cannot talk to the docker daemon`. This is the single most common
thing to trip over.

## Step 3 — the secrets file

The three database passwords are the only secrets, and they never leave the
server.

```bash
cd /opt/elks
cp microservices/.env.example microservices/.env
```

Generate three different passwords and paste them in:

```bash
openssl rand -base64 24   # -> SERVICE_A_DB_PASSWORD
openssl rand -base64 24   # -> SERVICE_B_DB_PASSWORD
openssl rand -base64 24   # -> SERVICE_C_DB_PASSWORD
```

```bash
nano microservices/.env
```

`deploy.sh` refuses to start if any of the three is still `change_me_*`, so a
forgotten edit fails immediately instead of quietly shipping a known password.

`microservices/.env` is gitignored. Never commit it.

## Step 4 — deploy

```bash
cd /opt/elks
bash hosting/deploy.sh
```

This is the step that starts the containers. It:

1. checks Docker, the compose plugin and the `.env` above;
2. creates the per-service log directories with the right owner;
3. saves `.env.previous` so `rollback.sh` can restore it;
4. builds the three images (tagged with the commit sha) and the ui image;
5. `docker compose up -d`, which starts the databases, waits for them to be
   healthy, then starts the services and the dashboard;
6. waits for **every** container to report healthy, up to 180 s;
7. runs a smoke test through the proxy: create a user, create an order for that
   user, wait for service-c to poll it, confirm the notification appeared.

Then check it:

```bash
curl -s http://127.0.0.1:8080/healthz
curl -s http://127.0.0.1:8080/api/service-a/health
docker compose -f microservices/docker-compose.yml \
  -f microservices/docker-compose.prod.yml --project-name elks ps
```

## Step 5 — open it

In your browser:

```
http://<your-server-ip>
```

That is the host nginx, on port 80, proxying to the ui container.

If it does not load, work down this list:

```bash
sudo ufw status                      # is 80 allowed?
curl -s http://127.0.0.1:8080/healthz   # is the container itself up?
sudo nginx -t                          # is the host config valid?
```

---

## Day-to-day operations

The full compose command is long, so make it an alias:

```bash
echo "alias elks='docker compose --project-name elks --env-file /opt/elks/microservices/.env -f /opt/elks/microservices/docker-compose.yml -f /opt/elks/microservices/docker-compose.prod.yml'" >> ~/.bashrc
source ~/.bashrc
```

Then:

```bash
elks ps                  # status
elks logs -f service-a   # follow one service
elks restart service-b   # restart one service
elks down                # stop everything (volumes and data survive)
```

One service's structured log file, on the host:

```bash
tail -f microservices/service-a/logs/app.log
```

### Deploying a change

```bash
cd /opt/elks
git pull
bash hosting/deploy.sh
```

`git pull` then `deploy.sh`, in that order. The server deploys the exact commit
that is checked out, and `deploy.sh` refuses to leave a half-started stack
silently behind.

### Rolling back

```bash
bash hosting/rollback.sh            # back one commit
bash hosting/rollback.sh <sha>      # a specific commit
bash hosting/rollback.sh --config-only   # restore the previous .env
```

### Backups

```bash
bash hosting/backup.sh
bash hosting/backup.sh --restore service-a /var/backups/elks/service-a-20260101T020000Z.sql.gz
```

Schedule it:

```bash
crontab -e
```

```
17 2 * * * /opt/elks/hosting/backup.sh >> /var/log/elks-backup.log 2>&1
```

Dumps land in `/var/backups/elks`; anything older than 14 days is deleted.
**A backup you have never restored from is not a backup.** Test a restore into a
throwaway database once, before you need it.

The dumps sit on the same instance as the databases. Copy them somewhere else
(`scp` to your laptop, or another bucket) and add EBS snapshots on the volume.
Neither protects you from losing the whole instance.

---

## Adding TLS later

Only when you have a domain whose A record points at the instance, and you have
added port 443 to the security group.

```bash
cd /opt/elks
DOMAIN=app.example.com MODE=tls bash hosting/bootstrap.sh
sudo bash hosting/certbot.sh app.example.com
curl -I https://app.example.com/healthz
```

`MODE=tls` rewrites the nginx site to redirect HTTP to HTTPS and opens 443 in
ufw. `certbot.sh` then requests the certificate, uncomments the two
`ssl_certificate` lines, reloads nginx, and verifies the renewal timer is live.
Only ask for `www.app.example.com` if that name actually resolves; `certbot.sh`
checks, because a name with no DNS record fails the whole request.

---

## How the production overlay differs from dev

`docker-compose.prod.yml` is applied on top of `docker-compose.yml`, so local
work is unaffected.

| | dev | prod |
| --- | --- | --- |
| API ports | published 5001-5003 | **not published**; only through the ui proxy |
| dashboard | `8080:8080` on all interfaces | `127.0.0.1:8080:8080` |
| entrypoint | `python app.py` | gunicorn, 1 worker, 8 threads |
| root filesystem | writable | read-only, tmpfs for `/tmp` |
| capabilities | default | all dropped, `no-new-privileges` |
| image tags | `elks/service-x:local` | `elks/service-x:<commit sha>` |
| Postgres | defaults | 50 connections, tuned buffers, data checksums |
| log driver | json-file | json-file, 10 MB x 3 |
| network | default bridge | `elks`, internal to the project |

The overlay uses `ports: !reset []` on each service. That is not decoration:
compose **merges** lists rather than replacing them, so without the reset the
dev `ports` entry survives and the API is published to the internet, bypassing
the proxy, its CSP and its rate limit. Verified with
`docker compose config` — check it yourself after any change:

```bash
cd /opt/elks/microservices
docker compose -f docker-compose.yml -f docker-compose.prod.yml config | grep -A2 published
```

You should see exactly one published port, for the ui container.

## Design notes worth knowing

**Why gunicorn with one worker.** The schema-init thread (and service-c's
poller) start at import time, because `if __name__ == "__main__"` never runs
under gunicorn. A second worker is a second process and would run a second
poller. `processed_orders` keeps that idempotent, but one worker is the correct
configuration. Raise `GUNICORN_THREADS` before `GUNICORN_WORKERS`.

**Why the API has no host port.** It removes a whole class of problem: no CORS
in production, nothing to open in the security group, and TLS in one place. The
dashboard's nginx also rate-limits (30 req/s, burst 60) and sets a strict CSP,
which is easier to get right once than in three places.

**Why `copytruncate` in logrotate.** The app deliberately only ever appends and
never rotates, so it never has to reopen a file. `copytruncate` is what makes
that work: copy, then truncate, keeping the inode the container holds open.

**Why the read-only root filesystem.** A compromised Flask process cannot write
a binary, drop a cron entry, or replace anything on disk. `/tmp` is tmpfs, so
anything that genuinely needs scratch space still has some.

**Why Postgres keeps its capabilities.** The other containers drop all of them,
but the postgres entrypoint starts as root to chown its data directory and then
drops privileges with gosu. With `cap_drop: ALL` the data directory cannot be
prepared and the database will not start.

## Troubleshooting

**`deploy.sh` says `cannot talk to the docker daemon`** — you have not picked up
the `docker` group yet. `newgrp docker`, or log out and back in.

**`ui` never becomes healthy** — `elks logs ui`. Usually a bad `nginx.conf`;
`docker exec -it elks-ui nginx -t` inside the container.

**A service crash-loops on a log permission error** — the bind mount is not
writable by uid 1000. `deploy.sh` fixes this on every run; if you changed a
mount by hand:
`sudo chown -R 1000:1000 microservices/service-x/logs`.

**`502` in the browser** — the proxy could not reach a service. `elks ps`, then
`elks logs <service>`.

**`429` in the browser** — the rate limit is 30 req/s with a burst of 60. The
dashboard itself stays well under that; something else is hitting the API.

**The dashboard loads but every panel says degraded** — the databases are still
starting. It resolves on its own within a minute or two; check
`elks logs service-a` if it does not.

**Out of disk** — `docker system df`. The log caps stop the usual cause, but old
images accumulate. `docker image prune -a` is safe once you know which tag is
deployed (`cat microservices/.deployed-commit`).
