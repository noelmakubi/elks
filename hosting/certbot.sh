#!/usr/bin/env bash
#
# Issue and renew the TLS certificate for the dashboard.
#
#   sudo bash hosting/certbot.sh your-domain.example.com
#
# Prerequisites:
#   * DNS already points at this host.
#   * Ports 80 and 443 are open in both ufw and the EC2 security group.
#   * The nginx site is the TLS one. If the host was bootstrapped in the
#     default `http` mode, re-run the bootstrap first:
#         DOMAIN=your-domain.example.com MODE=tls bash hosting/bootstrap.sh
#     then run this script.

set -Eeuo pipefail

DOMAIN="${1:-}"
[[ -n "$DOMAIN" ]] || { echo "usage: $0 <domain>" >&2; exit 2; }

SITE=/etc/nginx/sites-available/elks.conf

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run this with sudo"
[[ -f "$SITE" ]] || die "$SITE not found; run hosting/bootstrap.sh first"

########################################
# The site must be the TLS variant
########################################
# Without this check the script would happily issue a certificate that nothing
# ever loads, and the site would keep serving plain HTTP while the operator
# believed TLS was on.
if ! grep -q 'listen 443' "$SITE"; then
  die "$SITE has no HTTPS server block (this host was bootstrapped in http mode).
     Re-run:  DOMAIN=$DOMAIN MODE=tls bash $(dirname "$0")/bootstrap.sh
     then run this script again."
fi

# Fail early and clearly rather than after a slow ACME round trip.
if ! getent hosts "$DOMAIN" | grep -q .; then
  die "$DOMAIN does not resolve from this host. Add the DNS A record first."
fi

########################################
# Install certbot if needed
########################################
if ! command -v certbot >/dev/null 2>&1; then
  log "installing certbot"
  apt-get update -qq
  apt-get install -y -qq certbot
fi

########################################
# Issue
########################################
# nginx -t fails while the ssl_certificate lines point at a file that does not
# exist yet, so comment them out for the first issuance and back in after.
log "temporarily disabling the ssl_certificate directives for the first issuance"
cp -p "$SITE" "$SITE.bak"
sed -i 's|^\([[:space:]]*\)ssl_certificate|\1#ssl_certificate|' "$SITE"
nginx -t && systemctl reload nginx

# Only ask for www if it actually resolves here. Requesting a name with no DNS
# record fails the whole issuance, including the apex.
DOMAINS=(--domain "$DOMAIN")
if [[ "$DOMAIN" != www.* ]] && getent hosts "www.$DOMAIN" | grep -q .; then
  log "www.$DOMAIN resolves, including it"
  DOMAINS+=(--domain "www.$DOMAIN")
else
  log "www.$DOMAIN does not resolve, requesting the apex only"
fi

log "requesting a certificate for $DOMAIN"
# --register-unsafely-without-email: fine for a single-operator host. Add
# --email you@example.com if you want expiry warnings from Let's Encrypt.
certbot certonly \
  --webroot --webroot-path /var/www/certbot \
  "${DOMAINS[@]}" \
  --register-unsafely-without-email \
  --agree-tos \
  --non-interactive \
  || die "certbot failed. Check that DNS resolves to this host and that port 80 is reachable from the internet."

########################################
# Restore the certificate directives and reload
########################################
log "enabling the certificate in $SITE"
sed -i 's|^\([[:space:]]*\)#ssl_certificate|\1ssl_certificate|' "$SITE"
nginx -t || { cp -p "$SITE.bak" "$SITE"; die "nginx config test failed; restored the backup"; }
systemctl reload nginx

########################################
# Renewal
########################################
# certbot installs a timer on Debian/Ubuntu. Verify it, because a missing timer
# means an expired certificate and a silently broken site.
if systemctl list-timers --all 2>/dev/null | grep -q certbot; then
  log "certbot renewal timer is active"
else
  log "installing a certbot renewal timer (the packaged one was not found)"
  cat > /etc/systemd/system/certbot-renew.service <<'SERVICE'
[Unit]
Description=Renew the elks TLS certificate
[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
SERVICE
  cat > /etc/systemd/system/certbot-renew.timer <<'TIMER'
[Unit]
Description=Try to renew the elks TLS certificate twice daily
[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
TIMER
  systemctl enable --now certbot-renew.timer
fi

log "certificate issued and renewal scheduled"
certbot certificates 2>/dev/null || true
echo
echo "  Verify: curl -I https://$DOMAIN/healthz"
echo "  Note:   renewal runs automatically via the certbot timer. To test it"
echo "          without waiting: sudo certbot renew --dry-run"
