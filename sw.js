// TecOS — abre na hora, mesmo com internet lenta ou sem internet.
// Guarda no aparelho os arquivos do app e as bibliotecas; os dados (Supabase) não passam por aqui.
const CACHE = "tecos-v1";
const ARQUIVOS = ["./", "index.html", "config.js?v=6", "manifest.json", "icon.svg", "icon-180.png", "icon-512.png"];
const EXTERNOS = ["https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/dist/umd/supabase.js"];
const CDN = /^https:\/\/(cdn\.jsdelivr\.net|fonts\.googleapis\.com|fonts\.gstatic\.com)\//;

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ARQUIVOS).then(() => Promise.all(EXTERNOS.map(u => c.add(u).catch(() => {}))))).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  const proprio = url.origin === location.origin;
  if (!proprio && !CDN.test(req.url)) return;            // Supabase e outros: direto na internet
  const nav = req.mode === "navigate";
  const chave = nav ? "./" : req;
  e.respondWith(caches.open(CACHE).then(async c => {
    const guardado = await c.match(chave, {ignoreSearch: nav});
    const daRede = fetch(req).then(r => { if (r && (r.ok || r.type === "opaque")) c.put(chave, r.clone()); return r; }).catch(() => null);
    if (!proprio) { if (guardado) { e.waitUntil(daRede); return guardado; } return (await daRede) || Response.error(); }
    // arquivos do app: tenta a versão nova por até 1,2 s; se demorar, abre a guardada e atualiza por trás
    if (!guardado) return (await daRede) || Response.error();
    const rapido = await Promise.race([daRede, new Promise(r => setTimeout(() => r(null), 1200))]);
    if (rapido) return rapido;
    e.waitUntil(daRede);
    return guardado;
  }));
});
