// Dashboard service endpoints.
//
// In the default (hosted) setup the browser talks only to this origin: the
// dashboard's nginx container reverse-proxies /api/<service>/* to the matching
// Flask service. That is why these are relative paths and not absolute URLs.
//
// For local development without the proxy, override at runtime before this
// file loads, e.g. in index.html:
//
//   <script>
//     window.ELKS_API_MODE = 'direct';
//   </script>
//
// or set the same key in localStorage as 'direct' after a first visit.

const DIRECT_SERVICES = {
  a: { name: 'service-a', label: 'service-a (Users)',          baseUrl: 'http://localhost:5001' },
  b: { name: 'service-b', label: 'service-b (Orders)',         baseUrl: 'http://localhost:5002' },
  c: { name: 'service-c', label: 'service-c (Notifications)', baseUrl: 'http://localhost:5003' },
};

const PROXIED_SERVICES = {
  a: { name: 'service-a', label: 'service-a (Users)',          baseUrl: '/api/service-a' },
  b: { name: 'service-b', label: 'service-b (Orders)',         baseUrl: '/api/service-b' },
  c: { name: 'service-c', label: 'service-c (Notifications)', baseUrl: '/api/service-c' },
};

function resolveApiMode() {
  if (window.ELKS_API_MODE === 'direct') return 'direct';
  try {
    if (window.localStorage.getItem('elks_api_mode') === 'direct') return 'direct';
  } catch (_) {
    // localStorage can throw in private mode; fall through to the proxy.
  }
  return 'proxied';
}

const API_MODE = resolveApiMode();

const SERVICES = API_MODE === 'direct' ? DIRECT_SERVICES : PROXIED_SERVICES;

// Surfaced in the UI so it is obvious which mode is live.
window.ELKS_API_MODE = API_MODE;
