import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

// 枠（1日の使用時間）と自動ロック。本番設計 §3。
//
// ★ 数え方の差し替え点はこのファイルだけ（試験2 が未了のため）。
//   - CountMode            … どちらの数え方か（settings.json の countMode）
//   - usedMinutes(...)     … 段階イベントの値から使用時間を出す
//   - events(...)          … 監視 daily に並べるイベント
//   - isExhausted(...)     … 枠を使い切ったか
//   他のファイルに数え方の if を書かないこと。
//
// 監視 daily: リセット時刻〜翌日のリセット時刻の1分前（repeats）。段階イベントは
// 「使っているあいだ数分ごとに MonitorExt が起きる目覚まし」も兼ねる。

enum CountMode: String, Codable, CaseIterable {
    /// 許可アプリ込みで数える（形B）。初期値
    case inclusive
    /// 許可アプリを除いて数える（形A: all − allowed）
    case excludeAllowed

    var label: String {
        switch self {
        case .inclusive: return "許可アプリ込み（全使用時間）"
        case .excludeAllowed: return "許可アプリを除く（差し引き）"
        }
    }
}

/// 今日（リセット基準）の使用状況。MonitorExt が段階イベントのたびに書く
struct UsageState: Codable, Equatable {
    /// この期間の始まり（リセット時刻）。今の期間と違えば古い記録なので0から
    var periodStart: String
    /// 最後に発火した all-k の k（すべての使用）
    var allMin = 0
    /// 最後に発火した allowed-k の k（許可アプリだけ）
    var allowedMin = 0
    /// ちょうど枠の時間のイベント quota が発火したときの枠（inclusive 用。枠を変えたら効かない）
    var quotaHitFor: Int?
    var updatedAt: String?
}

extension DeviceActivityName {
    static let daily = Self("daily")   // 枠の監視（段階イベント＋quota）
}

enum Quota {
    static let quotaEvent = DeviceActivityEvent.Name("quota")
    static func allEvent(_ k: Int) -> DeviceActivityEvent.Name { .init("all-\(k)") }
    static func allowedEvent(_ k: Int) -> DeviceActivityEvent.Name { .init("allowed-\(k)") }

    /// 段階の刻み（分）。登録を断られたら粗くして取り直す
    static let stepCandidates = [5, 10, 15, 30]

    // MARK: ★差し替え点

    /// 使用時間（分）
    static func usedMinutes(_ u: UsageState, mode: CountMode) -> Int {
        switch mode {
        case .inclusive: return u.allMin
        case .excludeAllowed: return max(0, u.allMin - u.allowedMin)
        }
    }

    /// 枠を使い切ったか
    static func isExhausted(_ u: UsageState, settings s: AppSettings) -> Bool {
        switch s.countMode {
        case .inclusive:
            // 段階より正確な quota イベントを優先。段階の値でも超えていれば使い切り
            return u.quotaHitFor == s.quotaMinutes || usedMinutes(u, mode: .inclusive) >= s.quotaMinutes
        case .excludeAllowed:
            return usedMinutes(u, mode: .excludeAllowed) >= s.quotaMinutes
        }
    }

    /// 監視 daily に並べるイベント
    static func events(settings s: AppSettings, step: Int,
                       selection sel: FamilyActivitySelection) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        var ev: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        let quota = s.quotaMinutes
        let hasAllowed = !(sel.applicationTokens.isEmpty && sel.webDomainTokens.isEmpty && sel.categoryTokens.isEmpty)
        switch s.countMode {
        case .inclusive:
            // 枠の少し先まで細かい段階（表示用・目覚まし用）＋ちょうど枠の quota（ロック用）
            for k in allThresholds(step: step, fineUntil: quota + 60) {
                ev[allEvent(k)] = event(threshold: k)
            }
            ev[quotaEvent] = event(threshold: quota)
        case .excludeAllowed:
            // 差し引くので、all は許可アプリの分だけ先まで細かく要る（4時間ぶん余裕）
            for k in allThresholds(step: step, fineUntil: quota + 240) {
                ev[allEvent(k)] = event(threshold: k)
            }
            // 許可アプリが空のときは登録しない（3つとも空だと「すべて」になってしまう）
            if hasAllowed {
                for k in stride(from: step, through: 240, by: step) {
                    ev[allowedEvent(k)] = DeviceActivityEvent(applications: sel.applicationTokens,
                                                              categories: sel.categoryTokens,
                                                              webDomains: sel.webDomainTokens,
                                                              threshold: Wake.minutes(k),
                                                              includesPastActivity: true)
                }
            }
        }
        return ev
    }

    /// all-k の段: fineUntil までは step 刻み、その先は 1435分まで30分刻み。
    /// 枠を越えて（時間解除で）使い続けても MonitorExt が起き続け、relock の自己修復（reconcile）が止まらないように
    static func allThresholds(step: Int, fineUntil: Int) -> [Int] {
        let limit = 1435
        let fineEnd = min(fineUntil, limit)
        var ks = Array(stride(from: step, through: fineEnd, by: step))
        var k = ((ks.last ?? 0) / 30 + 1) * 30   // 細かい段の次の30分区切りから
        while k <= limit { ks.append(k); k += 30 }
        return ks
    }

    /// すべての使用（3つとも空）。途中で登録し直しても今日の分から数えるよう includesPastActivity
    private static func event(threshold k: Int) -> DeviceActivityEvent {
        DeviceActivityEvent(threshold: Wake.minutes(k), includesPastActivity: true)
    }

    // MARK: 期間（リセット時刻基準）

    /// 実際に登録できたリセット時刻（日をまたぐ間隔が断られたら 0:00 になる）
    static var effectiveResetMinutes: Int {
        Int(Store.string("dailyResetMinutes") ?? "") ?? Store.settings.resetMinutes
    }

    /// now を含む期間の始まり
    static func periodStart(_ now: Date = Date(), resetMinutes: Int = effectiveResetMinutes) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now).addingTimeInterval(TimeInterval(resetMinutes * 60))
        return now >= today ? today : cal.date(byAdding: .day, value: -1, to: today) ?? today
    }

    static func nextReset(_ now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: periodStart(now)) ?? now
    }

    // MARK: 使用状況の読み書き

    /// 今の期間の使用状況（期間が変わっていれば0から。intervalDidStart の取りこぼしの自己修復）
    static func usage(_ now: Date = Date()) -> UsageState {
        let start = ISO.string(periodStart(now))
        if let u = Store.codable("usage.json", as: UsageState.self), u.periodStart == start { return u }
        return UsageState(periodStart: start)
    }

    static func saveUsage(_ u: UsageState) {
        var v = u
        v.updatedAt = ISO.now
        Store.setCodable("usage.json", v)
    }

    /// intervalDidStart(daily): 保存済みの期間が今の期間と違うときだけ0から（同じ期間の再登録・
    /// 重複の呼び出しで今日の使用時間を消さない）。リセット時刻の少し前に呼ばれても新しい期間を指すよう +120秒で見る
    static func startNewPeriod() {
        let start = ISO.string(periodStart(Date().addingTimeInterval(120)))
        if let u = Store.codable("usage.json", as: UsageState.self), u.periodStart == start {
            Log.add(kind: "quotaReset", route: "daily", ok: true, detail: "同じ期間なので0にしない periodStart=\(start)")
            return
        }
        saveUsage(UsageState(periodStart: start))
        Log.add(kind: "quotaReset", route: "daily", detail: "periodStart=\(start)")
    }

    /// 段階イベント・quota の発火を記録する。早発火（期間の経過時間より大きい値）は記録して無視
    static func record(_ name: DeviceActivityEvent.Name) {
        let raw = name.rawValue
        var u = usage()
        let s = Store.settings
        let elapsed = Int(Date().timeIntervalSince(ISO.parse(u.periodStart) ?? Date()) / 60)
        let k: Int?
        if raw == quotaEvent.rawValue { k = s.quotaMinutes }
        else if raw.hasPrefix("all-") { k = Int(raw.dropFirst(4)) }
        else if raw.hasPrefix("allowed-") { k = Int(raw.dropFirst(8)) }
        else { k = nil }
        guard let k else {
            Log.add(kind: "quotaEvent", route: "daily", ok: false, error: "知らないイベント", detail: raw)
            return
        }
        // 期間が始まってからの経過時間より多く使えるはずがない（iOS の早発火の報告への備え・本番設計 §3.4）
        if k > elapsed + 1 {
            Log.add(kind: "quotaEvent", route: "daily", ok: false, error: "早発火として無視",
                    detail: "\(raw) elapsed=\(elapsed)")
            return
        }
        let before = isExhausted(u, settings: s)
        if raw == quotaEvent.rawValue { u.quotaHitFor = s.quotaMinutes }
        else if raw.hasPrefix("all-") { u.allMin = max(u.allMin, k) }
        else { u.allowedMin = max(u.allowedMin, k) }
        saveUsage(u)
        let after = isExhausted(u, settings: s)
        Log.add(kind: after && !before ? "quotaExhausted" : "quotaEvent", route: "daily", ok: true,
                detail: "\(raw) used=\(usedMinutes(u, mode: s.countMode)) quota=\(s.quotaMinutes) mode=\(s.countMode.rawValue)")
    }

    /// 試験2 の「E-all 到達でロック」用。今の枠で使い切った印を付ける
    static func markExhaustedForTest() {
        var u = usage()
        u.quotaHitFor = Store.settings.quotaMinutes
        u.allMin = max(u.allMin, Store.settings.quotaMinutes)
        saveUsage(u)
    }

    // MARK: 監視の登録

    /// 監視 daily を（登録し直して）登録する。失敗なら理由
    @discardableResult
    static func arm(reason: String) -> String? {
        let s = Store.settings
        let sel = Shield.loadSelection()
        let center = DeviceActivityCenter()
        center.stopMonitoring([.daily])
        let reset = s.resetMinutes
        var schedules: [(reset: Int, schedule: DeviceActivitySchedule)] = [(reset, schedule(reset: reset))]
        if reset != 0 { schedules.append((0, schedule(reset: 0))) }   // 日をまたぐ間隔が断られたとき
        var errs: [String] = []
        for (r, sch) in schedules {
            for step in stepCandidates {
                let ev = events(settings: s, step: step, selection: sel)
                do {
                    try center.startMonitoring(.daily, during: sch, events: ev)
                    Store.setString("dailyResetMinutes", String(r))
                    Store.setString("dailyStep", String(step))
                    Log.add(kind: "arm", route: "daily", ok: errs.isEmpty, error: errs.isEmpty ? nil : errs.joined(separator: " / "),
                            detail: "\(reason) reset=\(AppSettings.clock(r)) step=\(step) events=\(ev.count) quota=\(s.quotaMinutes) mode=\(s.countMode.rawValue)")
                    return nil
                } catch {
                    errs.append("reset=\(AppSettings.clock(r)) step=\(step) events=\(ev.count): \(Wake.describe(error))")
                }
            }
        }
        let e = errs.joined(separator: " / ")
        Log.add(kind: "arm", route: "daily", ok: false, error: e, detail: reason)
        return e
    }

    /// 登録されていなければ登録する（本体が前面に来たとき）
    static func armIfNeeded() {
        if !DeviceActivityCenter().activities.contains(.daily) { arm(reason: "missing") }
    }

    static var registeredStep: Int? { Int(Store.string("dailyStep") ?? "") }

    private static func schedule(reset: Int) -> DeviceActivitySchedule {
        let end = (reset + 1439) % 1440   // リセットの1分前
        return DeviceActivitySchedule(intervalStart: DateComponents(hour: reset / 60, minute: reset % 60),
                                      intervalEnd: DateComponents(hour: end / 60, minute: end % 60),
                                      repeats: true)
    }
}
