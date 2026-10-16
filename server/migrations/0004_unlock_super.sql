-- 解除の記録に「スーパーロック中の解除か」の印を足す（2026-10-16 本人と決定: スーパーロック・本番設計 §10）。
-- 足し算だけ。既存の行は super_lock = NULL（ふだんの解除）。
-- スーパーロック中の解除は書き写し＋理由・10分固定。kind（all／apps）はそのまま使う。
ALTER TABLE unlocks ADD COLUMN super_lock INTEGER;   -- 1 = スーパーロック中の解除
