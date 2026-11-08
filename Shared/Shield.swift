import Foundation
import ManagedSettings
import FamilyControls
import DeviceActivity
import CryptoKit

// ロックの掛け外しと、終わりの目覚ましの登録。本体・MonitorExt・ShieldActionExt から使う。
// ManagedSettingsStore の中身は iOS 16 以降、本体と拡張で自動共有される（Apple Frameworks Engineer）。
//
// 2026-11-08（本番設計 §9.8 C）: 啓輔さんの版もベータ版と同じ作りにした。残っているロックはスーパーロック
// （型名は StrictLock・§9.6）だけ。枠・手動ロック（サーバー）・セルフロック・書き写しで解除する旧スーパーロック・
// 時間解除・個別解除は、画面と動作の両方から外した。旧版の状態ファイルが残っていても読まない。

extension DeviceActivityName {
    static let strictLockEnd = Self("strictLockEnd") // スーパーロック（厳格ロック）の終わり（§9.6）
    /// 旧版が登録していた監視（枠の daily・目覚まし・解除の終わりなど）。起動時に止める（§9.8 C）
    static let legacy: [DeviceActivityName] = ["pollA", "pollB", "relock", "usage", "test2", "daily",
                                                "appRelock", "selfLockEnd", "superLockEnd"].map { Self($0) }
}

enum Shield {
    static let store = ManagedSettingsStore()

    // MARK: 掛け外し（直接呼ぶのは reconcile だけ）

    static var isShielded: Bool { store.shield.applicationCategories != nil }

    /// ロック中の例外 = 許可一覧から登録したアプリ（KeepApps.registered・50個まで）
    static func exceptions() -> Set<ApplicationToken> {
        Set(KeepApps.registered.prefix(KeepApps.limit))
    }

    /// 縁側自身は `apps` に入れなくても止まらない: FamilyControls で認可されたアプリは ManagedSettings の
    /// block・shield の対象外（Apple Frameworks Engineer, 2025-05, developer.apple.com/forums/thread/783310）。
    /// 自分の ApplicationToken はコードで作れない（Token は Codable の init だけ・SDK の swiftinterface）ので、
    /// 例外に足す手段も無い。実機（直入れ版・TestFlight 版）で縁側が止まらないことを確認済み（2026-11-08）。
    /// webDomainCategories は reconcile がスーパーロックの有無だけで決める
    static func lockNow(apps: Set<ApplicationToken>) {
        store.shield.applicationCategories = .all(except: apps)
        Store.shieldKey = ShieldKey.make(apps: apps)
    }

    static func unlockNow() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
        Store.shieldKey = nil
    }

    // MARK: 決め方
    //
    //   ロックする = スーパーロック（厳格ロック）の期限 > いま
    //   ロック中の例外 = 登録済みのアプリだけ。ウェブサイトは全部止める
    //   外れるのは期限が来たときだけ（resolve を通して外す）。アプリの削除の禁止と日付・時刻の自動設定の固定もこのあいだだけ
    //
    //   shield を書くのは reconcile だけ。

    /// スーパーロックの有無から shield を決めて書き、status.json を更新する。
    /// force: ロック中でも掛け直す（始めたとき）
    /// grace: この秒数のうちに来る期限も過ぎたものとして扱う（終わりの目覚ましが少し早く呼ばれたとき用）
    @discardableResult
    static func reconcile(route: String, force: Bool = false, grace: TimeInterval = 0) -> LockStatus {
        // 最初のロック解除前は期限が読めないので、スーパーロック中なら何も変えない（解除後の reconcile が決める）
        if StrictLock.unreadable {
            return LockStatus(locked: isShielded, updatedAt: ISO.now)
        }
        let now = Date()
        // 余裕は、自分の終わりの目覚ましのときだけ
        let strictState = StrictLock.resolve(now: now, grace: route == DeviceActivityName.strictLockEnd.rawValue ? grace : 0)
        let strict = strictState.until
        let shouldLock = strict != nil

        // ウェブサイト: ふだんは止めない（2026-10-19 本人判断・§8.5）。スーパーロック中だけすべてのサイトを止める
        // （§9.8・2026-11-08 本人）。旧版からの引き継ぎで掛かったままの分も、スーパーロックでなければ
        // reconcile を1回通れば必ず外す（自己修復）。shield の分岐に関係なく、毎回ここで合わせる
        if shouldLock {
            if store.shield.webDomainCategories == nil { store.shield.webDomainCategories = .all() }
        } else if store.shield.webDomainCategories != nil {
            store.shield.webDomainCategories = nil
        }
        // アプリの削除の禁止と日付・時刻の自動設定の固定はスーパーロックのあいだだけ（時計を進めて期限を越えさせない）。
        // shield の分岐に関係なく、毎回ここで合わせる
        if (store.application.denyAppRemoval ?? false) != shouldLock {
            store.application.denyAppRemoval = shouldLock ? true : nil
            Log.add(kind: "denyAppRemoval", route: route, detail: shouldLock ? "禁止" : "解いた")
        }
        if (store.dateAndTime.requireAutomaticDateAndTime ?? false) != shouldLock {
            store.dateAndTime.requireAutomaticDateAndTime = shouldLock ? true : nil
            Log.add(kind: "requireAutomaticDateAndTime", route: route, detail: shouldLock ? "固定" : "解いた")
        }

        let was = isShielded
        var exceptChanged = false
        if shouldLock {
            let apps = exceptions()
            let key = ShieldKey.make(apps: apps)
            exceptChanged = was && Store.shieldKey != key
            if !was || force || exceptChanged { lockNow(apps: apps) }
        } else if was {
            unlockNow()
        }
        let now2 = isShielded
        if was != now2 || now2 != shouldLock || exceptChanged || strictState.ended != nil {
            let ok = now2 == shouldLock
            Log.add(LogRecord(kind: "shield", route: route, locked: shouldLock, appliedAt: ISO.now, ok: ok,
                              error: ok ? nil : "読み戻しで shield=\(now2 ? "あり" : "なし")",
                              detail: (strictState.ended.map { "strictLockUntil=\(ISO.string($0))（終わり）" } ?? "")
                                  + (strict.map { "strictLockUntil=\(ISO.string($0))" } ?? "")
                                  + (exceptChanged ? " 例外を書き直し" : "")))
        }
        // 期限の目覚まし（変わったときだけ登録し直す）
        Wake.armExpiryWakes(route: route)
        let st = LockStatus(locked: shouldLock, updatedAt: ISO.now, strictLockUntil: strict.map(ISO.string))
        Store.setCodable("status.json", st)
        return st
    }

    /// スーパーロックを始める。断るときは理由を返し、何も変えない。
    /// 終わりの目覚ましを予約できないときは始めない（閉じ込めないため）
    static func startStrictLock(minutes: Int) -> String? {
        let now = Date()
        guard AuthorizationCenter.shared.authorizationStatus == .approved else { return "スクリーンタイムの許可がまだです。" }
        guard StrictLock.minuteChoices.contains(minutes) else { return "時間を選んでください。" }
        guard !StrictLock.isActive(now) else { return "すでにロック中です。" }
        guard KeepApps.registered.count <= KeepApps.limit else { return StrictLock.tooManyKeepApps }
        let until = now.addingTimeInterval(TimeInterval(minutes * 60))
        if let e = Wake.armStrictEnd(at: until) {
            Log.add(kind: "strictLock", route: "app", ok: false, error: e, detail: "目覚ましを予約できないので始めない")
            return "ロックの終わりを予約できませんでした。もう一度お試しください。"
        }
        // 登録の確かめ中なら終える（一時的な止めを残さない・ロック中は登録できない）
        KeepApps.stop(route: "strictLock")
        Store.strictLockEndFor = until
        Store.strictLockUntil = until
        guard Store.strictLockUntil != nil else {
            reconcile(route: "strictLock")
            return "ロックを保存できませんでした。もう一度お試しください。"
        }
        // 例外が登録済みのアプリに変わるので、ロック中でも掛け直す
        let st = reconcile(route: "strictLock", force: true)
        Log.add(LogRecord(kind: "strictLock", route: "app", locked: st.locked, appliedAt: ISO.now, ok: st.locked && isShielded,
                          detail: "minutes=\(minutes) until=\(ISO.string(until)) keepApps=\(KeepApps.registered.count)"))
        return nil
    }

    /// 旧版（§9.8 C より前）が残した監視を止める。本体の起動時に毎回呼ぶ（軽い・何度呼んでも同じ）。
    /// 旧版の shield は直後の reconcile が、スーパーロック中でなければ外す
    static func cleanupLegacy() {
        let center = DeviceActivityCenter()
        let left = Set(center.activities).intersection(DeviceActivityName.legacy)
        guard !left.isEmpty else { return }
        center.stopMonitoring(Array(left))
        Log.add(kind: "cleanupLegacy", detail: "旧版の監視を止めた: \(left.map(\.rawValue).sorted().joined(separator: ","))")
    }

    /// 今の状態（書き込みはしない。画面用）
    static var status: LockStatus {
        Store.codable("status.json", as: LockStatus.self) ?? LockStatus(locked: isShielded, updatedAt: ISO.now)
    }
}

/// App Group の status.json（ホーム画面が読む）。旧版の項目（reason・unlockUntil など）は読み捨てる
struct LockStatus: Codable, Equatable {
    /// shield を掛けるべきか
    var locked: Bool
    var updatedAt: String
    /// スーパーロック（厳格ロック）の終わり
    var strictLockUntil: String? = nil
}

extension Store {
    /// 今 shield に書いてある例外の指紋（例外が変わったときだけ書き直す）
    static var shieldKey: String? {
        get { string("shieldKey") }
        set { setString("shieldKey", newValue) }
    }
}

enum ShieldKey {
    /// トークンの集まりの指紋。トークンは並べられないので、1つずつ JSON にして文字列で並べる
    static func make(apps: Set<ApplicationToken>) -> String {
        let enc = JSONEncoder()
        let strs = apps.compactMap { (try? enc.encode($0)).map { $0.base64EncodedString() } }.sorted()
        let joined = (["apps"] + strs).joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 監視の登録

enum Wake {
    static let interval: TimeInterval = 15 * 60       // 最短15分（公式）

    static func comps(_ d: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
    }

    static func oneShot(from start: Date, length: TimeInterval = interval) -> DeviceActivitySchedule {
        DeviceActivitySchedule(intervalStart: comps(start), intervalEnd: comps(start.addingTimeInterval(length)),
                               repeats: false)
    }

    static func describe(_ e: Error) -> String {
        if let m = e as? DeviceActivityCenter.MonitoringError {
            switch m {
            case .excessiveActivities: return "excessiveActivities"
            case .intervalTooLong: return "intervalTooLong"
            case .intervalTooShort: return "intervalTooShort"
            case .invalidDateComponents: return "invalidDateComponents"
            case .unauthorized: return "unauthorized"
            default: return "MonitoringError(\(m))"
            }
        }
        return String(describing: e)
    }

    /// スーパーロックの終わりの目覚まし。対象が変わったとき（か、登録が消えているとき）だけ登録し直す。
    /// 登録に失敗しても止まらない（期限後は reconcile が外す）
    static func armExpiryWakes(route: String, force: Bool = false) {
        let target = Store.strictLockUntil
        let prev = Store.strictLockEndFor
        let same = prev.map { p in target.map { abs($0.timeIntervalSince(p)) < 1 } ?? false } ?? (target == nil)
        if same && !force {
            // 本体が前面に来たときなどに、登録が消えていないかだけ見る（拡張の中では見ない: 軽くするため）
            guard route == "R1" || route == "launch", let target, target > Date() else { return }
            if DeviceActivityCenter().activities.contains(.strictLockEnd) { return }
        }
        guard let target else {
            if prev != nil {
                DeviceActivityCenter().stopMonitoring([.strictLockEnd])
                Store.strictLockEndFor = nil
            }
            return
        }
        Store.strictLockEndFor = target
        if let e = armStrictEnd(at: max(target, Date().addingTimeInterval(5))) {
            Log.add(kind: "arm", route: DeviceActivityName.strictLockEnd.rawValue, ok: false, error: e,
                    detail: "\(route) target=\(ISO.string(target))（期限後は自己修復に任せる）")
        }
    }

    /// スーパーロックの終わりの目覚まし。間隔が短すぎると言われたら16分で取り直す。失敗なら理由
    static func armStrictEnd(at start: Date) -> String? {
        let center = DeviceActivityCenter()
        do {
            try center.startMonitoring(.strictLockEnd, during: oneShot(from: start))
            return nil
        } catch let first as DeviceActivityCenter.MonitoringError {
            guard case .intervalTooShort = first else { return describe(first) }
            do {
                try center.startMonitoring(.strictLockEnd, during: oneShot(from: start, length: 16 * 60))
                return nil
            } catch {
                return "\(describe(first)) / \(describe(error))"
            }
        } catch {
            return describe(error)
        }
    }
}
