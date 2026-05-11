"use strict";

// ============================================================
// Sama Rang — Netlify Function : queue.js
// Fix : suppression de Supabase Realtime (WebSocket)
// On utilise UNIQUEMENT l'API REST Supabase (fetch HTTP)
// Zéro dépendance ws, zéro problème Node.js 20
// ============================================================

const SUPABASE_URL = process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL || "";
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || "";

const REDIS_URL   = process.env.UPSTASH_REDIS_REST_URL   || "";
const REDIS_TOKEN = process.env.UPSTASH_REDIS_REST_TOKEN || "";

const CORS = {
  "Content-Type": "application/json",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
};

// ─── Supabase REST (PAS de createClient, PAS de Realtime) ──
// On appelle directement l'API PostgREST via fetch
// → Aucun WebSocket, aucune dépendance native
async function sbFetch(path, opts = {}) {
  const url = `${SUPABASE_URL}/rest/v1${path}`;
  const res = await fetch(url, {
    ...opts,
    headers: {
      apikey:        SUPABASE_KEY,
      Authorization: `Bearer ${SUPABASE_KEY}`,
      "Content-Type": "application/json",
      Prefer:        opts.prefer || "return=representation",
      ...(opts.headers || {}),
    },
  });

  const text = await res.text();
  const data = text ? JSON.parse(text) : null;

  if (!res.ok) {
    const msg = data?.message || data?.error || res.statusText;
    throw new Error(`Supabase ${res.status}: ${msg}`);
  }
  return data;
}

// Helpers PostgREST
const sb = {
  // SELECT * FROM table WHERE filters
  select: (table, filters = "", select = "*") =>
    sbFetch(`/${table}?select=${select}${filters ? "&" + filters : ""}`),

  // SELECT single row
  single: async (table, filters = "", select = "*") => {
    const rows = await sbFetch(`/${table}?select=${select}${filters ? "&" + filters : ""}`, {
      headers: { Accept: "application/vnd.pgrst.object+json" },
    });
    return rows;
  },

  // INSERT — retourne le premier élément inséré
  insert: (table, body) =>
    sbFetch(`/${table}`, { method: "POST", body: JSON.stringify(body) })
      .then(r => Array.isArray(r) ? r[0] : r),

  // UPDATE
  update: (table, filters, body) =>
    sbFetch(`/${table}?${filters}`, {
      method: "PATCH",
      body: JSON.stringify(body),
      prefer: "return=representation",
    }),

  // DELETE
  delete: (table, filters) =>
    sbFetch(`/${table}?${filters}`, { method: "DELETE", prefer: "return=minimal" }),

  // COUNT
  count: async (table, filters = "") => {
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/${table}?select=id${filters ? "&" + filters : ""}`,
      {
        headers: {
          apikey:        SUPABASE_KEY,
          Authorization: `Bearer ${SUPABASE_KEY}`,
          Prefer:        "count=exact",
          "Range-Unit":  "items",
          Range:         "0-0",
        },
      }
    );
    const range = res.headers.get("content-range") || "0/0";
    return parseInt(range.split("/")[1] || "0", 10);
  },
};

// ─── Redis (inchangé — déjà fonctionnel) ──────────────────
async function redisCmd(cmd) {
  if (!REDIS_URL) return null;
  const r = await fetch(REDIS_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${REDIS_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify(cmd),
  });
  const d = await r.json();
  if (d.error) throw new Error(d.error);
  return d.result;
}
const rGet = async (k) => { const v = await redisCmd(["GET", k]); return v ? JSON.parse(v) : null; };
const rSet = async (k, v, ex = 86400) => redisCmd(["SET", k, JSON.stringify(v), "EX", ex]);
const rDel = async (k) => redisCmd(["DEL", k]);

// ─── Utilitaires ──────────────────────────────────────────
const ok  = (body)      => ({ statusCode: 200, headers: CORS, body: JSON.stringify(body) });
const err = (code, msg) => ({ statusCode: code, headers: CORS, body: JSON.stringify({ error: msg }) });
const today = () => new Date().toISOString().split("T")[0];

// ─── Handler principal ────────────────────────────────────
exports.handler = async (event) => {
  if (event.httpMethod === "OPTIONS") return { statusCode: 204, headers: CORS, body: "" };

  const raw    = (event.path || "").replace(/^\/.netlify\/functions\/queue\/?/, "").replace(/^\//, "");
  const seg    = raw.split("/").filter(Boolean);
  const method = event.httpMethod;
  const body   = event.body ? JSON.parse(event.body) : {};
  const qs     = event.queryStringParameters || {};

  try {
    // ── GET /health ──────────────────────────────────────
    if (method === "GET" && seg[0] === "health") {
      return ok({ status: "ok", node: process.version, supabase: !!SUPABASE_URL });
    }

    // ── GET /salons/:slug ── état de la file ─────────────
    if (method === "GET" && seg[0] === "salons" && seg.length === 2) {
      const slug = seg[1];

      // Cache Redis d'abord
      const cached = await rGet(`sq:v2:${slug}`);
      if (cached) return ok({ ...cached, source: "cache" });

      // Supabase REST — pas de WebSocket, juste HTTP
      const salon = await sb.single("salons", `slug=eq.${slug}`, "id,name,slug,plan");
      if (!salon) return err(404, "Salon introuvable");

      const queue = await sb.select(
        "queue_entries",
        `salon_id=eq.${salon.id}&date=eq.${today()}&status=in.(waiting,called,serving)&order=position.asc`,
        "id,client_name,client_phone,position,status,service_type,price,joined_at,called_at"
      );

      const payload = {
        id: salon.id, name: salon.name, plan: salon.plan,
        waitingCount: (queue || []).filter(e => e.status === "waiting").length,
        estimatedWait: (queue || []).filter(e => e.status === "waiting").length * 20,
        queue: queue || [],
      };

      await rSet(`sq:v2:${slug}`, payload, 30); // Cache 30s
      return ok({ ...payload, source: "db" });
    }

    // ── POST /salons/:slug/join ── rejoindre la file ──────
    if (method === "POST" && seg[0] === "salons" && seg[2] === "join") {
      const slug = seg[1];
      const { name, phone, serviceType = "coupe" } = body;
      if (!name) return err(400, "Nom requis");

      const salon = await sb.single("salons", `slug=eq.${slug}`, "id,name,plan");
      if (!salon) return err(404, "Salon introuvable");

      // Vérifier limite Free
      if (salon.plan === "free") {
        const startMonth = new Date(); startMonth.setDate(1); startMonth.setHours(0,0,0,0);
        const monthCount = await sb.count(
          "queue_entries",
          `salon_id=eq.${salon.id}&joined_at=gte.${startMonth.toISOString()}`
        );
        if (monthCount >= 50) return err(403, "Limite mensuelle atteinte (plan Free)");
      }

      // Position
      const waitCount = await sb.count(
        "queue_entries",
        `salon_id=eq.${salon.id}&date=eq.${today()}&status=eq.waiting`
      );
      const position = waitCount + 1;

      const PRICES = { coupe: 1500, barbe: 1000, coupe_barbe: 2500 };
      const price  = PRICES[serviceType] || 1500;

      const entry = await sb.insert("queue_entries", {
        salon_id:     salon.id,
        client_name:  name.trim(),
        client_phone: phone ? phone.replace(/\D/g, "") : null,
        service_type: serviceType,
        price,
        position,
        status:       "waiting",
        date:         today(),
      });

      // Invalider le cache Redis
      await rDel(`sq:v2:${slug}`);

      // Lien WhatsApp (pas d'API payante)
      const waLink = phone
        ? `https://wa.me/${phone.replace(/\D/g,"")}?text=${encodeURIComponent(
            `✅ Inscrit au ${salon.name} !\n📍 Position : N°${position}\n⏱ ~${position * 20} min d'attente`
          )}`
        : null;

      return ok({
        client: { id: entry?.id, name: name.trim(), position, estimatedWait: position * 20 },
        salon:  { name: salon.name },
        whatsappLink: waLink,
      });
    }

    // ── POST /salons/:slug/next ── appeler le suivant ─────
    if (method === "POST" && seg[0] === "salons" && seg[2] === "next") {
      const slug = seg[1];
      const salon = await sb.single("salons", `slug=eq.${slug}`, "id,name");
      if (!salon) return err(404, "Salon introuvable");

      const waiting = await sb.select(
        "queue_entries",
        `salon_id=eq.${salon.id}&date=eq.${today()}&status=eq.waiting&order=position.asc&limit=1`,
        "id,client_name,client_phone,position"
      );
      const next = waiting?.[0];
      if (!next) return ok({ called: null, remaining: 0 });

      await sb.update(
        "queue_entries",
        `id=eq.${next.id}`,
        { status: "called", called_at: new Date().toISOString() }
      );

      await rDel(`sq:v2:${slug}`);

      const waLink = next.client_phone
        ? `https://wa.me/${next.client_phone}?text=${encodeURIComponent(
            `🔔 C'est votre tour !\n${next.client_name}, présentez-vous au ${salon.name} dans les 5 minutes. Merci 🙏`
          )}`
        : null;

      const remaining = await sb.count(
        "queue_entries",
        `salon_id=eq.${salon.id}&date=eq.${today()}&status=eq.waiting`
      );

      return ok({
        called: { id: next.id, name: next.client_name, phone: next.client_phone },
        whatsappLink: waLink,
        remaining,
      });
    }

    // ── POST /salons/:slug/done/:id ── terminer ───────────
    if (method === "POST" && seg[0] === "salons" && seg[2] === "done") {
      const [, slug, , id] = seg;
      const salon = await sb.single("salons", `slug=eq.${slug}`, "id");
      if (!salon) return err(404, "Salon introuvable");

      await sb.update("queue_entries", `id=eq.${id}`, {
        status:  "done",
        done_at: new Date().toISOString(),
      });
      await rDel(`sq:v2:${slug}`);
      return ok({ ok: true });
    }

    // ── POST /salons/:slug/remove/:id ── retirer ──────────
    if (method === "POST" && seg[0] === "salons" && seg[2] === "remove") {
      const [, slug, , id] = seg;
      const salon = await sb.single("salons", `slug=eq.${slug}`, "id");
      if (!salon) return err(404, "Salon introuvable");

      await sb.delete("queue_entries", `id=eq.${id}`);
      await rDel(`sq:v2:${slug}`);
      return ok({ ok: true });
    }

    // ── POST /salons/:slug/add ── ajouter walk-in ─────────
    if (method === "POST" && seg[0] === "salons" && seg[2] === "add") {
      const slug = seg[1];
      const { name, phone, serviceType = "coupe" } = body;
      if (!name) return err(400, "Nom requis");

      const salon = await sb.single("salons", `slug=eq.${slug}`, "id,name");
      if (!salon) return err(404, "Salon introuvable");

      const waitCount = await sb.count(
        "queue_entries",
        `salon_id=eq.${salon.id}&date=eq.${today()}&status=eq.waiting`
      );

      const PRICES = { coupe: 1500, barbe: 1000, coupe_barbe: 2500 };
      const entry = await sb.insert("queue_entries", {
        salon_id:     salon.id,
        client_name:  name.trim(),
        client_phone: phone ? phone.replace(/\D/g, "") : null,
        service_type: serviceType,
        price:        PRICES[serviceType] || 1500,
        position:     waitCount + 1,
        status:       "waiting",
        date:         today(),
      });

      await rDel(`sq:v2:${slug}`);
      return ok({ client: entry });
    }

    // ── GET /stats/:slug ──────────────────────────────────
    if (method === "GET" && seg[0] === "stats") {
      const slug = seg[1];
      const salon = await sb.single("salons", `slug=eq.${slug}`, "id");
      if (!salon) return err(404, "Salon introuvable");

      const [waiting, done, called] = await Promise.all([
        sb.count("queue_entries", `salon_id=eq.${salon.id}&date=eq.${today()}&status=eq.waiting`),
        sb.count("queue_entries", `salon_id=eq.${salon.id}&date=eq.${today()}&status=eq.done`),
        sb.count("queue_entries", `salon_id=eq.${salon.id}&date=eq.${today()}&status=eq.called`),
      ]);

      return ok({ totalToday: waiting + done + called, waiting, served: done, called, avgWait: 20 });
    }

    return err(404, "Route introuvable");

  } catch (e) {
    console.error("[queue]", e.message);
    return err(500, e.message);
  }
};