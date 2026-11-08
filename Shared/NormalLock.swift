import Foundation
import FamilyControls
import ManagedSettings

// 通常ロック（本番設計 §9.9・§9.10・2026-11-08 本人と決定）。
//
//   利用者が iOS のアプリ一覧の画面（FamilyActivityPicker）で選んだ「残すアプリ」以外を全部止める、軽いロック（§9.10）。
//   - 止め方は shield.applicationCategories = .all(except: 残すアプリ)。縁側と iOS 標準アプリは止まらない（Shield.lockNow）
//   - 残すアプリはどれでも選べる（スーパーロックの許可一覧には縛らない）。初期値は空（＝縁側と標準アプリ以外は全部止まる）。
//     §9.9 の「止めるアプリ」の選択（normal-selection.json）は引き継がずに捨てる（Shield.cleanupLegacy）
//   - 残すアプリは手動とスケジュールの通常ロックで共通の1組
//   - 期限まで外れない。始め方は手動（30分〜8時間）とスケジュール（Shared/Schedule.swift）の2つ
//   - 残すアプリはロック中も足し・外しでき、即反映（足したアプリはその場で使える・本人承知の逃げ道）。
//     選び直せるので、スーパーロックのようなアプリの削除の禁止・日付と時刻の固定はしない（効き目が無い割に重い）
//   - ウェブサイトは止めない（§8.5）。ピッカーでサイトやカテゴリを選んでも使わない（例外に入れられるのはアプリだけ）
//   - 期限の扱いはスーパーロック（StrictLock）と同じ作り: 期限をファイルに置き、終わりの目覚まし（.normalLockEnd）・
//     本体の起動と見回り・止めたアプリの画面の「閉じる」のどれでも、期限後の reconcile で外れる
//   - スーパーロックと重なったらスーパーが勝つ（Shield.reconcile の1か所で決める）。スーパー中はスーパーの許可一覧だけが効き、
//     通常の残すアプリも止まる

enum NormalLock {
    static let fileKey = "normalLockUntil"
    /// 残すアプリ（§9.10）。アプリのトークンだけを置く
    static let keepFile = "normal-keep.json"
    /// §9.9 の「止めるアプリ」の選択。読まずに消す
    static let legacySelectionFile = "normal-selection.json"
    /// 残すアプリの上限（ManagedSettings の例外は50個まで）
    static let appLimit = 50
    static var tooManyApps: String { "ロックで残すアプリは\(appLimit)個までです。選び直してください。" }
    static let categoriesIgnored = "カテゴリごとは残せません。アプリを1つずつ選んでください（選んだアプリだけを残しました）。"

    static func isActive(_ now: Date = Date()) -> Bool {
        Store.normalLockUntil.map { $0 > now } ?? false
    }

    /// 残すアプリ
    static var keepApps: Set<ApplicationToken> {
        get { Set(Store.codable(keepFile, as: [ApplicationToken].self) ?? []) }
        set { Store.setCodable(keepFile, Array(newValue)) }
    }

    /// ピッカーに渡す選択（残すアプリだけを入れたもの）
    static var keepSelection: FamilyActivitySelection {
        var s = FamilyActivitySelection()
        s.applicationTokens = keepApps
        return s
    }

    /// 期限を確かめる（reconcile から呼ぶ）。期限切れと壊れた値は消し、先すぎる値は切り詰める
    static func resolve(now: Date, grace: TimeInterval) -> (until: Date?, ended: Date?) {
        LockTimer.resolve(key: fileKey, kind: "normalLock", now: now, grace: grace)
    }
}

/// 期限ファイルの共通の扱い（スーパーロック・通常ロック）
enum LockTimer {
    /// 先すぎる期限の切り詰め先（秒）。スケジュールの1回の最長（24時間未満）を収める。
    /// どんな値でも、いまから24時間で必ず終わる
    static let maxAhead: TimeInterval = 24 * 3600

    static func resolve(key: String, kind: String, now: Date, grace: TimeInterval) -> (until: Date?, ended: Date?) {
        guard Store.data(key) != nil else { return (nil, nil) }
        guard let until = Store.string(key).flatMap(ISO.parse) else {
            Store.setString(key, nil)
            Log.add(kind: kind, ok: false, error: "期限が読めないので外した")
            return (nil, nil)
        }
        if until <= now.addingTimeInterval(grace) {
            Store.setString(key, nil)
            return (nil, until)
        }
        let limit = now.addingTimeInterval(maxAhead)
        if until > limit.addingTimeInterval(60) {
            Store.setString(key, ISO.string(limit))
            Log.add(kind: kind, ok: false, error: "期限が先すぎるので切り詰めた",
                    detail: "\(ISO.string(until)) → \(ISO.string(limit))")
            return (limit, nil)
        }
        return (until, nil)
    }

    /// 期限・スケジュールのファイルが在るのに読めない＝最初のロック解除前（データ保護中）。
    /// このあいだは shield も削除禁止も変えない
    static var unreadable: Bool {
        [StrictLock.fileKey, NormalLock.fileKey, NormalLock.keepFile, Schedules.file, Schedules.runsFile].contains { key in
            Store.data(key) == nil && FileManager.default.fileExists(atPath: Store.url(key).path)
        }
    }
}

extension Store {
    /// 通常ロックの終わり（無ければ通常ロックなし）
    static var normalLockUntil: Date? {
        get { string(NormalLock.fileKey).flatMap(ISO.parse) }
        set { setString(NormalLock.fileKey, newValue.map(ISO.string)) }
    }

    /// .runSuperStart を登録したときの対象
    static var runSuperStartFor: Date? {
        get { string("runSuperStartFor").flatMap(ISO.parse) }
        set { setString("runSuperStartFor", newValue.map(ISO.string)) }
    }

    /// .normalLockEnd を登録したときの対象
    static var normalLockEndFor: Date? {
        get { string("normalLockEndFor").flatMap(ISO.parse) }
        set { setString("normalLockEndFor", newValue.map(ISO.string)) }
    }
}
