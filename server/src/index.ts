// スマホ制限アプリ試作のサーバー。認証は Bearer トークン1本（本実装の認証は決まっていない）。
//
//   GET  /state                       今の状態 {version, locked, unlockUntil, changedAt}
//   POST /lock?push=none|silent|alert ロックにして version+1
//   POST /unlock?minutes=15&push=…    解除（minutes 付きで時間解除）
//   POST /device                      APNs のデバイストークンを登録
//   GET  /device                      最新のデバイストークン（tools/push.sh 用・設計の表に足したもの）
//   POST /events                      端末の記録をまとめて受け取る {events:[…]}
//   GET  /events?since=ISO            記録を返す
//   POST /unlocks                     縁側アプリからの時間解除（理由つき）を記録する（2026-10-14 足し算）
//   GET  /unlocks?since=ISO&limit=N   解除の履歴（新しい順）
//   GET  /                            最小のボタンページ（トークンは URL のフラグメント #<token> で渡す）

import { type ApnsEnv, type PushKind, type StatePayload, sendPush } from "./apns";

interface Env extends ApnsEnv {
  DB: D1Database;
  API_TOKEN?: string;
}

interface StateRow {
  version: number;
  locked: number;
  unlock_until: string | null;
  changed_at: string;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });

const nowIso = () => new Date().toISOString();

function timingSafeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

function authorized(req: Request, env: Env): boolean {
  if (!env.API_TOKEN) return false;
  const h = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(h);
  return !!m && timingSafeEqual(m[1].trim(), env.API_TOKEN);
}

function toState(r: StateRow): StatePayload & { effectiveLocked: boolean } {
  const until = r.unlock_until;
  const expired = !!until && Date.parse(until) <= Date.now();
  return {
    version: r.version,
    locked: r.locked === 1,
    unlockUntil: until,
    changedAt: r.changed_at,
    // 時間解除の期限が過ぎていれば端末側で再ロックされているはず（表示用。端末は version で判断する）
    effectiveLocked: r.locked === 1 || expired,
  };
}

async function getState(env: Env) {
  const r = await env.DB.prepare("SELECT version, locked, unlock_until, changed_at FROM state WHERE id = 1").first<StateRow>();
  if (!r) throw new Error("state の行が無い（マイグレーション未適用）");
  return toState(r);
}

async function serverEvent(env: Env, kind: string, fields: Partial<Record<string, unknown>> = {}) {
  await env.DB.prepare(
    `INSERT INTO events (id, source, received_at, ts, proc, kind, route, version, locked, server_changed_at, ok, error, detail)
     VALUES (?, 'server', ?, ?, 'server', ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      crypto.randomUUID(),
      nowIso(),
      nowIso(),
      kind,
      (fields.route as string) ?? null,
      (fields.version as number) ?? null,
      fields.locked === undefined ? null : fields.locked ? 1 : 0,
      (fields.serverChangedAt as string) ?? null,
      fields.ok === undefined ? null : fields.ok ? 1 : 0,
      (fields.error as string) ?? null,
      (fields.detail as string) ?? null,
    )
    .run();
}

async function changeState(env: Env, locked: boolean, minutes: number | null) {
  const changedAt = nowIso();
  const until = !locked && minutes ? new Date(Date.now() + minutes * 60_000).toISOString() : null;
  await env.DB.prepare("UPDATE state SET version = version + 1, locked = ?, unlock_until = ?, changed_at = ? WHERE id = 1")
    .bind(locked ? 1 : 0, until, changedAt)
    .run();
  const s = await getState(env);
  await serverEvent(env, locked ? "serverLock" : "serverUnlock", {
    version: s.version,
    locked: s.locked,
    serverChangedAt: s.changedAt,
    detail: until ? `unlockUntil=${until}` : undefined,
  });
  return s;
}

async function maybePush(env: Env, kind: string | null, s: StatePayload) {
  if (!kind || kind === "none") return { push: "none" };
  if (kind !== "alert" && kind !== "silent") return { push: kind, ok: false, error: "push は none|silent|alert" };
  const dev = await env.DB.prepare("SELECT token FROM device ORDER BY updated_at DESC LIMIT 1").first<{ token: string }>();
  let result;
  if (!dev) result = { ok: false, error: "デバイストークンが未登録" };
  else result = await sendPush(env, dev.token, kind as PushKind, s);
  await serverEvent(env, "serverPush", {
    route: kind === "alert" ? "R3" : "R2",
    version: s.version,
    serverChangedAt: s.changedAt,
    ok: result.ok,
    error: result.error,
    detail: "status" in result && result.status ? `status=${result.status}` : undefined,
  });
  return { push: kind, ...result };
}

// 端末から来る値は信用しない。文字列・数値・真偽以外（オブジェクト・配列など）は null に落とす
type Scalar = string | number | boolean | null;
const scalar = (v: unknown): Scalar =>
  typeof v === "string" || typeof v === "boolean" || (typeof v === "number" && Number.isFinite(v)) ? v : null;
const text = (v: unknown): string | null => {
  const x = scalar(v);
  return x === null ? null : String(x).slice(0, 2000);
};
const int = (v: unknown): number | null => {
  const x = scalar(v);
  const n = typeof x === "number" ? x : typeof x === "string" && x.trim() !== "" ? Number(x) : NaN;
  return Number.isFinite(n) ? Math.trunc(n) : null;
};
const bool = (v: unknown): number | null => {
  const x = scalar(v);
  if (typeof x === "boolean") return x ? 1 : 0;
  if (x === 0 || x === 1) return x;
  return null;
};

async function postEvents(req: Request, env: Env) {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "JSON が読めない" }, 400);
  }
  const raw = body && typeof body === "object" && Array.isArray((body as { events?: unknown }).events)
    ? ((body as { events: unknown[] }).events)
    : [];
  if (raw.length > 5000) return json({ error: "多すぎる（5000件まで）" }, 413);
  const received = nowIso();
  const stmt = env.DB.prepare(
    `INSERT OR IGNORE INTO events
     (id, source, received_at, ts, proc, kind, route, version, locked, server_changed_at, applied_at, ok, error, detail)
     VALUES (?, 'device', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  let skipped = 0;
  const batch: D1PreparedStatement[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) { skipped++; continue; }
    const e = item as Record<string, unknown>;
    const id = text(e.id);
    if (!id) { skipped++; continue; }
    batch.push(stmt.bind(
      id, received, text(e.ts), text(e.proc), text(e.kind), text(e.route), int(e.version), bool(e.locked),
      text(e.serverChangedAt), text(e.appliedAt), bool(e.ok), text(e.error), text(e.detail),
    ));
  }
  // D1 の batch は大きすぎると失敗するので 100 件ずつ。塊が失敗したら1件ずつ入れ直し、入らないものだけ捨てる
  let inserted = 0;
  let rejected = 0;
  for (let i = 0; i < batch.length; i += 100) {
    const chunk = batch.slice(i, i + 100);
    try {
      const res = await env.DB.batch(chunk);
      inserted += res.reduce((n, r) => n + (r.meta.changes ?? 0), 0);
    } catch {
      for (const st of chunk) {
        try {
          const r = await st.run();
          inserted += r.meta.changes ?? 0;
        } catch {
          rejected++;
        }
      }
    }
  }
  return json({ received: raw.length, inserted, skipped, rejected });
}

async function getEvents(url: URL, env: Env) {
  const since = url.searchParams.get("since") ?? "1970-01-01T00:00:00Z";
  const n = Math.trunc(Number(url.searchParams.get("limit") ?? "5000"));
  const limit = Math.min(Math.max(1, Number.isFinite(n) ? n : 5000), 20000);   // 数でなければ 5000、1〜20000 に収める
  const { results } = await env.DB.prepare(
    `SELECT id, source, received_at AS receivedAt, ts, proc, kind, route, version, locked,
            server_changed_at AS serverChangedAt, applied_at AS appliedAt, ok, error, detail
     FROM events WHERE COALESCE(ts, received_at) >= ? ORDER BY COALESCE(ts, received_at) LIMIT ?`,
  )
    .bind(since, limit)
    .all<Record<string, unknown>>();
  const out = results.map((r) => ({
    ...r,
    locked: r.locked === null ? null : r.locked === 1,
    ok: r.ok === null ? null : r.ok === 1,
  }));
  return json({ events: out });
}

async function postDevice(req: Request, env: Env) {
  let body: { token?: string; env?: string; bundle?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "JSON が読めない" }, 400);
  }
  if (!body.token || !/^[0-9a-f]{32,200}$/i.test(body.token)) return json({ error: "token が不正" }, 400);
  await env.DB.prepare(
    `INSERT INTO device (token, env, bundle, updated_at) VALUES (?, ?, ?, ?)
     ON CONFLICT(token) DO UPDATE SET env = excluded.env, bundle = excluded.bundle, updated_at = excluded.updated_at`,
  )
    .bind(body.token, body.env ?? "sandbox", body.bundle ?? null, nowIso())
    .run();
  await serverEvent(env, "deviceRegistered", { detail: `env=${body.env ?? "sandbox"}` });
  return json({ ok: true });
}

function parseMinutes(url: URL): number | null | "bad" {
  const m = url.searchParams.get("minutes");
  if (m === null || m === "") return null;
  const n = Number(m);
  if (!Number.isInteger(n) || n < 1 || n > 24 * 60) return "bad";
  return n;
}

const LOCK_REASONS = new Set(["none", "manual", "quota", "manualAndQuota"]);

// 縁側アプリからの時間解除の記録。状態（state）は変えない（解除は端末の中で済んでいる・記録だけ）
async function postUnlock(req: Request, env: Env) {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "JSON が読めない" }, 400);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) return json({ error: "オブジェクトで送ること" }, 400);
  const b = body as Record<string, unknown>;
  const id = typeof b.id === "string" && /^[A-Za-z0-9-]{8,64}$/.test(b.id) ? b.id : null;
  if (!id) return json({ error: "id が不正" }, 400);
  const at = typeof b.at === "string" && !Number.isNaN(Date.parse(b.at)) ? b.at : null;
  if (!at) return json({ error: "at は ISO 8601 の時刻" }, 400);
  const minutes = int(b.minutes);
  if (minutes === null || minutes < 1 || minutes > 24 * 60) return json({ error: "minutes は 1〜1440 の整数" }, 400);
  const reason = typeof b.reason === "string" ? b.reason.trim() : "";
  if (reason.length === 0) return json({ error: "reason は必須" }, 400);
  if (reason.length > 500) return json({ error: "reason は500字まで" }, 400);
  const until = typeof b.until === "string" && !Number.isNaN(Date.parse(b.until))
    ? b.until
    : new Date(Date.parse(at) + minutes * 60_000).toISOString();
  const lockReason = typeof b.lockReason === "string" && LOCK_REASONS.has(b.lockReason) ? b.lockReason : null;
  const usedMinutes = int(b.usedMinutes);
  const quotaMinutes = int(b.quotaMinutes);

  const res = await env.DB.prepare(
    `INSERT OR IGNORE INTO unlocks (id, at, received_at, minutes, until, reason, lock_reason, used_minutes, quota_minutes, source)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'app')`,
  )
    .bind(id, at, nowIso(), minutes, until, reason, lockReason, usedMinutes, quotaMinutes)
    .run();
  const inserted = res.meta.changes ?? 0;
  if (inserted > 0) {
    await serverEvent(env, "deviceUnlock", {
      route: "app",
      ok: true,
      detail: `minutes=${minutes} until=${until} lockReason=${lockReason ?? "?"}`,
    });
  }
  return json({ ok: true, inserted, id });
}

async function getUnlocks(url: URL, env: Env) {
  const since = url.searchParams.get("since") ?? "1970-01-01T00:00:00Z";
  const n = Math.trunc(Number(url.searchParams.get("limit") ?? "200"));
  const limit = Math.min(Math.max(1, Number.isFinite(n) ? n : 200), 5000);
  const { results } = await env.DB.prepare(
    `SELECT id, at, received_at AS receivedAt, minutes, until, reason, lock_reason AS lockReason,
            used_minutes AS usedMinutes, quota_minutes AS quotaMinutes, source
     FROM unlocks WHERE at >= ? ORDER BY at DESC LIMIT ?`,
  )
    .bind(since, limit)
    .all<Record<string, unknown>>();
  return json({ unlocks: results });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const route = `${req.method} ${url.pathname}`;

    if (route === "GET /") return new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } });

    if (!authorized(req, env)) return json({ error: "unauthorized" }, 401);

    try {
      switch (route) {
        case "GET /state":
          return json(await getState(env));
        case "POST /lock": {
          const s = await changeState(env, true, null);
          return json({ state: s, ...(await maybePush(env, url.searchParams.get("push"), s)) });
        }
        case "POST /unlock": {
          const minutes = parseMinutes(url);
          if (minutes === "bad") return json({ error: "minutes は 1〜1440 の整数" }, 400);
          const s = await changeState(env, false, minutes);
          return json({ state: s, ...(await maybePush(env, url.searchParams.get("push"), s)) });
        }
        case "POST /device":
          return await postDevice(req, env);
        case "GET /device": {
          const d = await env.DB.prepare("SELECT token, env, bundle, updated_at AS updatedAt FROM device ORDER BY updated_at DESC LIMIT 1").first();
          return d ? json(d) : json({ error: "未登録" }, 404);
        }
        case "POST /events":
          return await postEvents(req, env);
        case "GET /events":
          return await getEvents(url, env);
        case "POST /unlocks":
          return await postUnlock(req, env);
        case "GET /unlocks":
          return await getUnlocks(url, env);
        default:
          return json({ error: "not found" }, 404);
      }
    } catch (e) {
      return json({ error: String(e) }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

// 試作用の最小のボタンページ。トークンは URL のフラグメント（#…）で渡すので、サーバーのログには残らない
const PAGE = `<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>制限試作</title>
<style>
 body{font-family:system-ui,sans-serif;max-width:28rem;margin:2rem auto;padding:0 1rem;line-height:1.6}
 button{font-size:1.1rem;padding:.6rem 1rem;margin:.3rem .3rem .3rem 0;border-radius:.5rem;border:1px solid #888;background:#fff}
 button.lock{background:#c0392b;color:#fff;border:none}
 pre{background:#f4f4f4;padding:.8rem;border-radius:.4rem;white-space:pre-wrap}
 label{font-size:.9rem}
</style></head>
<body>
<h1>制限試作</h1>
<p id="who"></p>
<div>
 <button class="lock" data-act="lock">ロック</button>
 <button data-act="unlock" data-min="15">15分解除</button>
 <button data-act="unlock" data-min="30">30分解除</button>
</div>
<p><label>プッシュ <select id="push"><option value="none">なし</option><option value="alert">alert（R3）</option><option value="silent">silent（R2）</option></select></label></p>
<pre id="out">…</pre>
<script>
const token = location.hash.slice(1);
const out = document.getElementById('out');
document.getElementById('who').textContent = token ? '' : 'URL の末尾に #<トークン> を付けて開いてください';
async function call(method, path) {
  const r = await fetch(path, {method, headers: {Authorization: 'Bearer ' + token}});
  const t = await r.text();
  try { return JSON.stringify(JSON.parse(t), null, 2); } catch { return r.status + ' ' + t; }
}
async function show() { out.textContent = await call('GET', '/state'); }
document.querySelectorAll('button').forEach(b => b.addEventListener('click', async () => {
  const push = document.getElementById('push').value;
  const q = '?push=' + push + (b.dataset.min ? '&minutes=' + b.dataset.min : '');
  out.textContent = await call('POST', '/' + b.dataset.act + q);
}));
if (token) show();
</script>
</body></html>`;
