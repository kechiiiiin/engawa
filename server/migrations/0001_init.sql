-- 今のロック状態（1行だけ）
CREATE TABLE state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  version INTEGER NOT NULL,
  locked INTEGER NOT NULL,
  unlock_until TEXT,
  changed_at TEXT NOT NULL
);
INSERT INTO state (id, version, locked, unlock_until, changed_at)
VALUES (1, 0, 0, NULL, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));

-- 端末からの記録とサーバー側の操作記録（id で重複を捨てる）
CREATE TABLE events (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,            -- 'device' | 'server'
  received_at TEXT NOT NULL,
  ts TEXT,
  proc TEXT,
  kind TEXT,
  route TEXT,
  version INTEGER,
  locked INTEGER,
  server_changed_at TEXT,
  applied_at TEXT,
  ok INTEGER,
  error TEXT,
  detail TEXT
);
CREATE INDEX events_ts ON events (ts);
CREATE INDEX events_received ON events (received_at);

-- APNs のデバイストークン
CREATE TABLE device (
  token TEXT PRIMARY KEY,
  env TEXT NOT NULL,
  bundle TEXT,
  updated_at TEXT NOT NULL
);
