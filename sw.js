// ── Forest Coffee CTRM — Service Worker ──────────────────────────────
// __APP_VERSION__ lo reemplaza Netlify en cada deploy (SHA del commit),
// así 'activate' borra las cachés viejas automáticamente. No editar a mano.
const CACHE_NAME = 'forest-ctrm-__APP_VERSION__';

const STATIC_ASSETS = [
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
];

const BYPASS_ORIGINS = [
  'supabase.co',
  'anthropic.com',
  'googleapis.com',
  'gstatic.com',
  'jsdelivr.net',
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache =>
      cache.addAll(STATIC_ASSETS).catch(() => {})
    )
  );
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => {
        console.log('[SW] Deleting old cache:', k);
        return caches.delete(k);
      }))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (BYPASS_ORIGINS.some(o => url.hostname.includes(o))) return;
  if (event.request.method !== 'GET') return;
  if (STATIC_ASSETS.some(a => url.pathname === a)) {
    event.respondWith(
      caches.match(event.request).then(cached => cached || fetch(event.request))
    );
  }
  // index.html always goes to network — never cached
});
