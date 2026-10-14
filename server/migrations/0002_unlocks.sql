-- 縁側アプリからの時間解除の記録（理由つき）。2026-10-14 本人判断で「解除はアプリ内（理由＋時間）」。
-- 既存の state／events／device は変えない（72時間放置試験が動いているため・足し算だけ）。
CREATE TABLE unlocks (
  id TEXT PRIMARY KEY,             -- 端末が作る UUID（送り直しの重複を捨てる）
  at TEXT NOT NULL,                -- 押した時刻（端末の時計）
  received_at TEXT NOT NULL,       -- サーバーが受け取った時刻
  minutes INTEGER NOT NULL,
  until TEXT NOT NULL,             -- 解除の終わり
  reason TEXT NOT NULL,            -- 理由（1〜2000字・コードポイントで数える）
  lock_reason TEXT,                -- そのときのロックの理由 none|manual|quota|manualAndQuota
  used_minutes INTEGER,            -- そのときの今日の使用時間（推定）
  quota_minutes INTEGER,           -- そのときの枠
  source TEXT NOT NULL             -- app
);
CREATE INDEX unlocks_at ON unlocks (at);
