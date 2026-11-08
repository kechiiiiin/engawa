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
    static let normalLockEnd = Self("normalLockEnd") // 通常ロックの終わり（§9.9）
    /// 確定済みのスーパーの回の始まり（一発・§9.9。§9.11 では §9.9 から引き継いだ、まだ来ていないスーパーの時間帯と、
    /// 少し早く確定した回の分。スケジュールを編集・削除しても、確定した回のスーパーは来る）。
    /// "sched." で始めない（Schedules.syncMonitoring が古い予定として外さないように）
    static let runSuperStart = Self("runSuperStart")
    /// 最初のロック解除前に起こされて何もできなかったときの拾い直し（一発・15分後）
    static let retryAfterUnlock = Self("retryAfterUnlock")
    /// 旧版が登録していた監視（枠の daily・目覚まし・解除の終わりなど）。起動時に止める（§9.8 C）
    static let legacy: [DeviceActivityName] = ["pollA", "pollB", "relock", "usage", "test2", "daily",
                                                "appRelock", "selfLockEnd", "superLockEnd"].map { Self($0) }
}

/// いま効かせるロック（強い方を優先・§9.9）
enum LockMode: String, Codable {
    case none, normal, strict
}

/// 目覚ましが少し早く・遅く来たときの余裕（MonitorExt が渡す）
struct WakeHint {
    /// この秒数のうちに来るスーパーロックの期限も過ぎたものとして扱う
    var strictGrace: TimeInterval = 0
    /// 同じく通常ロック
    var normalGrace: TimeInterval = 0
    /// スケジュールの始まりがこの秒数のうちに来るなら、始まったものとして扱う
    var lead: TimeInterval = 0
}

enum Shield {
    static let store = ManagedSettingsStore()

    // MARK: 掛け外し（直接呼ぶのは reconcile だけ）

    static var isShielded: Bool { store.shield.applicationCategories != nil || store.shield.applications != nil }

    /// スーパーロック中の例外 = 許可一覧から登録したアプリ（KeepApps.registered・50個まで）
    static func exceptions() -> Set<ApplicationToken> {
        Set(KeepApps.registered.prefix(KeepApps.limit))
    }

    /// 通常ロック中の例外 = 残すアプリ（§9.10）と、スーパーロックで使うアプリの登録の確かめ中の候補（合わせて50個まで）。
    /// 50個に収まらないときは、候補を必ず入れて、残すアプリの方を（効かせる例外の中だけ）減らす。残すアプリの一覧そのものは変えない。
    /// 減らした残すアプリは確かめのあいだだけ止まる（止まる側に倒す）。候補を落とすと、その候補がカテゴリの止めにも掛かって
    /// 登録できなくなるため。候補は確かめ用のストアで止まったままなので、例外に入れても使えるようにはならない。
    /// 候補を例外に入れるのは、候補を止めるのを確かめ用のストア（アプリ単位）だけにするため。既定のストアのカテゴリでも
    /// 止まっていると、ロック画面とボタンがアプリ版・カテゴリ版のどちらで呼ばれるか決まらず、登録できないおそれがある
    /// （推測・要実機）。候補は確かめ用のストアで止まったままなので、使えるようにはならない。
    /// 確かめが終われば次の reconcile で例外から外れ、通常ロックで止まる
    static func normalExceptions() -> Set<ApplicationToken> {
        let keep = NormalLock.keepApps
        guard KeepApps.isVerifying, let pending = KeepApps.store.shield.applications, !pending.isEmpty else {
            return Set(keep.prefix(NormalLock.appLimit))
        }
        // 候補は確かめを始めるときに50個までに抑えてある（AppModel.startKeepVerify）。念のためここでも上限で切る
        let candidates = Set(pending.prefix(NormalLock.appLimit))
        let rest = keep.subtracting(candidates)
        return candidates.union(rest.prefix(max(0, NormalLock.appLimit - candidates.count)))
    }

    /// 縁側自身は `apps` に入れなくても止まらない: FamilyControls で認可されたアプリは ManagedSettings の
    /// block・shield の対象外（Apple Frameworks Engineer, 2025-05, developer.apple.com/forums/thread/783310）。
    /// 自分の ApplicationToken はコードで作れない（Token は Codable の init だけ・SDK の swiftinterface）ので、
    /// 例外に足す手段も無い。実機（直入れ版・TestFlight 版）で縁側が止まらないことを確認済み（2026-11-08）。
    /// webDomainCategories は reconcile がスーパーロックの有無だけで決める
    static func lockNow(apps: Set<ApplicationToken>) {
        store.shield.applications = nil
        store.shield.applicationCategories = .all(except: apps)
    }


    static func unlockNow() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
        Store.shieldKey = nil
    }

    // MARK: 決め方（§9.9: 強い方を優先する合成はここだけで決める）
    //
    //   スーパーロックの期限 > いま            → スーパーロック（登録済みのアプリ以外を全部・ウェブサイトも全部）
    //   そうでなく、通常ロックの期限 > いま      → 通常ロック（残すアプリ以外を全部・§9.10。サイトは止めない）
    //   どちらも無い                         → 外す
    //   スケジュールの回の中なら、頭でその回の終わりまで期限を伸ばす（Schedules.apply・縮めない）。
    //   スケジュールのスーパーも手動のスーパーと同じ期限（strictLockUntil）に入るので、削除禁止・日時固定・Web 全止めは
    //   どちらもスーパーのあいだだけ同じに掛かる（§9.11）
    //   外れるのは期限が来たときだけ（resolve を通して外す）。アプリの削除の禁止と日付・時刻の自動設定の固定は
    //   スーパーロックのあいだだけ。スーパーが終わって通常の期限が残っていれば、通常ロックに戻る
    //
    //   shield を書くのは reconcile だけ。

    /// ロックの期限から shield を決めて書き、status.json を更新する。
    /// force: ロック中でも掛け直す（始めたとき）
    @discardableResult
    static func reconcile(route: String, force: Bool = false, hint: WakeHint = WakeHint()) -> LockStatus {
        // 最初のロック解除前は期限が読めないので、何も変えない（解除後の reconcile が決める）
        if LockTimer.unreadable {
            // 拡張の中（予定の始まりなど）で何もできなかったら、少しあとにもう一度起こしてもらう。
            // 本体は端末のロック解除時（applicationProtectedDataDidBecomeAvailable）に決め直す
            if LogRecord.currentProc != "app" { Wake.armRetryAfterUnlock() }
            return LockStatus(locked: isShielded, updatedAt: ISO.now)
        }
        let now = Date()
        Schedules.apply(now: now, lead: hint.lead, strictGrace: hint.strictGrace, normalGrace: hint.normalGrace, route: route)
        let strictState = StrictLock.resolve(now: now, grace: hint.strictGrace)
        let normalState = NormalLock.resolve(now: now, grace: hint.normalGrace)
        let strict = strictState.until
        let normal = normalState.until
        let mode: LockMode = strict != nil ? .strict : (normal != nil ? .normal : .none)
        let isStrict = mode == .strict

        // ウェブサイト: ふだんは止めない（2026-10-19 本人判断・§8.5）。スーパーロック中だけすべてのサイトを止める
        // （§9.8・2026-11-08 本人）。通常ロックでも止めない。旧版からの引き継ぎで掛かったままの分も、
        // スーパーロックでなければ reconcile を1回通れば必ず外す（自己修復）。shield の分岐に関係なく、毎回ここで合わせる
        if isStrict {
            if store.shield.webDomainCategories == nil { store.shield.webDomainCategories = .all() }
        } else if store.shield.webDomainCategories != nil {
            store.shield.webDomainCategories = nil
        }
        // アプリの削除の禁止と日付・時刻の自動設定の固定はスーパーロックのあいだだけ（時計を進めて期限を越えさせない）。
        // 通常ロックは残すアプリを選び直せる軽いロックなので掛けない（§9.9・§9.10）
        if (store.application.denyAppRemoval ?? false) != isStrict {
            store.application.denyAppRemoval = isStrict ? true : nil
            Log.add(kind: "denyAppRemoval", route: route, detail: isStrict ? "禁止" : "解いた")
        }
        if (store.dateAndTime.requireAutomaticDateAndTime ?? false) != isStrict {
            store.dateAndTime.requireAutomaticDateAndTime = isStrict ? true : nil
            Log.add(kind: "requireAutomaticDateAndTime", route: route, detail: isStrict ? "固定" : "解いた")
        }

        let was = isShielded
        var rewritten = false
        switch mode {
        case .strict:
            let apps = exceptions()
            let key = ShieldKey.make(mode: .strict, apps: apps)
            if !was || force || Store.shieldKey != key {
                lockNow(apps: apps)
                Store.shieldKey = key
                rewritten = was
            }
        case .normal:
            // 止め方はスーパーロックと同じ（例外が違うだけ・§9.10）。指紋に mode が入るので、スーパーとの行き来でも書き直す
            let apps = normalExceptions()
            let key = ShieldKey.make(mode: .normal, apps: apps)
            if !was || force || Store.shieldKey != key {
                lockNow(apps: apps)
                Store.shieldKey = key
                rewritten = was
            }
        case .none:
            if was || Store.shieldKey != nil { unlockNow() }
        }
        let now2 = isShielded
        let expectShield = mode != .none
        if was != now2 || now2 != expectShield || rewritten || strictState.ended != nil || normalState.ended != nil {
            let ok = now2 == expectShield
            var detail = "mode=\(mode.rawValue)"
            if let e = strictState.ended { detail += " strictLockUntil=\(ISO.string(e))（終わり）" }
            if let e = normalState.ended { detail += " normalLockUntil=\(ISO.string(e))（終わり）" }
            if let strict { detail += " strictLockUntil=\(ISO.string(strict))" }
            if let normal { detail += " normalLockUntil=\(ISO.string(normal))" }
            if rewritten { detail += " 書き直し" }
            Log.add(LogRecord(kind: "shield", route: route, locked: mode != .none, appliedAt: ISO.now, ok: ok,
                              error: ok ? nil : "読み戻しで shield=\(now2 ? "あり" : "なし")", detail: detail))
        }
        // 期限の目覚まし（変わったときだけ登録し直す）
        Wake.armExpiryWakes(route: route)
        let st = LockStatus(locked: mode != .none, updatedAt: ISO.now, strictLockUntil: strict.map(ISO.string),
                            normalLockUntil: normal.map(ISO.string), mode: mode.rawValue)
        Store.setCodable("status.json", st)
        return st
    }

    /// スーパーロックを始める。断るときは理由を返し、何も変えない。
    /// 終わりの目覚ましを予約できないときは始めない（閉じ込めないため）
    static func startStrictLock(minutes: Int) -> String? {
        let now = Date()
        guard AuthorizationCenter.shared.authorizationStatus == .approved else { return "スクリーンタイムの許可がまだです。" }
        guard StrictLock.minuteChoices.contains(minutes) else { return "時間を選んでください。" }
        guard !StrictLock.isActive(now) else { return "すでにスーパーロック中です。" }
        guard KeepApps.registered.count <= KeepApps.limit else { return StrictLock.tooManyKeepApps }
        let until = now.addingTimeInterval(TimeInterval(minutes * 60))
        if let e = Wake.armEnd(.strictLockEnd, at: until) {
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

    /// 通常ロックを始める（§9.9）。断るときは理由を返し、何も変えない。
    /// 終わりの目覚ましを予約できないときは始めない（閉じ込めないため）。スーパーロック中でも始められる
    /// （スーパーが終わったあとに通常ロックが残る）
    static func startNormalLock(minutes: Int) -> String? {
        let now = Date()
        guard AuthorizationCenter.shared.authorizationStatus == .approved else { return "スクリーンタイムの許可がまだです。" }
        guard StrictLock.minuteChoices.contains(minutes) else { return "時間を選んでください。" }
        guard !NormalLock.isActive(now) else { return "すでにロック中です。" }
        // 残すアプリは空でもよい（縁側と標準アプリ以外が全部止まる・§9.10）
        let keep = NormalLock.keepApps
        guard keep.count <= NormalLock.appLimit else { return NormalLock.tooManyApps }
        let until = now.addingTimeInterval(TimeInterval(minutes * 60))
        if let e = Wake.armEnd(.normalLockEnd, at: until) {
            Log.add(kind: "normalLock", route: "app", ok: false, error: e, detail: "目覚ましを予約できないので始めない")
            return "ロックの終わりを予約できませんでした。もう一度お試しください。"
        }
        Store.normalLockEndFor = until
        Store.normalLockUntil = until
        guard Store.normalLockUntil != nil else {
            reconcile(route: "normalLock")
            return "ロックを保存できませんでした。もう一度お試しください。"
        }
        let st = reconcile(route: "normalLock", force: true)
        Log.add(LogRecord(kind: "normalLock", route: "app", locked: st.locked, appliedAt: ISO.now, ok: st.locked,
                          detail: "minutes=\(minutes) until=\(ISO.string(until)) keep=\(keep.count)"))
        return nil
    }

    /// 通常ロックで残すアプリを選び直す（§9.10: ロック中もできる・即反映。足したアプリはその場で使え、外すとその場で止まる）。
    /// アプリだけを使い、カテゴリとサイトは捨てる（例外に入れられない）。断るとき・捨てたものがあるときは理由
    static func setNormalKeep(_ sel: FamilyActivitySelection) -> String? {
        guard sel.applicationTokens.count <= NormalLock.appLimit else { return NormalLock.tooManyApps }
        NormalLock.keepApps = sel.applicationTokens
        Log.add(kind: "normalKeep", detail: "apps=\(sel.applicationTokens.count) categories=\(sel.categoryTokens.count)（カテゴリは使わない）")
        reconcile(route: "normalKeep")
        return sel.categoryTokens.isEmpty ? nil : NormalLock.categoriesIgnored
    }

    /// 旧版（§9.8 C より前）が残した監視を止める。本体の起動時に毎回呼ぶ（軽い・何度呼んでも同じ）。
    /// 旧版の shield は直後の reconcile が、スーパーロック中でなければ外す
    static func cleanupLegacy() {
        // §9.9 の「止めるアプリ」の選択は引き継がない（§9.10）
        if FileManager.default.fileExists(atPath: Store.url(NormalLock.legacySelectionFile).path) {
            Store.setData(NormalLock.legacySelectionFile, nil)
            Log.add(kind: "cleanupLegacy", detail: "通常ロックの止めるアプリの選択を捨てた")
        }
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
    /// 通常ロックの終わり（§9.9）
    var normalLockUntil: String? = nil
    /// いま効いているロック（LockMode の rawValue）
    var mode: String? = nil
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
    static func make(mode: LockMode, apps: Set<ApplicationToken>, categories: Set<ActivityCategoryToken> = []) -> String {
        let enc = JSONEncoder()
        let strs = apps.compactMap { (try? enc.encode($0)).map { "a" + $0.base64EncodedString() } }.sorted()
        let cats = categories.compactMap { (try? enc.encode($0)).map { "c" + $0.base64EncodedString() } }.sorted()
        let joined = ([mode.rawValue] + strs + cats).joined(separator: "\n")
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

    /// ロックの終わりの目覚まし（スーパーロック・通常ロック）。対象が変わったとき（か、登録が消えているとき）だけ
    /// 登録し直す。登録に失敗しても止まらない（期限後は reconcile が外す）。forceFor: その目覚ましだけ必ず登録し直す
    static func armExpiryWakes(route: String, forceFor: DeviceActivityName? = nil) {
        arm(.strictLockEnd, target: Store.strictLockUntil, prev: Store.strictLockEndFor,
            setPrev: { Store.strictLockEndFor = $0 }, route: route, force: forceFor == .strictLockEnd)
        arm(.normalLockEnd, target: Store.normalLockUntil, prev: Store.normalLockEndFor,
            setPrev: { Store.normalLockEndFor = $0 }, route: route, force: forceFor == .normalLockEnd)
        arm(.runSuperStart, target: Schedules.nextRunStrictStart(after: Date()), prev: Store.runSuperStartFor,
            setPrev: { Store.runSuperStartFor = $0 }, route: route, force: forceFor == .runSuperStart)
    }

    /// 最初のロック解除前（データ保護中）の拾い直し。15分後に一度起こす。先の予約が残っていれば登録し直さない
    /// （起こされてもまだ読めなければ、そのときにまた15分後を予約する）。ファイルには書けないので記録は残らない
    static func armRetryAfterUnlock() {
        let center = DeviceActivityCenter()
        let now = Date()
        if let sc = center.schedule(for: .retryAfterUnlock),
           let start = Calendar.current.date(from: sc.intervalStart), start > now {
            return
        }
        try? center.startMonitoring(.retryAfterUnlock, during: oneShot(from: now.addingTimeInterval(interval)))
    }

    static func arm(_ name: DeviceActivityName, target: Date?, prev: Date?, setPrev: (Date?) -> Void,
                            route: String, force: Bool) {
        let same = prev.map { p in target.map { abs($0.timeIntervalSince(p)) < 1 } ?? false } ?? (target == nil)
        if same && !force {
            // 本体が前面に来たときなどに、登録が消えていないかだけ見る（拡張の中では見ない: 軽くするため）
            guard route == "R1" || route == "launch", let target, target > Date() else { return }
            if DeviceActivityCenter().activities.contains(name) { return }
        }
        guard let target else {
            if prev != nil {
                DeviceActivityCenter().stopMonitoring([name])
                setPrev(nil)
            }
            return
        }
        setPrev(target)
        if let e = armEnd(name, at: max(target, Date().addingTimeInterval(5))) {
            Log.add(kind: "arm", route: name.rawValue, ok: false, error: e,
                    detail: "\(route) target=\(ISO.string(target))（期限後は自己修復に任せる）")
        }
    }

    /// ロックの終わりの目覚まし。間隔が短すぎると言われたら16分で取り直す。失敗なら理由
    static func armEnd(_ name: DeviceActivityName, at start: Date) -> String? {
        let center = DeviceActivityCenter()
        do {
            try center.startMonitoring(name, during: oneShot(from: start))
            return nil
        } catch let first as DeviceActivityCenter.MonitoringError {
            guard case .intervalTooShort = first else { return describe(first) }
            do {
                try center.startMonitoring(name, during: oneShot(from: start, length: 16 * 60))
                return nil
            } catch {
                return "\(describe(first)) / \(describe(error))"
            }
        } catch {
            return describe(error)
        }
    }
}
