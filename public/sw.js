/* שורש — service worker מינימלי.
 *
 * מטרה יחידה: לאפשר התקנה למסך הבית (כרום דורש fetch handler).
 *
 * ⚠️ בכוונה *לא* שומר את index.html במטמון. כבר נכווינו מגרסה תקועה
 *    בנייד — ראה public/_headers. הכלל כאן: רשת קודם, תמיד.
 *    רק האייקונים נשמרים, והם ממילא לא משתנים.
 */
const CACHE = 'shoresh-icons-v2';
const ICONS = ['icon-192.png', 'icon-512.png', 'icon-maskable.png', 'apple-touch-icon.png'];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ICONS)).catch(() => {}));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  const isIcon = ICONS.some(i => url.pathname.endsWith(i));

  if (isIcon && e.request.method === 'GET') {
    // ignoreSearch: האייקונים נטענים עם ?v=… לשבירת מטמון, והמטמון שומר בלי.
    e.respondWith(
      caches.match(e.request, { ignoreSearch: true }).then(r => r || fetch(e.request))
    );
    return;
  }
  // כל השאר — ישר לרשת, בלי מטמון.
  e.respondWith(fetch(e.request));
});
