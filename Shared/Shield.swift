import Foundation
import ManagedSettings
import FamilyControls
import DeviceActivity

// ロックの掛け外し（三層の決め方）と、DeviceActivity の監視の登録。本体・MonitorExt・PushExt から使う。
// ManagedSettingsStore の中身は iOS 16 以降、本体と拡張で自動共有される（Apple Frameworks Engineer）。

extension DeviceActivityName {
    static let pollA = Self("pollA")     // R4 目覚まし A
    static let pollB = Self("pollB")     // R4 目覚まし B（A から約7.5分ずらす）
    static let relock = Self("relock")   // 時間解除のあとの再ロック
    static let usage = Self("usage")     // R5 使用量の目覚まし
    static let test2 = Self("test2")     // 試験2 の数え方
    static let appRelock = Self("appRelock")     // 個別解除の終わり（いちばん早いもの）
    static let selfLockEnd = Self("selfLockEnd") // セルフロックの終わり
    /// 使うアクティビティはこの8つだけ（上限20の報告に対して余裕を持つ。受け入れ条件20）。daily は Quota.swift
    static let all: [DeviceActivityName] = [.pollA, .pollB, .relock, .usage, .test2, .daily, .appRelock, .selfLockEnd]
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

    // MARK: 掛け外し（直接呼ぶのは reconcile だけ）

    static var isShielded: Bool { store.shield.applicationCategories != nil }

    /// 例外 = 許可アプリ ∪ 個別に解除中のアプリ（合わせて50個まで。超える分の個別解除は入れない）
    static func exceptions(_ now: Date = Date()) -> (apps: Set<ApplicationToken>, domains: Set<WebDomainToken>, dropped: Int) {
        let sel = loadSelection()
        var apps = sel.applicationTokens
        var dropped = 0
        for u in AppUnlocks.active(now) where !apps.contains(u.token) {
            if apps.count < AppUnlocks.limit { apps.insert(u.token) } else { dropped += 1 }
        }
        return (apps, sel.webDomainTokens, dropped)
    }

    static func lockNow(apps: Set<ApplicationToken>, domains: Set<WebDomainToken>) {
        store.shield.applicationCategories = .all(except: apps)
        store.shield.webDomainCategories = .all(except: domains)
        Store.shieldKey = ShieldKey.make(apps: apps, domains: domains)
    }

    static func unlockNow() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
        Store.shieldKey = nil
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

    // MARK: 三層（＋セルフロック）の決め方（本番設計 §4.2・2026-10-14 追加の本人判断）
    //
    //   ロックする = (手動ロック || 枠ロック || セルフロック) && !(時間解除の期限 > いま)
    //   ロック中の例外 = 許可アプリ ∪ 個別解除（期限 > いま）
    //
    //   - 手動ロック: サーバーの状態から（ヘスティアが /lock でかける）。時間解除つきの解除（/unlock?minutes=）も
    //                「期限が来たら戻る」ので手動ロックは立ったまま
    //   - 枠ロック:   端末の使用状況から（Quota.isExhausted）。リセット時刻で外れる
    //   - セルフロック: 端末だけ（ホームの「いまからロック」）。期限で終わる。サーバーの state は変えない
    //   - 時間解除:   サーバー（/unlock?minutes=）か縁側アプリ（理由＋時間）。どのロックも一時的に外し、期限で戻る
    //   - 個別解除:   縁側アプリ（アプリを選ぶ＋理由＋時間）。選んだアプリだけ例外に足し、期限で外す
    //
    //   shield を書くのは reconcile だけ。

    /// サーバーの状態を反映する（R1・R2・R3・R4・R5 共通）。version > appliedVersion のときだけ
    @discardableResult
    static func apply(_ s: ServerState, route: String) -> ApplyResult {
        let now = Date()
        guard s.version > Store.appliedVersion else {
            // 同じ版でも、時間解除の期限切れで外れたままなら掛け直す（relock の取りこぼしの自己修復）
            let st = reconcile(route: "sync-fallback")
            return ApplyResult(applied: false, ok: true, locked: st.locked, error: nil)
        }
        let until = s.unlockUntil.flatMap(ISO.parse)
        // 時間解除つきの解除は、期限が来たら手動ロックに戻る（試作の「期限切れの時間解除はロック扱い」と同じ）
        Store.manualLock = s.locked || until != nil

        var errors: [String] = []
        if let until, !s.locked, until > now {
            // サーバーの時間解除で上書きする
            if let e = setUnlock(until: until, source: "server") { errors.append(e) }
        } else if s.locked {
            // 新しいロックの指示は、アプリでの時間解除・個別解除も打ち消す
            clearUnlock()
            clearAppUnlocks(route: route)
        } else if until != nil, Store.unlockSource == "server" {
            // 期限切れのサーバーの時間解除: 手動ロックを立てるだけ。残っているのが古いサーバーの解除なら外す
            clearUnlock()
        }
        // 期限切れのサーバーの時間解除・無期限の解除（locked=false・期限なし）は、アプリでの時間解除を残す
        // 期限なしの解除（ヘスティアからの解除）は、本人が頼んだ解除なのでセルフロックも外す。
        // 期限つきの解除（/unlock?minutes=）は時間解除として全層を一時的に外すだけ（セルフロックは残る）
        if !s.locked, until == nil, let sl = Store.selfLockUntil {
            Store.selfLockUntil = nil
            Log.add(kind: "selfLockCleared", route: route, detail: "サーバーの期限なしの解除で外した selfLockUntil=\(ISO.string(sl))")
        }
        Store.appliedVersion = s.version

        let st = reconcile(route: route)
        // 読み戻して確かめる（書けたつもりで書けていない、を拾う）
        let readBack = isShielded
        if readBack != st.locked {
            errors.append("読み戻し不一致（shield=\(readBack ? "あり" : "なし")）")
        }
        let ok = errors.isEmpty
        Log.add(LogRecord(kind: "apply", route: route, version: s.version, locked: st.locked,
                          serverChangedAt: s.changedAt, appliedAt: ISO.string(now), ok: ok,
                          error: ok ? nil : errors.joined(separator: " / "),
                          detail: "manual=\(Store.manualLock) reason=\(st.reason.rawValue)"
                              + (s.unlockUntil.map { " unlockUntil=\($0)" } ?? "")))
        return ApplyResult(applied: true, ok: ok, locked: st.locked, error: ok ? nil : errors.joined(separator: " / "))
    }

    /// 三層から shield を決めて書き、status.json を更新する。期限切れの時間解除はここで外す（自己修復）。
    /// force: ロック中でも掛け直す（許可アプリを選び直したとき）
    /// grace: この秒数のうちに来る期限も過ぎたものとして扱う（終わりの目覚ましが少し早く呼ばれたとき用）
    @discardableResult
    static func reconcile(route: String, force: Bool = false, grace: TimeInterval = 0) -> LockStatus {
        let now = Date()
        var expired: Date?
        if let until = Store.unlockUntil, until <= now {
            expired = until
            Store.unlockUntil = nil
            Store.relockFor = nil
            Store.unlockSource = nil
        }
        // セルフロック・個別解除の期限切れもここで外す（自己修復）
        var selfEnded: Date?
        if let s = Store.selfLockUntil, s <= now.addingTimeInterval(grace) {
            selfEnded = s
            Store.selfLockUntil = nil
        }
        let pruned = AppUnlocks.prune(before: now.addingTimeInterval(grace))

        let settings = Store.settings
        let manual = Store.manualLock
        let quota = Quota.isExhausted(Quota.usage(now), settings: settings)
        let selfLock = Store.selfLockUntil
        let reason = LockReason(manual: manual, quota: quota, selfLock: selfLock != nil)
        let until = Store.unlockUntil
        let shouldLock = reason != .none && until == nil

        let was = isShielded
        var exceptChanged = false
        var dropped = 0
        if shouldLock {
            let ex = exceptions(now)
            dropped = ex.dropped
            let key = ShieldKey.make(apps: ex.apps, domains: ex.domains)
            exceptChanged = was && Store.shieldKey != key
            if !was || force || exceptChanged { lockNow(apps: ex.apps, domains: ex.domains) }
        } else if was {
            unlockNow()
        }
        let now2 = isShielded
        if was != now2 || expired != nil || now2 != shouldLock || exceptChanged || selfEnded != nil || pruned > 0 {
            let ok = now2 == shouldLock
            Log.add(LogRecord(kind: expired != nil && now2 ? "relock" : "shield", route: route,
                              version: Store.appliedVersion, locked: shouldLock, appliedAt: ISO.now, ok: ok,
                              error: ok ? nil : "読み戻しで shield=\(now2 ? "あり" : "なし")",
                              detail: "reason=\(reason.rawValue)"
                                  + (expired.map { " unlockUntil=\(ISO.string($0))（期限切れ）" } ?? "")
                                  + (until.map { " unlockUntil=\(ISO.string($0))" } ?? "")
                                  + (selfEnded.map { " selfLockUntil=\(ISO.string($0))（終わり）" } ?? "")
                                  + (selfLock.map { " selfLockUntil=\(ISO.string($0))" } ?? "")
                                  + (pruned > 0 ? " appUnlock期限切れ=\(pruned)" : "")
                                  + (exceptChanged ? " 例外を書き直し" : "")
                                  + (dropped > 0 ? " 上限で入れなかった個別解除=\(dropped)" : "")))
        }
        // ロック中の使用を数えないための印（効き始め・外れ。LockSpans）。個別解除があるあいだは、
        // どのアプリの使用か分けられないので「外れている」として数える
        let active = AppUnlocks.active(now)
        // 印の直前に読み直す（ここまでの間に別のプロセスが時間解除・個別解除を入れていたら、効いていない扱い）
        let t = Date()
        let effective = shouldLock && isShielded
            && (Store.unlockUntil.map { $0 <= t } ?? true)
            && AppUnlocks.active(t).isEmpty
        LockSpans.note(effective: effective, usage: Quota.usage(t), route: route)
        // 期限の目覚まし（変わったときだけ登録し直す）
        Wake.armExpiryWakes(route: route)
        let st = LockStatus(locked: shouldLock, reason: reason, unlockUntil: until.map(ISO.string),
                            unlockSource: until == nil ? nil : Store.unlockSource, updatedAt: ISO.now,
                            selfLockUntil: selfLock.map(ISO.string), appUnlockCount: active.count)
        Store.setCodable("status.json", st)
        return st
    }

    /// 時間解除の期限が過ぎているのに外れたままなら、ロックを掛け直す（試作の自己修復 sync-fallback。中身は reconcile）
    @discardableResult
    static func healExpiredUnlock(route: String = "sync-fallback") -> Bool {
        let was = isShielded
        return reconcile(route: route).locked && !was
    }

    /// 時間解除を入れて relock を登録する。失敗なら理由（失敗しても止まらない: 期限後は reconcile が掛け直す）
    @discardableResult
    static func setUnlock(until: Date, source: String) -> String? {
        Store.unlockUntil = until
        Store.unlockSource = source
        if let e = Wake.armRelock(at: until) { return "relock 登録失敗（自己修復に任せる）: \(e)" }
        return nil
    }

    static func clearUnlock() {
        Store.unlockUntil = nil
        Store.relockFor = nil
        Store.unlockSource = nil
        DeviceActivityCenter().stopMonitoring([.relock])
    }

    /// 縁側アプリからの時間解除（理由は必須）。記録を残し、サーバーへ送る待ち行列に入れる
    @discardableResult
    static func unlockFromApp(minutes: Int, reason: String) -> UnlockRecord {
        let now = Date()
        let before = reconcile(route: "app")
        let s = Store.settings
        let used = Quota.usedMinutes(Quota.usage(now), mode: s.countMode)
        let until = now.addingTimeInterval(TimeInterval(minutes * 60))
        let err = setUnlock(until: until, source: "app")
        let st = reconcile(route: "app")
        let rec = UnlockRecord(id: UUID().uuidString, at: ISO.string(now), minutes: minutes, until: ISO.string(until),
                               reason: reason, lockReason: before.reason.rawValue, usedMinutes: used,
                               quotaMinutes: s.quotaMinutes, kind: UnlockRecord.kindAll)
        Unlocks.enqueue(rec)
        Log.add(LogRecord(kind: "appUnlock", route: "app", version: Store.appliedVersion, locked: st.locked,
                          appliedAt: ISO.now, ok: err == nil && !st.locked, error: err,
                          detail: "minutes=\(minutes) lockReason=\(before.reason.rawValue) used=\(used) reason=\(reason)"))
        return rec
    }

    /// 個別解除をすべて外す（新しいロックの指示のとき）
    static func clearAppUnlocks(route: String) {
        let n = AppUnlocks.active().count
        guard n > 0 else { return }
        AppUnlocks.clear()
        Log.add(kind: "appUnlockCleared", route: route, detail: "新しいロックの指示で個別解除 \(n) 件を外した")
    }

    /// 縁側アプリからの個別解除（理由は必須）。選んだアプリを期限つきで例外に足す。断るときは理由を返す
    static func unlockAppsFromApp(_ pick: FamilyActivitySelection, minutes: Int, reason: String) -> Result<UnlockRecord, AppUnlockError> {
        let now = Date()
        let c = AppUnlocks.check(pick, now: now)
        if let e = c.error { return .failure(AppUnlockError(message: e)) }
        guard !c.targets.isEmpty else { return .failure(AppUnlockError(message: "ロックされているアプリを1つ以上選んでください。")) }
        let before = reconcile(route: "appUnlock")
        let s = Store.settings
        let used = Quota.usedMinutes(Quota.usage(now), mode: s.countMode)
        let until = now.addingTimeInterval(TimeInterval(minutes * 60))
        let id = UUID().uuidString
        AppUnlocks.add(c.targets, until: until, recordId: id)
        let st = reconcile(route: "appUnlock")
        let rec = UnlockRecord(id: id, at: ISO.string(now), minutes: minutes, until: ISO.string(until),
                               reason: reason, lockReason: before.reason.rawValue, usedMinutes: used,
                               quotaMinutes: s.quotaMinutes, kind: UnlockRecord.kindApps, appCount: c.targets.count)
        Unlocks.enqueue(rec)
        Log.add(LogRecord(kind: "appUnlockApps", route: "app", version: Store.appliedVersion, locked: st.locked,
                          appliedAt: ISO.now, ok: true,
                          detail: "minutes=\(minutes) apps=\(c.targets.count) lockReason=\(before.reason.rawValue) used=\(used) reason=\(reason)"))
        return .success(rec)
    }

    /// セルフロックをかける（延ばす）。期限は今のものより短くしない。
    /// かけた・延ばしたときは新しいロックの指示なので、時間解除・個別解除は打ち消す（サーバーの /lock と同じ扱い）。
    /// 延ばさなかった（新しい期限 ≤ 今の期限）ときは何も変えない
    @discardableResult
    static func startSelfLock(until: Date, choice: String) -> LockStatus {
        let old = Store.selfLockUntil
        if let old, until <= old {
            let st = reconcile(route: "selfLock")
            Log.add(kind: "selfLock", route: "app", ok: true,
                    detail: "choice=\(choice) until=\(ISO.string(until)) 今の期限 \(ISO.string(old)) より短いので変えない")
            return st
        }
        Store.selfLockUntil = until
        let hadUnlock = Store.unlockUntil
        if hadUnlock != nil { clearUnlock() }
        clearAppUnlocks(route: "selfLock")
        let st = reconcile(route: "selfLock")
        Log.add(LogRecord(kind: "selfLock", route: "app", version: Store.appliedVersion, locked: st.locked,
                          appliedAt: ISO.now, ok: st.locked && isShielded,
                          detail: "choice=\(choice) until=\(ISO.string(until))"
                              + (old.map { " 前=\(ISO.string($0))" } ?? "")
                              + (hadUnlock.map { " 時間解除を打ち消し=\(ISO.string($0))" } ?? "")))
        return st
    }

    /// 取りに行って反映する（R1・R2・R4・R5）
    @discardableResult
    static func sync(route: String) -> ApplyResult? {
        guard let s = Net.fetchState(route: route) else { return nil }
        return apply(s, route: route)
    }

    /// 今の状態（書き込みはしない。画面用）
    static var status: LockStatus {
        Store.codable("status.json", as: LockStatus.self)
            ?? LockStatus(locked: isShielded, reason: .none, unlockUntil: nil, unlockSource: nil, updatedAt: ISO.now)
    }
}

struct AppUnlockError: Error {
    var message: String
}

enum LockReason: String, Codable {
    case none, manual, quota, manualAndQuota
    // セルフロック（2026-10-14 足し算。サーバーの LOCK_REASONS にも足した）
    case selfLock, manualAndSelf, quotaAndSelf, manualAndQuotaAndSelf

    init(manual: Bool, quota: Bool, selfLock: Bool) {
        switch (manual, quota, selfLock) {
        case (false, false, false): self = .none
        case (true, false, false): self = .manual
        case (false, true, false): self = .quota
        case (true, true, false): self = .manualAndQuota
        case (false, false, true): self = .selfLock
        case (true, false, true): self = .manualAndSelf
        case (false, true, true): self = .quotaAndSelf
        case (true, true, true): self = .manualAndQuotaAndSelf
        }
    }

    var hasManual: Bool { [.manual, .manualAndQuota, .manualAndSelf, .manualAndQuotaAndSelf].contains(self) }
    var hasQuota: Bool { [.quota, .manualAndQuota, .quotaAndSelf, .manualAndQuotaAndSelf].contains(self) }
    var hasSelf: Bool { [.selfLock, .manualAndSelf, .quotaAndSelf, .manualAndQuotaAndSelf].contains(self) }

    var label: String { label(selfUntil: nil) }

    /// セルフロックの終わりが分かれば「セルフロック（21:45まで）」と出す
    func label(selfUntil: Date?) -> String {
        if self == .none { return "なし" }
        if self == .manualAndQuota { return "手動ロック・枠も使い切りました" }
        var parts: [String] = []
        if hasManual { parts.append("手動ロック") }
        if hasQuota { parts.append("枠を使い切りました") }
        if hasSelf { parts.append(selfUntil.map { "セルフロック（\(LockReason.clock.string(from: $0))まで）" } ?? "セルフロック") }
        return parts.joined(separator: "・")
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f
    }()
}

/// App Group の status.json（ホーム画面・ShieldConfig が読む）
struct LockStatus: Codable, Equatable {
    /// shield を掛けるべきか
    var locked: Bool
    /// 下にあるロックの理由（時間解除中でも、期限後に戻るロックの理由を出す）
    var reason: LockReason
    /// 時間解除中ならその期限
    var unlockUntil: String?
    /// 時間解除の出どころ（app／server）
    var unlockSource: String?
    var updatedAt: String
    /// セルフロックの終わり（2026-10-14 足し算。古い status.json には無い）
    var selfLockUntil: String? = nil
    /// 個別に解除中のアプリの数
    var appUnlockCount: Int? = nil
}

/// Wake.arm で Store の static を KeyPath で触るための入れ物
final class StoreBox {
    var appRelockFor: Date? {
        get { Store.appRelockFor }
        set { Store.appRelockFor = newValue }
    }
    var selfLockEndFor: Date? {
        get { Store.selfLockEndFor }
        set { Store.selfLockEndFor = newValue }
    }
}

extension Store {
    /// 手動ロック（サーバーの状態から）。ファイルが無い＝試作からの入れ替え直後は、今の shield から推す
    static var manualLock: Bool {
        get {
            if let s = string("manualLock") { return s == "1" }
            return Shield.isShielded || unlockUntil != nil
        }
        set { setString("manualLock", newValue ? "1" : "0") }
    }

    /// 時間解除の出どころ（app／server）
    static var unlockSource: String? {
        get { string("unlockSource") }
        set { setString("unlockSource", newValue) }
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

    /// 個別解除・セルフロックの終わりの目覚まし。対象が変わったとき（か、登録が消えているとき）だけ登録し直す。
    /// 登録に失敗しても止まらない（期限後は reconcile が外す）
    static func armExpiryWakes(route: String, force: Bool = false) {
        arm(.appRelock, target: AppUnlocks.earliestUntil, stored: \.appRelockFor, route: route, force: force)
        arm(.selfLockEnd, target: Store.selfLockUntil, stored: \.selfLockEndFor, route: route, force: force)
    }

    private static func arm(_ name: DeviceActivityName, target: Date?,
                            stored: ReferenceWritableKeyPath<StoreBox, Date?>, route: String, force: Bool) {
        let box = StoreBox()
        let prev = box[keyPath: stored]
        let same = prev.map { p in target.map { abs($0.timeIntervalSince(p)) < 1 } ?? false } ?? (target == nil)
        if same && !force {
            // 本体が前面に来たときなどに、登録が消えていないかだけ見る（拡張の中では見ない: 軽くするため）
            guard route == "R1" || route == "launch", let target, target > Date() else { return }
            if DeviceActivityCenter().activities.contains(name) { return }
        }
        let center = DeviceActivityCenter()
        guard let target else {
            if prev != nil {
                center.stopMonitoring([name])
                box[keyPath: stored] = nil
            }
            return
        }
        box[keyPath: stored] = target
        do {
            try center.startMonitoring(name, during: oneShot(from: max(target, Date().addingTimeInterval(5))))
        } catch {
            Log.add(kind: "arm", route: name.rawValue, ok: false, error: describe(error),
                    detail: "\(route) target=\(ISO.string(target))（期限後は自己修復に任せる）")
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
