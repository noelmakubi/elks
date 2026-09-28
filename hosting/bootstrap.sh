#!/usr/bin/env bash
#
# One-time EC2 bootstrap for the elks stack.
#
# Run as a non-root user with sudo, on a fresh Ubuntu 22.04/24.04 instance:
#   bash hosting/bootstrap.sh                 # HTTP on the public IP (no TLS)
#   DOMAIN=app.example.com MODE=tls bash hosting/bootstrap.sh
#
# Idempotent: safe to re-run. It installs Docker, creates the deploy user,
# lays out the log directories, drops the logrotate and nginx config into
# place, and opens exactly the ports the stack needs.
#
# MODE:
#   http  (default) the host nginx serves plain HTTP on :80 and proxies to the
#         ui container on 127.0.0.1:8080. Browse http://<server-ip>. No domain
#         and no certificate needed. This is the mode to start in.
#   tls   same, plus the :443 server block with the two ssl_certificate lines
#         left commented. Run hosting/certbot.sh afterwards to fill them in.
#         Requires DOMAIN to resolve to this host first.
#
# In both modes the ui container stays bound to loopback, so the dashboard is
# never exposed directly: everything goes through the host nginx.
#
# Nothing here starts the application. Run deploy.sh after cloning the repo.

set -Eeuo pipefail

readonly STACK_NAME="elks"
readonly LOG_ROOT="${LOG_ROOT:-/var/log/elks}"
readonly DEPLOY_HOME="${DEPLOY_HOME:-/opt/elks}"
readonly REPO_URL="${REPO_URL:-https://github.com/noelmakubi/elks.git}"
readonly BRANCH="${BRANCH:-main}"
readonly MODE="${MODE:-http}"
readonly DOMAIN="${DOMAIN:-}"

# Ports opened on the host firewall: 22 (ssh) and 80 (the dashboard). 443 is
# added only in tls mode. The API ports are never opened: the services have no
# host port at all and are reachable only through the ui container's proxy.
readonly SSH_PORT=22
readonly HTTP_PORT=80
readonly HTTPS_PORT=443

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "bootstrap failed on line $LINENO"' ERR

[[ $EUID -ne 0 ]] || die "run this as your normal login user, not root (it calls sudo itself)"

case "$MODE" in
  http)
    log "mode: http  -> the dashboard will be served on http://<server-ip> (port 80)"
    ;;
  tls)
    [[ -n "$DOMAIN" ]] || die "MODE=tls needs DOMAIN=your-domain.example.com"
    log "mode: tls   -> the dashboard will be served on https://$DOMAIN"
    ;;
  *)
    die "MODE must be 'http' or 'tls', got '$MODE'"
    ;;
esac

########################################
# 1. Base packages
########################################
log "installing base packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  ca-certificates curl gnupg git rsync jq logrotate ufw nginx chrony \
  unattended-upgrades

########################################
# 2. Docker Engine + Compose v2 from the official repo
########################################
if ! command -v docker >/dev/null 2>&1; then
  log "installing Docker Engine and the Compose plugin"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
else
  log "docker already installed: $(docker --version)"
fi

sudo systemctl enable --now docker
docker compose version

# The deploy user needs docker without sudo, which is effectively root on that
# host. Acceptable for a single-purpose app server; use a rootless setup if the
# box is shared.
if ! id -nG "$USER" | grep -qw docker; then
  log "adding $USER to the docker group"
  sudo usermod -aG docker "$USER"
  warn "$USER was added to the docker group: log out and back in (or run 'newgrp docker')"
fi

########################################
# 3. Sysctl tuning for a container workload
########################################
log "applying sysctl tuning"
sudo tee /etc/sysctl.d/99-elks.conf >/dev/null <<'SYSCTL'
# Services must survive a connection spike and a slow disk without being OOM-killed.
vm.max_map_count = 262144
vm.overcommit_memory = 1
vm.swappiness = 10
# Postgres and gunicorn both benefit from a higher file descriptor ceiling.
fs.file-max = 131072
# Docker sets this itself; make sure conntrack is sized for the DB connections.
net.netfilter.nf_conntrack_max = 262144
SYSCTL
sudo sysctl --system >/dev/null

# Swap: a 2 GB instance with three Postgres instances needs a little headroom.
if ! swapon --show | grep -q .; then
  log "creating a 2G swap file"
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

########################################
# 4. Clock sync
########################################
# The services log ISO-8601 timestamps and service-c polls on an interval; clock
# drift makes logs and ordering confusing.
log "enabling chrony for time sync"
sudo systemctl enable --now chrony

########################################
# 5. Log directories owned by the container's uid
########################################
# The images run as 1000:1000. If the deploy user is not uid 1000, chown the log
# dirs so the services can still write. Using named chown rather than
# depending on the login user's uid keeps this reproducible.
log "creating log directories under $LOG_ROOT"
for svc in service-a service-b service-c; do
  sudo install -d -o 1000 -g 1000 -m 0750 "$LOG_ROOT/$svc"
done

# Keep the app's own bind mounts inside the repo working. The deploy.sh symlinks
# ./service-x/logs to these directories so there is exactly one set of log files.
log "deploy home: $DEPLOY_HOME"
sudo install -d -o "$USER" -g "$USER" -m 0750 "$DEPLOY_HOME"

########################################
# 6. Logrotate
########################################
# The app deliberately does not rotate its own file (see README). This is the
# other half of that design. copytruncate is required because the container
# holds the file open.
log "installing the logrotate policy"
sudo tee /etc/logrotate.d/elks >/dev/null <<ROTATE
# Rotates each service's JSON log. copytruncate keeps the file the running
# container holds open, so the app never has to reopen it.
$LOG_ROOT/service-a/app.log {
    daily
    rotate 14
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su 1000 1000
}
$LOG_ROOT/service-b/app.log {
    daily
    rotate 14
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su 1000 1000
}
$LOG_ROOT/service-c/app.log {
    daily
    rotate 14
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su 1000 1000
}
ROTATE
sudo logrotate -d /etc/logrotate.d/elks >/dev/null 2>&1 || true

# Docker's own json-file logs are capped in compose, but the daemon-wide default
# is still unbounded. Cap it as a backstop.
log "capping Docker's own log growth"
sudo tee /etc/docker/daemon.json >/dev/null <<'DAEMON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
DAEMON
sudo systemctl restart docker

########################################
# 7. Host nginx: the public entrypoint in front of the ui container
########################################
# In both modes the ui container is bound to 127.0.0.1:8080, so nginx is the
# only thing the internet can reach. The difference is only whether port 80
# serves the app directly (http) or redirects to a TLS terminator (tls).
log "installing the host nginx site for $STACK_NAME (mode: $MODE)"

if [[ "$MODE" == "tls" ]]; then
  # ---- TLS mode -----------------------------------------------------------
  sudo tee /etc/nginx/sites-available/elks.conf >/dev/null <<NGINX
# TLS terminator for the elks dashboard.
#
# The dashboard container listens on 127.0.0.1:8080 and reverse-proxies the API
# to the Flask services. This config adds TLS and the security headers nginx
# adds best at the edge.
#
# The certificate is NOT provisioned here. Run: sudo bash hosting/certbot.sh $DOMAIN
# which fills in the two commented ssl_certificate lines below.

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN;

    # Uncommented by certbot.sh after the certificate is issued.
    # ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache         shared:SSL:10m;
    ssl_session_timeout       1d;

    access_log /var/log/nginx/elks.access.log;
    error_log  /var/log/nginx/elks.error.log;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff"                  always;
    add_header X-Frame-Options           "DENY"                     always;
    server_tokens off;

    client_max_body_size 1m;

    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }
}
NGINX
else
  # ---- HTTP mode (no domain, no certificate) ------------------------------
  # Deliberately no redirect to https: there is no certificate yet, so
  # redirecting would send every browser to an error page. Serve the app.
  sudo tee /etc/nginx/sites-available/elks.conf >/dev/null <<'NGINX'
# Public entrypoint for the elks dashboard (HTTP mode, no TLS).
#
# The dashboard container listens on 127.0.0.1:8080 and reverse-proxies
# /api/<service>/* to the Flask services. This is the only thing reachable from
# the internet, so the API ports stay unpublished.
#
# Traffic here is plain HTTP: anyone on the path can read it. That is fine for
# a first look at the stack. To get HTTPS, point a domain at this host and
# re-run:  DOMAIN=app.example.com MODE=tls bash hosting/bootstrap.sh

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    # Named so it also answers a bare-IP request, which is how you will reach
    # it before any DNS exists.
    server_name _;

    access_log /var/log/nginx/elks.access.log;
    error_log  /var/log/nginx/elks.error.log;

    server_tokens off;
    client_max_body_size 1m;

    # The inner nginx already sets these; repeating them here means they also
    # apply to error responses this layer generates itself.
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options    DENY   always;

    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }
}
NGINX
fi

sudo ln -sf /etc/nginx/sites-available/elks.conf /etc/nginx/sites-enabled/elks.conf
# Leave the packaged default site out of the way. It binds 80 too and would
# otherwise win for a bare-IP request, serving the nginx welcome page instead
# of the dashboard.
sudo rm -f /etc/nginx/sites-enabled/default
sudo install -d -o www-data -g www-data -m 0755 /var/www/certbot

if sudo nginx -t 2>/dev/null; then
  log "nginx config is valid"
  sudo systemctl enable --now nginx
  sudo systemctl reload nginx || true
else
  die "nginx config test failed; not reloading. Fix /etc/nginx/sites-available/elks.conf"
fi

########################################
# 8. Firewall
########################################
# NOTE: `ufw --force reset` clears any rules that were already here. On a fresh
# instance that is correct. On a host you have configured by hand, read this
# file first.
log "configuring ufw"
sudo ufw default deny incoming >/dev/null
sudo ufw default allow outgoing >/dev/null
sudo ufw allow "${SSH_PORT}/tcp" comment 'ssh' >/dev/null
sudo ufw allow "${HTTP_PORT}/tcp"  comment 'http (the dashboard)' >/dev/null
if [[ "$MODE" == "tls" ]]; then
  sudo ufw allow "${HTTPS_PORT}/tcp" comment 'https' >/dev/null
fi
sudo ufw --force enable >/dev/null
sudo ufw status verbose

# AWS security groups filter before ufw ever sees a packet. Remind rather than
# automate, since the API differs per account layout.
if [[ "$MODE" == "tls" ]]; then
  cat <<'SECURITYGROUP'
  Reminder: your EC2 security group must also allow inbound 22, 80 and 443 from
  0.0.0.0/0 (or your bastion CIDR for 22). Nothing else. ufw cannot help with
  packets dropped upstream of the host.
SECURITYGROUP
else
  cat <<'SECURITYGROUP'
  Reminder: your EC2 security group must allow inbound 22 and 80 from 0.0.0.0/0
  (or your bastion CIDR for 22). Nothing else. 8080 must stay closed: the
  dashboard is reached through the host nginx on port 80, not directly.
SECURITYGROUP
fi

########################################
# 9. Swap off the boot disk? No: verify disk headroom instead.
########################################
log "disk usage"
df -h / | tail -n 1

########################################
# 10. Unattended security updates for the host OS
########################################
log "enabling unattended security updates"
sudo dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
sudo systemctl enable --now unattended-upgrades.service 2>/dev/null || true

########################################
# 11. Clone the repo
########################################
if [[ -d "$DEPLOY_HOME/.git" ]]; then
  log "repo already present at $DEPLOY_HOME; fetching"
  git -C "$DEPLOY_HOME" fetch --all --tags --prune
else
  log "cloning $REPO_URL into $DEPLOY_HOME"
  sudo -u "$USER" git clone --branch "$BRANCH" "$REPO_URL" "$DEPLOY_HOME"
fi

chmod +x "$DEPLOY_HOME"/hosting/*.sh 2>/dev/null || true

########################################
# Done
########################################
PUBLIC_IP="$(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || echo '<server public ip>')"

if [[ "$MODE" == "tls" ]]; then
cat <<DONE

  Bootstrap complete (mode: tls). Next:

    1. Confirm your DNS A record already points at this host ($PUBLIC_IP).
    2. Issue the certificate:
         sudo bash $DEPLOY_HOME/hosting/certbot.sh $DOMAIN
    3. Create the secrets file and set the three DB passwords:
         cp $DEPLOY_HOME/microservices/.env.example $DEPLOY_HOME/microservices/.env
    4. Log out and back in (or 'newgrp docker') so the docker group applies.
    5. Start the stack:
         cd $DEPLOY_HOME && bash hosting/deploy.sh
    6. Open https://$DOMAIN

DONE
else
cat <<DONE

  Bootstrap complete (mode: http). Next:

    1. Create the secrets file and set the three DB passwords:
         cp $DEPLOY_HOME/microservices/.env.example $DEPLOY_HOME/microservices/.env
    2. Log out and back in (or 'newgrp docker') so the docker group applies.
         This matters: without it every later docker command fails with
         "permission denied" or "cannot talk to the docker daemon".
    3. Start the stack:
         cd $DEPLOY_HOME && bash hosting/deploy.sh
    4. Open http://$PUBLIC_IP

  Traffic is plain HTTP on this port. To move to HTTPS later, point a domain
  at this host, allow 443 in the security group, then:
         DOMAIN=app.example.com MODE=tls bash $DEPLOY_HOME/hosting/bootstrap.sh
         sudo bash $DEPLOY_HOME/hosting/certbot.sh app.example.com

DONE
fi
