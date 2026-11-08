import Foundation

// 厳格ロック（2026-11-04 本人と決定・本番設計 §9.6）。
//
//   時間を選んで始めたら、期限まで解除手段がないロック。2026-11-08（§9.8 C）からは縁側に残る唯一のロック。
//   ロックする = 厳格（期限 > いま）
//   画面上の呼び方は「スーパーロック」（2026-11-08 本人・§9.8。型名は StrictLock のまま）
//   ロック中の例外 = 許可一覧から登録したアプリ（KeepApps.registered）だけ。個別解除は足さない。ウェブサイトは全部止める
//   ロック中はアプリの削除を禁止し、日付と時刻を自動設定に固定する（時計を進めて期限を越えさせない。§9.6）
//
//   - 始めるのは Shield.startStrictLock だけ。外れるのは期限が来たときだけ（Shield.reconcile が resolve を通して外す）
//   - 閉じ込めない: 期限の目覚まし（.strictLockEnd の始まりと、その15分後の終わり）・本体の起動と見回り・
//     止めたアプリの画面の「閉じる」（ShieldAction）のどれでも、期限後の reconcile で外れる。
//     目覚ましを予約できないときは始めない
//   - 壊れた未来の日時・時計を戻したとき: 最長の長さまでに切り詰める（どんな値でも、いまから8時間で必ず終わる）
//   - 読めて日時でないものは「ロックなし」として消す。最初のロック解除前（データ保護で読めない）は何も変えない

enum StrictLock {
    /// 選べる長さ（分）
    static let minuteChoices = [30, 60, 120, 240, 480]
    static let fileKey = "strictLockUntil"
    /// 残すアプリが多すぎるときの断り（ホームの注意・確認画面・Shield で同じ言葉）
    static var tooManyKeepApps: String { "スーパーロックで使えるアプリは\(KeepApps.limit)個までです。登録を減らしてください。" }
    /// 期限がいまより先すぎるときの切り詰め先（秒）。最長の長さ
    static var maxDuration: TimeInterval { TimeInterval((minuteChoices.max() ?? 480) * 60) }

    static func isActive(_ now: Date = Date()) -> Bool {
        Store.strictLockUntil.map { $0 > now } ?? false
    }

    /// ファイルは在るのに読めない＝最初のロック解除前（データ保護中）。このあいだは shield も削除禁止も変えない
    static var unreadable: Bool {
        Store.data(fileKey) == nil && FileManager.default.fileExists(atPath: Store.url(fileKey).path)
    }

    /// 期限を確かめる（reconcile から呼ぶ）。期限切れと壊れた値はここで消し、先すぎる値は切り詰める
    static func resolve(now: Date, grace: TimeInterval) -> (until: Date?, ended: Date?) {
        guard Store.data(fileKey) != nil else { return (nil, nil) }
        guard let until = Store.strictLockUntil else {
            Store.strictLockUntil = nil
            Log.add(kind: "strictLock", ok: false, error: "期限が読めないので外した")
            return (nil, nil)
        }
        if until <= now.addingTimeInterval(grace) {
            Store.strictLockUntil = nil
            return (nil, until)
        }
        let limit = now.addingTimeInterval(maxDuration)
        if until > limit.addingTimeInterval(60) {
            Store.strictLockUntil = limit
            Log.add(kind: "strictLock", ok: false, error: "期限が先すぎるので切り詰めた",
                    detail: "\(ISO.string(until)) → \(ISO.string(limit))")
            return (limit, nil)
        }
        return (until, nil)
    }

    /// 「16:00」。今日でなければ「明日 1:30」
    static func clock(_ d: Date, now: Date = Date()) -> String {
        let t = hm.string(from: d)
        return Calendar.current.isDate(d, inSameDayAs: now) ? t : "明日 \(t)"
    }

    /// 残り時間の言葉（「1時間59分」「1分未満」）
    static func remaining(_ d: Date, now: Date = Date()) -> String {
        let sec = Int(d.timeIntervalSince(now).rounded(.up))
        return sec >= 60 ? duration((sec + 59) / 60) : "1分未満"
    }

    /// 150 → 「2時間30分」
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)分" }
        return m == 0 ? "\(h)時間" : "\(h)時間\(m)分"
    }

    static let hm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f
    }()
}

extension Store {
    /// 厳格ロックの終わり（無ければ厳格ロックなし）
    static var strictLockUntil: Date? {
        get { string(StrictLock.fileKey).flatMap(ISO.parse) }
        set { setString(StrictLock.fileKey, newValue.map(ISO.string)) }
    }

    /// .strictLockEnd を登録したときの対象
    static var strictLockEndFor: Date? {
        get { string("strictLockEndFor").flatMap(ISO.parse) }
        set { setString("strictLockEndFor", newValue.map(ISO.string)) }
    }
}
