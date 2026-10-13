#!/usr/bin/env bash
# Mac から APNs（sandbox）へ alert／silent プッシュを送る（経路 R3／R2 の試験用）。
#
#   tools/push.sh alert     # mutable-content の通知 → PushExt（NSE）が state を反映
#   tools/push.sh silent    # content-available → 本体が背景で起きて GET /state（終了状態では起きない・公式）
#
# 鍵などは環境変数か ~/.config/seigen-spike/ から読む（鍵の中身・JWT・トークンは出力しない）:
#   APNS_KEY_PATH  既定: ~/.config/seigen-spike/AuthKey_*.p8 の最初の1つ
#   APNS_KEY_ID    既定: ~/.config/seigen-spike/key-id、無ければファイル名 AuthKey_<KEYID>.p8 から
#   APNS_TEAM_ID   既定: ~/.config/seigen-spike/team-id
#   APNS_TOPIC     既定: jp.kechiiiiin.seigenspike
#   APNS_HOST      既定: api.sandbox.push.apple.com（開発ビルドなので sandbox）
#   DEVICE_TOKEN   既定: サーバーの GET /device
#   SERVER / TOKEN_FILE  サーバー（state とデバイストークンを取る・送った記録を残す）
#   DRY_RUN=1      送らずに、JWT が作れるか・ペイロードだけ確かめる（JWT_OUT=ファイル で JWT を書き出す。使い捨て鍵の検算用）
set -euo pipefail

KIND="${1:-}"
case "$KIND" in alert|silent) ;; *) echo "使い方: $0 alert|silent" >&2; exit 2 ;; esac

CONF="$HOME/.config/seigen-spike"
SERVER="${SERVER:-$(cat "$CONF/server-url" 2>/dev/null || true)}"
TOKEN_FILE="${TOKEN_FILE:-$CONF/token}"
APNS_KEY_PATH="${APNS_KEY_PATH:-$(ls "$CONF"/AuthKey_*.p8 2>/dev/null | head -1 || true)}"
APNS_TOPIC="${APNS_TOPIC:-jp.kechiiiiin.seigenspike}"
APNS_HOST="${APNS_HOST:-api.sandbox.push.apple.com}"

[ -n "$APNS_KEY_PATH" ] && [ -s "$APNS_KEY_PATH" ] || { echo "APNs の鍵（.p8）が無い。APNS_KEY_PATH か $CONF/AuthKey_<KEYID>.p8 に置く" >&2; exit 1; }
if [ -z "${APNS_KEY_ID:-}" ]; then
  APNS_KEY_ID="$(cat "$CONF/key-id" 2>/dev/null || true)"
  [ -n "$APNS_KEY_ID" ] || APNS_KEY_ID="$(basename "$APNS_KEY_PATH" | sed -n 's/^AuthKey_\([A-Z0-9]*\)\.p8$/\1/p')"
fi
APNS_TEAM_ID="${APNS_TEAM_ID:-$(cat "$CONF/team-id" 2>/dev/null || true)}"
[ -n "$APNS_KEY_ID" ] || { echo "APNS_KEY_ID が無い" >&2; exit 1; }
[ -n "$APNS_TEAM_ID" ] || { echo "APNS_TEAM_ID が無い（$CONF/team-id）" >&2; exit 1; }

api() { curl -sS -H "Authorization: Bearer $(cat "$TOKEN_FILE")" "$@"; }

[ -n "$SERVER" ] || { echo "SERVER が無い" >&2; exit 1; }
STATE="$(api "$SERVER/state")"
if [ -z "${DEVICE_TOKEN:-}" ]; then
  DEVICE_TOKEN="$(api "$SERVER/device" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')"
fi
[ -n "$DEVICE_TOKEN" ] || { echo "デバイストークンが無い（アプリを一度開いて POST /device させる）" >&2; exit 1; }

PAYLOAD="$(STATE="$STATE" KIND="$KIND" python3 - <<'PY'
import json, os
s = json.loads(os.environ["STATE"])
state = {k: s.get(k) for k in ("version", "locked", "unlockUntil", "changedAt")}
if os.environ["KIND"] == "silent":
    p = {"aps": {"content-available": 1}, "state": state}
else:
    what = "ロック" if state["locked"] else ("解除（%s まで）" % state["unlockUntil"] if state["unlockUntil"] else "解除")
    p = {"aps": {"alert": {"title": "制限試作", "body": "%sの指示 v%d" % (what, state["version"])}, "mutable-content": 1},
         "state": state}
print(json.dumps(p, ensure_ascii=False, separators=(",", ":")))
PY
)"

# --- JWT（ES256）。openssl の DER 署名を r||s（64 バイト）に直す ---
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
HEADER="$(printf '{"alg":"ES256","kid":"%s"}' "$APNS_KEY_ID" | b64url)"
CLAIMS="$(printf '{"iss":"%s","iat":%d}' "$APNS_TEAM_ID" "$(date +%s)" | b64url)"
SIG="$(printf '%s.%s' "$HEADER" "$CLAIMS" | openssl dgst -sha256 -sign "$APNS_KEY_PATH" -binary | python3 -c '
import sys, base64
d = sys.stdin.buffer.read()
# SEQUENCE { INTEGER r, INTEGER s }
assert d[0] == 0x30
i = 2 if d[1] < 0x80 else 2 + (d[1] & 0x7f)
out = b""
for _ in range(2):
    assert d[i] == 0x02
    n = d[i + 1]; v = d[i + 2:i + 2 + n]; i += 2 + n
    out += v.lstrip(b"\x00").rjust(32, b"\x00")
sys.stdout.write(base64.urlsafe_b64encode(out).decode().rstrip("="))
')"
JWT="$HEADER.$CLAIMS.$SIG"

if [ "$KIND" = alert ]; then PUSH_TYPE=alert; PRIORITY=10; ROUTE=R3; else PUSH_TYPE=background; PRIORITY=5; ROUTE=R2; fi

if [ "${DRY_RUN:-}" = 1 ]; then
  echo "DRY_RUN: JWT を作れた（${#JWT} 文字・中身は出さない）"
  # 署名の検算用（試験用の使い捨て鍵のときだけ使う）
  [ -n "${JWT_OUT:-}" ] && printf '%s' "$JWT" > "$JWT_OUT"
  echo "宛先: https://$APNS_HOST/3/device/${DEVICE_TOKEN:0:8}…  type=$PUSH_TYPE priority=$PRIORITY"
  echo "ペイロード: $PAYLOAD"
  exit 0
fi

SENT_AT="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z"))')"
HDRS="$(mktemp)"; BODY="$(mktemp)"; trap 'rm -f "$HDRS" "$BODY"' EXIT
CODE="$(curl -sS --http2 -o "$BODY" -D "$HDRS" -w '%{http_code}' \
  -H "authorization: bearer $JWT" \
  -H "apns-topic: $APNS_TOPIC" -H "apns-push-type: $PUSH_TYPE" -H "apns-priority: $PRIORITY" \
  -H "content-type: application/json" \
  --data "$PAYLOAD" "https://$APNS_HOST/3/device/$DEVICE_TOKEN")" || CODE=000
APNS_ID="$(grep -i '^apns-id:' "$HDRS" | tr -d '\r' | awk '{print $2}' || true)"
echo "送った時刻 $SENT_AT  HTTP $CODE  apns-id ${APNS_ID:-なし}  $(cat "$BODY")"

# 送った記録をサーバーに残す（遅れの集計で使う）
OK=false; [ "$CODE" = 200 ] && OK=true
EVENT="$(SENT_AT="$SENT_AT" ROUTE="$ROUTE" CODE="$CODE" OK="$OK" BODY="$(cat "$BODY")" STATE="$STATE" python3 -c '
import json, os, uuid
s = json.loads(os.environ["STATE"])
print(json.dumps({"events": [{"id": str(uuid.uuid4()), "ts": os.environ["SENT_AT"], "proc": "mac", "kind": "macPush",
  "route": os.environ["ROUTE"], "version": s.get("version"), "locked": s.get("locked"), "serverChangedAt": s.get("changedAt"),
  "appliedAt": None, "ok": os.environ["OK"] == "true", "error": None if os.environ["OK"] == "true" else (os.environ["BODY"] or "HTTP " + os.environ["CODE"]),
  "detail": "HTTP " + os.environ["CODE"]}]}))
')"
api -X POST -H 'content-type: application/json' --data "$EVENT" "$SERVER/events" >/dev/null || echo "（送った記録をサーバーに残せなかった）" >&2
[ "$CODE" = 200 ]
