// Worker から APNs へ送る（試作では「余力があれば」の経路。まず Mac の tools/push.sh で試す）。
// JWT（ES256）は WebCrypto で署名する。鍵が無ければ送らずに理由を返す。

export interface ApnsEnv {
  APNS_KEY?: string; // .p8 の中身（PEM）。wrangler secret
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC: string;
  APNS_HOST: string;
}

export type PushKind = "alert" | "silent";

export interface StatePayload {
  version: number;
  locked: boolean;
  unlockUntil: string | null;
  changedAt: string;
}

export function buildPayload(kind: PushKind, state: StatePayload): Record<string, unknown> {
  if (kind === "silent") {
    return { aps: { "content-available": 1 }, state };
  }
  const what = state.locked ? "ロック" : state.unlockUntil ? `解除（${state.unlockUntil} まで）` : "解除";
  return {
    aps: { alert: { title: "制限試作", body: `${what}の指示 v${state.version}` }, "mutable-content": 1 },
    state,
  };
}

function b64url(data: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function makeJwt(env: ApnsEnv): Promise<string> {
  const pem = (env.APNS_KEY ?? "").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) }));
  const input = `${header}.${claims}`;
  // WebCrypto の ECDSA 署名は r||s（IEEE P1363）で、JWT の形そのまま
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  return `${input}.${b64url(sig)}`;
}

export interface PushResult {
  ok: boolean;
  status?: number;
  error?: string;
  apnsId?: string | null;
}

export async function sendPush(env: ApnsEnv, deviceToken: string, kind: PushKind, state: StatePayload): Promise<PushResult> {
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
    return { ok: false, error: "APNs の鍵が Worker に無い（APNS_KEY / APNS_KEY_ID / APNS_TEAM_ID）" };
  }
  try {
    const jwt = await makeJwt(env);
    const res = await fetch(`https://${env.APNS_HOST}/3/device/${deviceToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": env.APNS_TOPIC,
        "apns-push-type": kind === "alert" ? "alert" : "background",
        "apns-priority": kind === "alert" ? "10" : "5",
        "content-type": "application/json",
      },
      body: JSON.stringify(buildPayload(kind, state)),
    });
    const text = res.ok ? "" : await res.text();
    return { ok: res.ok, status: res.status, apnsId: res.headers.get("apns-id"), error: res.ok ? undefined : text };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}
