import Foundation
import ManagedSettings
import FamilyControls
import DeviceActivity

// ロックの掛け外しと、DeviceActivity の監視の登録。本体・MonitorExt・PushExt から使う。
// ManagedSettingsStore の中身は iOS 16 以降、本体と拡張で自動共有される（Apple Frameworks Engineer）。

extension DeviceActivityName {
    static let pollA = Self("pollA")     // R4 目覚まし A
    static let pollB = Self("pollB")     // R4 目覚まし B（A から約7.5分ずらす）
    static let relock = Self("relock")   // 時間解除のあとの再ロック
    static let usage = Self("usage")     // R5 使用量の目覚まし
    static let test2 = Self("test2")     // 試験2 の数え方
    /// 使うアクティビティはこの5つだけ（上限20の報告に対して余裕を持つ。受け入れ条件20）
    static let all: [DeviceActivityName] = [.pollA, .pollB, .relock, .usage, .test2]
}

enum Shield {
    static let store = ManagedSettingsStore()

    // MARK: 許可アプリの選択

    static func loadSelection(_ key: String = "selection.json") -> FamilyActivitySelection {
        Store.codable(key, as: FamilyActivitySelection.self) ?? FamilyActivitySelection()
    }

    static func saveSelection(_ s: FamilyActivitySelection, _ key: String = "selection.json") {
        Store.setCodable(key, s)
    }

    /// 試験2 の E-cats 用（ピッカーで「すべてのカテゴリ」を選んだもの）
    static func loadCatsSelection() -> FamilyActivitySelection { loadSelection("cats.json") }
    static func saveCatsSelection(_ s: FamilyActivitySelection) { saveSelection(s, "cats.json") }

    // MARK: 掛け外し

    static var isShielded: Bool { store.shield.applicationCategories != nil }

    static func lockNow() {
        let sel = loadSelection()
        store.shield.applicationCategories = .all(except: sel.applicationTokens)
        store.shield.webDomainCategories = .all(except: sel.webDomainTokens)
    }

    static func unlockNow() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
    }

    struct ApplyResult {
        var applied: Bool
        var ok: Bool
        var locked: Bool
        var error: String?
        var message: String {
            if !applied { return "反映済み（新しい指示なし）" }
            if ok { return locked ? "ロックを反映しました" : "解除を反映しました" }
            return "失敗: \(error ?? "不明")"
        }
    }

    /// サーバーの状態を反映する（全経路共通）。version > appliedVersion のときだけ
    @discardableResult
    static func apply(_ s: ServerState, route: String) -> ApplyResult {
        let now = Date()
        guard s.version > Store.appliedVersion else {
            // 同じ版でも、時間解除の期限切れで外れたままなら掛け直す（relock の取りこぼしの自己修復）
            healExpiredUnlock()
            return ApplyResult(applied: false, ok: true, locked: isShielded, error: nil)
        }
        var locked = s.locked
        let until = s.unlockUntil.flatMap(ISO.parse)
        if !locked, let until, until <= now { locked = true }   // 期限が切れた時間解除は「ロック」として扱う

        var errors: [String] = []
        if locked {
            lockNow()
            Store.unlockUntil = nil
            Store.relockFor = nil
            DeviceActivityCenter().stopMonitoring([.relock])
        } else {
            unlockNow()
            Store.unlockUntil = until
            if let until {
                // 登録に失敗しても止まらない: 期限切れのあとは healExpiredUnlock()（同期・MonitorExt の全コールバック）が掛け直す
                if let e = Wake.armRelock(at: until) { errors.append("relock 登録失敗（自己修復に任せる）: \(e)") }
            } else {
                Store.relockFor = nil
                DeviceActivityCenter().stopMonitoring([.relock])
            }
        }
        Store.appliedVersion = s.version

        // 読み戻して確かめる（書けたつもりで書けていない、を拾う）
        let readBack = isShielded
        if readBack != locked {
            errors.append("読み戻し不一致（shield=\(readBack ? "あり" : "なし")）")
        }
        let ok = errors.isEmpty
        Log.add(LogRecord(kind: "apply", route: route, version: s.version, locked: locked,
                          serverChangedAt: s.changedAt, appliedAt: ISO.string(now), ok: ok,
                          error: ok ? nil : errors.joined(separator: " / "),
                          detail: s.unlockUntil.map { "unlockUntil=\($0)" }))
        return ApplyResult(applied: true, ok: ok, locked: locked, error: ok ? nil : errors.joined(separator: " / "))
    }

    /// 時間解除の期限が過ぎているのに外れたままなら、ロックを掛け直す（armRelock の失敗や
    /// intervalDidStart(relock) の取りこぼしの自己修復）。掛けたら true
    @discardableResult
    static func healExpiredUnlock(route: String = "sync-fallback") -> Bool {
        guard let until = Store.unlockUntil, until <= Date() else { return false }
        Store.unlockUntil = nil
        Store.relockFor = nil
        guard !isShielded else { return false }   // もう掛かっている（relock が先に効いた）
        lockNow()
        let ok = isShielded
        Log.add(LogRecord(kind: "relock", route: route, version: Store.appliedVersion, locked: true,
                          appliedAt: ISO.now, ok: ok, error: ok ? nil : "読み戻しで shield なし",
                          detail: "unlockUntil=\(ISO.string(until))"))
        return true
    }

    /// 取りに行って反映する（R1・R2・R4・R5）
    @discardableResult
    static func sync(route: String) -> ApplyResult? {
        guard let s = Net.fetchState(route: route) else { return nil }
        return apply(s, route: route)
    }
}

// MARK: - 監視の登録

enum Wake {
    static let interval: TimeInterval = 15 * 60       // 最短15分（公式）
    static let warning = DateComponents(minute: 5)     // 呼ばれる回数を増やせるか試す

    static func comps(_ d: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
    }

    static func oneShot(from start: Date, length: TimeInterval = interval, warning: DateComponents? = nil) -> DeviceActivitySchedule {
        DeviceActivitySchedule(intervalStart: comps(start), intervalEnd: comps(start.addingTimeInterval(length)),
                               repeats: false, warningTime: warning)
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

    /// 時間解除の終わりに始まる間隔を登録し、MonitorExt.intervalDidStart(relock) で掛け直す。失敗なら理由
    static func armRelock(at until: Date) -> String? {
        let start = max(until, Date().addingTimeInterval(5))
        Store.relockFor = until   // MonitorExt はこの値と unlockUntil が一致するときだけ掛ける
        do {
            try DeviceActivityCenter().startMonitoring(.relock, during: oneShot(from: start))
            return nil
        } catch {
            return describe(error)
        }
    }

    // MARK: R4 予定の目覚まし

    /// 1本を start から15分の間隔で登録。間隔が短すぎると言われたら16分で取り直す
    @discardableResult
    static func armPoll(_ name: DeviceActivityName, start: Date) -> String? {
        let center = DeviceActivityCenter()
        do {
            try center.startMonitoring(name, during: oneShot(from: start, warning: warning))
            return nil
        } catch {
            let first = describe(error)
            do {
                try center.startMonitoring(name, during: oneShot(from: start, length: 16 * 60, warning: warning))
                return "\(first) → 16分で登録"
            } catch {
                return "\(first) / \(describe(error))"
            }
        }
    }

    /// A は次の15分区切り、B はその7.5分後から
    static func armBothPolls() -> [String] {
        let now = Date()
        let q = 15.0 * 60
        let nextA = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / q).rounded(.up) * q)
        let a = nextA.timeIntervalSince(now) < 30 ? nextA.addingTimeInterval(q) : nextA
        var errs: [String] = []
        if let e = armPoll(.pollA, start: a) { errs.append("pollA: \(e)") }
        if let e = armPoll(.pollB, start: a.addingTimeInterval(q / 2)) { errs.append("pollB: \(e)") }
        Log.add(kind: "arm", route: "R4", ok: errs.isEmpty, error: errs.isEmpty ? nil : errs.joined(separator: " / "),
                detail: "pollA=\(ISO.string(a))")
        return errs
    }

    static func disarmPolls() {
        DeviceActivityCenter().stopMonitoring([.pollA, .pollB])
        Log.add(kind: "disarm", route: "R4")
    }

    // MARK: R5 使用量の目覚まし

    static func usageEventName(_ k: Int) -> DeviceActivityEvent.Name { .init("u\(k)") }

    static func minutes(_ k: Int) -> DateComponents { DateComponents(hour: k / 60, minute: k % 60) }

    /// 「すべての使用」（3つとも空）のイベントを1分, 2分, … N分で登録。
    /// 断られたら半分にして取り直し、登録できた最大数を記録する（受け入れ条件17）
    @discardableResult
    static func armUsage(n requested: Int) -> (registered: Int, errors: [String]) {
        let center = DeviceActivityCenter()
        let schedule = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                              intervalEnd: DateComponents(hour: 23, minute: 59),
                                              repeats: true)
        var n = requested
        var errs: [String] = []
        while n >= 1 {
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            for k in 1...n {
                events[usageEventName(k)] = DeviceActivityEvent(threshold: minutes(k))
            }
            do {
                try center.startMonitoring(.usage, during: schedule, events: events)
                Store.usageMaxRegistered = max(Store.usageMaxRegistered, n)
                Log.add(kind: "arm", route: "R5", ok: errs.isEmpty, error: errs.isEmpty ? nil : errs.joined(separator: " / "),
                        detail: "requested=\(requested) registered=\(n)")
                return (n, errs)
            } catch {
                errs.append("N=\(n): \(describe(error))")
                n /= 2
            }
        }
        Log.add(kind: "arm", route: "R5", ok: false, error: errs.joined(separator: " / "), detail: "requested=\(requested) registered=0")
        return (0, errs)
    }

    static func disarmUsage() {
        DeviceActivityCenter().stopMonitoring([.usage])
        Log.add(kind: "disarm", route: "R5")
    }

    /// 経路のオン・オフに合わせて登録し直す
    static func reconcile(_ r: Routes) {
        let active = Set(DeviceActivityCenter().activities)
        if r.poll { if !active.contains(.pollA) || !active.contains(.pollB) { _ = armBothPolls() } }
        else if active.contains(.pollA) || active.contains(.pollB) { disarmPolls() }
        if r.usageWake { if !active.contains(.usage) { armUsage(n: Store.usageN) } }
        else if active.contains(.usage) { disarmUsage() }
    }

    // MARK: 試験2

    static let stepMinutes = Array(stride(from: 5, through: 60, by: 5))

    /// 当日4:00〜翌3:59 の1本に E-all／E-cats／E-allowed／段階イベントを並べる。失敗なら理由の一覧
    static func armTest2() -> [String] {
        let sel = Shield.loadSelection()
        let cats = Shield.loadCatsSelection()
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        let ten = minutes(10)
        var notes: [String] = []

        events[.init("E-all")] = DeviceActivityEvent(threshold: ten)
        if cats.categoryTokens.isEmpty {
            notes.append("E-cats は未登録（「すべてのカテゴリ」を選んでいない）")
        } else {
            events[.init("E-cats")] = DeviceActivityEvent(categories: cats.categoryTokens, threshold: ten)
        }
        let hasAllowed = !(sel.applicationTokens.isEmpty && sel.webDomainTokens.isEmpty && sel.categoryTokens.isEmpty)
        if hasAllowed {
            events[.init("E-allowed")] = DeviceActivityEvent(applications: sel.applicationTokens,
                                                             categories: sel.categoryTokens,
                                                             webDomains: sel.webDomainTokens, threshold: ten)
        } else {
            notes.append("E-allowed は未登録（許可アプリが空。空で登録すると「すべて」になってしまう）")
        }
        for k in stepMinutes {
            events[.init("E-step-all-\(k)")] = DeviceActivityEvent(threshold: minutes(k))
            if hasAllowed {
                events[.init("E-step-allowed-\(k)")] = DeviceActivityEvent(applications: sel.applicationTokens,
                                                                         categories: sel.categoryTokens,
                                                                         webDomains: sel.webDomainTokens,
                                                                         threshold: minutes(k))
            }
        }

        let center = DeviceActivityCenter()
        center.stopMonitoring([.test2])
        var errs: [String] = []
        do {
            try center.startMonitoring(.test2, during: DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 4, minute: 0),
                intervalEnd: DateComponents(hour: 3, minute: 59), repeats: true), events: events)
        } catch {
            // 日をまたぐ間隔が断られたら 0:00〜23:59 で取り直す
            errs.append("4:00〜3:59: \(describe(error))")
            do {
                try center.startMonitoring(.test2, during: DeviceActivitySchedule(
                    intervalStart: DateComponents(hour: 0, minute: 0),
                    intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true), events: events)
                notes.append("0:00〜23:59 で登録し直した")
            } catch {
                errs.append("0:00〜23:59: \(describe(error))")
            }
        }
        let ok = errs.isEmpty || notes.contains("0:00〜23:59 で登録し直した")
        Log.add(kind: "arm", route: "test2", ok: ok, error: errs.isEmpty ? nil : errs.joined(separator: " / "),
                detail: "events=\(events.count)" + (notes.isEmpty ? "" : " " + notes.joined(separator: " / ")))
        return errs + notes
    }
}
