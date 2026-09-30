// Cache only the public application shell. Never cache authenticated API responses.
const CACHE='wzb-shell-v3';
self.addEventListener('install',event=>{event.waitUntil((async()=>{const cache=await caches.open(CACHE);const response=await fetch('/');await cache.put('/',response.clone());const html=await response.text();const assets=[...html.matchAll(/(?:src|href)="(\/assets\/[^\"]+)"/g)].map(match=>match[1]);await cache.addAll(assets);self.skipWaiting()})())});
self.addEventListener('activate',event=>{event.waitUntil((async()=>{for(const key of await caches.keys())if(key!==CACHE)await caches.delete(key);await self.clients.claim()})())});
self.addEventListener('fetch',event=>{const url=new URL(event.request.url);if(event.request.method!=='GET'||url.origin!==location.origin||url.pathname.startsWith('/api'))return;event.respondWith(fetch(event.request).catch(async()=>await caches.match(event.request)||(event.request.mode==='navigate'?await caches.match('/'):Response.error()))) });
