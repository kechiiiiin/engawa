-- 解除の記録に「種別」と「対象のアプリ数」を足す（2026-10-14 追加の本人判断: アプリ個別の解除）。
-- 足し算だけ。既存の行は kind = NULL（＝全体の時間解除 all として読む）。
-- アプリ名はトークンが不透明で読めないので、サーバーには数だけ置く。
ALTER TABLE unlocks ADD COLUMN kind TEXT;            -- all（全体の時間解除）| apps（アプリ個別の解除）
ALTER TABLE unlocks ADD COLUMN app_count INTEGER;    -- apps のときの対象のアプリ数
