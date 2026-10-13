#!/usr/bin/env python3
"""GET /events から経路別の遅れを表にする（make events）。標準ライブラリだけ。

遅れ = appliedAt − serverChangedAt（端末とサーバーの時計が NTP で合っている前提。
ずれは receivedAt と端末の ts の差で目安を出す）。

出すもの:
  1. 反映（kind=apply）の経路別: 件数・成功・中央値・最大・60秒以内の割合・16分以内の割合
  2. 目覚め（kind=wake）の経路別・6時間区切りの件数（試験1-4: 放置で止まらないか）
  3. しきい値（kind=threshold）の発火一覧（試験2）
  4. 再ロック（kind=relock）・ロック画面の表示（kind=shieldShown）の件数
"""
import argparse
import datetime as dt
import json
import os
import statistics
import sys
import urllib.parse
import urllib.request
from collections import Counter, defaultdict


def parse(ts):
    if not ts:
        return None
    try:
        return dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def fetch(server, token, since):
    url = f"{server.rstrip('/')}/events?since={urllib.parse.quote(since)}&limit=20000"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["events"]


def fmt_s(x):
    return "-" if x is None else f"{x:.1f}s"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="1970-01-01T00:00:00Z")
    ap.add_argument("--json", help="サーバーではなくファイルから読む（GET /events の応答そのまま）")
    a = ap.parse_args()

    if a.json:
        with open(a.json) as f:
            events = json.load(f)["events"]
    else:
        server = os.environ.get("SERVER")
        token_file = os.environ.get("TOKEN_FILE", os.path.expanduser("~/.config/seigen-spike/token"))
        if not server:
            sys.exit("SERVER が無い")
        with open(token_file) as f:
            token = f.read().strip()
        events = fetch(server, token, a.since)

    print(f"記録 {len(events)} 件（since {a.since}）\n")

    # 1. 反映の遅れ
    lat = defaultdict(list)
    counts = Counter()
    fails = Counter()
    for e in events:
        if e.get("kind") != "apply" or e.get("source") == "server":
            continue
        route = e.get("route") or "?"
        counts[route] += 1
        if e.get("ok") is False:
            fails[route] += 1
        a_, s_ = parse(e.get("appliedAt")), parse(e.get("serverChangedAt"))
        if a_ and s_:
            lat[route].append((a_ - s_).total_seconds())

    print("■ 反映の遅れ（appliedAt − serverChangedAt）")
    print(f"{'経路':<8}{'件数':>5}{'失敗':>5}{'中央値':>10}{'最大':>10}{'≤60s':>8}{'≤16分':>8}")
    for route in sorted(counts):
        xs = lat[route]
        med = statistics.median(xs) if xs else None
        mx = max(xs) if xs else None
        r60 = f"{sum(x <= 60 for x in xs) / len(xs) * 100:.0f}%" if xs else "-"
        r16 = f"{sum(x <= 960 for x in xs) / len(xs) * 100:.0f}%" if xs else "-"
        print(f"{route:<8}{counts[route]:>5}{fails[route]:>5}{fmt_s(med):>10}{fmt_s(mx):>10}{r60:>8}{r16:>8}")
    if not counts:
        print("（まだ無い）")

    # R3: push.sh が送った時刻（macPush.ts = SENT_AT）からの遅れ。version で突き合わせ、反映より前の最後の送信を使う
    pushes = defaultdict(list)
    for e in events:
        if e.get("kind") == "macPush" and e.get("route") == "R3" and e.get("version") is not None:
            t = parse(e.get("ts"))
            if t:
                pushes[e["version"]].append(t)
    r3 = []
    for e in events:
        if e.get("kind") != "apply" or e.get("route") != "R3":
            continue
        t = parse(e.get("appliedAt"))
        cands = [p for p in pushes.get(e.get("version"), []) if t and p <= t]
        if t and cands:
            r3.append((e.get("version"), (t - max(cands)).total_seconds()))
    if counts.get("R3"):
        print("\nR3 送信から反映まで（appliedAt − macPush.ts）: ", end="")
        if r3:
            xs = [x for _, x in r3]
            print(f"{len(xs)} 件・中央値 {statistics.median(xs):.1f}s・最大 {max(xs):.1f}s・60秒以内 {sum(x <= 60 for x in xs)}/{len(xs)}")
            for v, x in r3:
                print(f"  v{v}: {x:.1f}s")
        else:
            print("突き合わせられる macPush なし")

    # 試験1-3: アプリを開いてから（foreground）R1 の反映まで
    opened = None
    gaps = []
    for e in sorted(events, key=lambda e: e.get("ts") or ""):
        if e.get("kind") == "foreground":
            opened = parse(e.get("ts"))
        elif e.get("kind") == "apply" and e.get("route") == "R1" and opened:
            t = parse(e.get("appliedAt"))
            if t:
                gaps.append((t - opened).total_seconds())
            opened = None
    if gaps:
        print(f"\nR1 開いてから反映まで: {len(gaps)} 件・最大 {max(gaps):.1f}s・5秒以内 {sum(g <= 5 for g in gaps)}/{len(gaps)}")

    # 時計のずれの目安（端末の ts とサーバーの受信時刻。送信待ちがあるので上限の目安）
    skew = [
        (parse(e.get("receivedAt")) - parse(e.get("ts"))).total_seconds()
        for e in events
        if e.get("source") == "device" and parse(e.get("receivedAt")) and parse(e.get("ts"))
    ]
    if skew:
        print(f"\n時計の目安: 受信 − 端末 ts の最小 {min(skew):.1f}s（負なら端末の時計が進んでいる）")

    # 2. 目覚め（6時間区切り・JST）
    jst = dt.timezone(dt.timedelta(hours=9))
    buckets = defaultdict(Counter)
    for e in events:
        if e.get("kind") != "wake":
            continue
        t = parse(e.get("ts"))
        if not t:
            continue
        t = t.astimezone(jst)
        key = t.strftime("%m-%d ") + f"{t.hour // 6 * 6:02d}時台〜"
        buckets[key][e.get("route") or "?"] += 1
    print("\n■ 目覚め（JST・6時間区切り）")
    if buckets:
        routes = sorted({r for c in buckets.values() for r in c})
        print(f"{'区切り':<16}" + "".join(f"{r:>8}" for r in routes))
        for k in sorted(buckets):
            print(f"{k:<16}" + "".join(f"{buckets[k][r]:>8}" for r in routes))
    else:
        print("（まだ無い）")

    # 3. しきい値
    th = [e for e in events if e.get("kind") in ("threshold", "thresholdWarning")]
    print("\n■ しきい値の発火")
    for e in th:
        t = parse(e.get("ts"))
        print(f"  {t.astimezone(jst).strftime('%m-%d %H:%M:%S') if t else '?'}  {e.get('kind')}  {e.get('detail')}")
    if not th:
        print("（まだ無い）")

    # 試験4: 時間解除の終わり（unlockUntil）から再ロックまで（appliedAt − unlockUntil）
    print("\n■ 試験4 再ロック（appliedAt − unlockUntil）")
    rl = []
    for e in events:
        if e.get("kind") != "relock" or not e.get("appliedAt"):
            continue
        d = e.get("detail") or ""
        until = parse(d.split("unlockUntil=", 1)[1].split()[0]) if "unlockUntil=" in d else None
        t = parse(e.get("appliedAt"))
        if until and t:
            rl.append((t, e.get("route"), (t - until).total_seconds()))
    for t, route, x in rl:
        print(f"  {t.astimezone(jst).strftime('%m-%d %H:%M:%S')}  {route:<14}{x / 60:6.1f}分（{x:.0f}s）")
    if rl:
        print(f"  最大 {max(x for _, _, x in rl) / 60:.1f}分（解除15分なら 15〜17分＝この値が 0〜2分なら本命の合格）")
    else:
        print("（まだ無い）")

    # 4. その他
    other = Counter(e.get("kind") for e in events if e.get("kind") in ("relock", "shieldShown", "shieldAction", "macPush", "serverPush"))
    print("\n■ その他の件数: " + (", ".join(f"{k}={v}" for k, v in sorted(other.items())) or "なし"))
    shown = [e.get("detail") or "" for e in events if e.get("kind") == "shieldShown"]
    if shown:
        print(f"  ロック画面の文言の種類: {len(set(s.split(' idea=')[-1] for s in shown))}（表示 {len(shown)} 回）")


if __name__ == "__main__":
    main()
