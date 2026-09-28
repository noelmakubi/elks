# syntax=docker/dockerfile:1
# ui - static dashboard served by nginx.
#
# The bundled nginx config also reverse-proxies /api/<service> to the three
# Flask services, so the browser only ever talks to this one origin. That removes
# the need for CORS in production and keeps the API off the public internet.

FROM nginx:1.27-alpine

# Drop the stock site and run unprivileged, listening on 8080 inside the
# container so it does not need root.
RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/nginx.conf
COPY proxy_params_docker.conf /etc/nginx/proxy_params_docker.conf
COPY index.html style.css app.js config.js /usr/share/nginx/html/

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost:8080/ || exit 1
