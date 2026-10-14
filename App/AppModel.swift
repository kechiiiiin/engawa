import SwiftUI
import FamilyControls
import DeviceActivity

// 本体の状態。ホーム・設定・開発者向けで共有する。
// 重い処理（通信・同期）はメインスレッドの外で行う（Net は同期待ちのため）。

final class AppModel: ObservableObject {
    // --- 普段使い ---
    @Published var authStatus: AuthorizationStatus = AuthorizationCenter.shared.authorizationStatus
    @Published var selection: FamilyActivitySelection = Shield.loadSelection()
    @Published var status: LockStatus = Shield.status
    @Published var usage: UsageState = Quota.usage()
    @Published var settings: AppSettings = Store.settings
    @Published var ideas: [Idea] = Ideas.list
    @Published var idea: Idea = Ideas.pick().idea
    @Published var syncing = false
    @Published var unlockMessage: String = ""
    /// 個別に解除中のアプリ（終わりの早い順）
    @Published var appUnlocks: [AppUnlock] = AppUnlocks.active()

    // --- 開発者向け（試作の計測用） ---
    @Published var catsSelection: FamilyActivitySelection = Shield.loadCatsSelection()
    @Published var routes: Routes = Store.routes
    @Published var usageN: Int = Store.usageN
    @Published var serverText: String = Store.serverURL?.absoluteString ?? ""
    @Published var lastResult: String = ""
    @Published var test2Result: String = ""
    @Published var usageResult: String = ""
    @Published var dailyResult: String = ""
    @Published var logs: [LogRecord] = []
    @Published var shielded = Shield.isShielded
    @Published var activities: [String] = []
    @Published var ideasText: String = ""

    var hasToken: Bool { Store.token != nil }
    var usedMinutes: Int { Quota.usedMinutes(usage, mode: settings.countMode) }
    var quotaExhausted: Bool { Quota.isExhausted(usage, settings: settings) }
    var unlockUntil: Date? { status.unlockUntil.flatMap(ISO.parse) }
    var selfLockUntil: Date? { status.selfLockUntil.flatMap(ISO.parse) }

    /// ホームの表示を App Group から読み直す（軽い）
    func refreshHome() {
        authStatus = AuthorizationCenter.shared.authorizationStatus
        status = Shield.status
        appUnlocks = AppUnlocks.active()
        usage = Quota.usage()
        settings = Store.settings
        shielded = Shield.isShielded
    }

    /// 開発者向けの表示も含めて読み直す
    func refresh() {
        refreshHome()
        routes = Store.routes
        logs = Log.recent(300)
        activities = DeviceActivityCenter().activities.map(\.rawValue).sorted()
        ideas = Ideas.list
        if let d = Store.data(Ideas.file), let s = String(data: d, encoding: .utf8) { ideasText = s }
    }

    func requestAuth() {
        Task { @MainActor in
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                Log.add(kind: "auth", ok: true)
                Quota.arm(reason: "auth")
            } catch {
                Log.add(kind: "auth", ok: false, error: String(describing: error))
            }
            self.refresh()
        }
    }

    /// 経路 R1: 前面に来るたび。サーバーの状態を反映し、枠の監視を継ぎ直し、記録を送る
    func syncOnForeground() {
        Log.add(kind: "foreground", route: "R1")   // 試験1-3: 開いてから反映までを測る起点
        Shield.reconcile(route: "R1")              // 通信の前に、期限切れの時間解除などを先に直す
        refreshHome()
        syncing = true
        DispatchQueue.global().async {
            Wake.reconcile(Store.routes)   // 途切れた目覚ましを継ぎ直す
            Quota.armIfNeeded()
            let r = Shield.sync(route: "R1")
            let sent = Log.flush()
            DispatchQueue.main.async {
                self.syncing = false
                self.lastResult = (r?.message ?? "取得失敗（記録を見てください）") + " / 記録: \(sent)"
                self.refresh()
            }
        }
    }

    /// 前面にいるあいだの見回り（時間解除の期限が来たら掛け直す・残り時間の表示）
    func tick() {
        let now = Date()
        let expired = (Store.unlockUntil.map { $0 <= now } ?? false)
            || (Store.selfLockUntil.map { $0 <= now } ?? false)
            || AppUnlocks.all.contains { $0.untilDate <= now }
        if expired { Shield.reconcile(route: "sync-fallback") }
        refreshHome()
    }

    // MARK: 解除（理由＋時間）

    func unlock(minutes: Int, reason: String) {
        let r = Unlocks.normalizeReason(reason)
        guard !r.isEmpty, Unlocks.minuteChoices.contains(minutes) else { return }
        Shield.unlockFromApp(minutes: minutes, reason: r)
        refreshHome()
        unlockMessage = "\(minutes)分 解除しました"
        DispatchQueue.global().async {
            let sent = Unlocks.flush()
            Log.flush()
            DispatchQueue.main.async {
                self.unlockMessage = "\(minutes)分 解除しました（記録: \(sent)）"
                self.refresh()
            }
        }
    }

    // MARK: 個別解除（アプリを選ぶ＋理由＋時間）

    /// 断るときは理由を返す（画面に出す）。済んだら nil
    func unlockApps(_ pick: FamilyActivitySelection, minutes: Int, reason: String) -> String? {
        let r = Unlocks.normalizeReason(reason)
        guard !r.isEmpty else { return "理由を書いてください。" }
        guard Unlocks.minuteChoices.contains(minutes) else { return "時間を選んでください。" }
        switch Shield.unlockAppsFromApp(pick, minutes: minutes, reason: r) {
        case .failure(let e):
            return e.message
        case .success(let rec):
            refreshHome()
            let n = rec.appCount ?? 0
            unlockMessage = "\(n)個のアプリを\(minutes)分 解除しました"
            DispatchQueue.global().async {
                let sent = Unlocks.flush()
                Log.flush()
                DispatchQueue.main.async {
                    self.unlockMessage = "\(n)個のアプリを\(minutes)分 解除しました（記録: \(sent)）"
                    self.refresh()
                }
            }
            return nil
        }
    }

    // MARK: セルフロック（いまからロック）

    func startSelfLock(_ choice: SelfLock.Choice) {
        let until = choice.until()
        let before = Store.selfLockUntil
        Shield.startSelfLock(until: until, choice: choice.rawValue)
        refreshHome()
        let end = Store.selfLockUntil ?? until
        if let before, before >= until {
            unlockMessage = "すでに \(LockReason.clock.string(from: before)) までセルフロック中です（短くはせず、解除中のものもそのままです）"
        } else {
            unlockMessage = "\(LockReason.clock.string(from: end)) までロックしました"
        }
        DispatchQueue.global().async {
            Log.flush()
            DispatchQueue.main.async { self.refresh() }
        }
    }

    // MARK: 設定

    func saveSettings(_ s: AppSettings) {
        let old = Store.settings
        guard s != old else { return }
        Store.settings = s
        Log.add(kind: "settings", detail: "quota=\(s.quotaMinutes) reset=\(AppSettings.clock(s.resetMinutes)) mode=\(s.countMode.rawValue)"
                + "（前 quota=\(old.quotaMinutes) reset=\(AppSettings.clock(old.resetMinutes)) mode=\(old.countMode.rawValue)）")
        let err = Quota.arm(reason: "settings")
        Shield.reconcile(route: "settings")
        dailyResult = err.map { "登録失敗: \($0)" } ?? ""
        refresh()
    }

    func saveSelection(_ s: FamilyActivitySelection) {
        Shield.saveSelection(s)
        Log.add(kind: "selection", detail: "apps=\(s.applicationTokens.count) domains=\(s.webDomainTokens.count) cats=\(s.categoryTokens.count)")
        // ロック中なら許可アプリを入れ直して掛け直す。差し引きで数えるときはイベントも作り直す
        Shield.reconcile(route: "selection", force: true)
        if Store.settings.countMode == .excludeAllowed { Quota.arm(reason: "selection") }
        refresh()
    }

    /// 一覧の編集（1文字ごとに呼ばれる）。記録は画面を離れるときに1回（logIdeasChange）
    func saveIdeas(_ list: [Idea]) {
        guard list != Ideas.list else { return }   // 開いただけでは書かない（既定のままにしておく）
        Ideas.list = list
        ideas = list
    }

    func logIdeasChange() {
        let l = Ideas.list
        Log.add(kind: "ideas", detail: "一覧 \(l.count) 件（使えるもの \(l.filter(\.isUsable).count) 件）")
    }

    func shuffleIdea() {
        let cur = idea
        for _ in 0..<5 {
            idea = Ideas.pick().idea
            if idea != cur { break }
        }
    }

    // MARK: 開発者向け（試作の計測用 UI）

    func saveCats(_ s: FamilyActivitySelection) {
        Shield.saveCatsSelection(s)
        Log.add(kind: "catsSelection", detail: "cats=\(s.categoryTokens.count)")
    }

    func setRoutes(_ r: Routes) {
        Store.routes = r
        Log.add(kind: "routes", detail: "画面: \(r.summary)")
        Wake.reconcile(r)
        refresh()
    }

    func armUsage() {
        Store.usageN = usageN
        let (n, errs) = Wake.armUsage(n: usageN)
        usageResult = "登録できた N=\(n)（これまでの最大 \(Store.usageMaxRegistered)）" + (errs.isEmpty ? "" : "\n" + errs.joined(separator: "\n"))
        refresh()
    }

    func armTest2() {
        let r = Wake.armTest2()
        test2Result = r.isEmpty ? "登録した" : r.joined(separator: "\n")
        refresh()
    }

    func armDaily() {
        let err = Quota.arm(reason: "developer")
        dailyResult = err.map { "登録失敗: \($0)" }
            ?? "登録した（刻み \(Quota.registeredStep ?? 0)分・リセット \(AppSettings.clock(Quota.effectiveResetMinutes))）"
        refresh()
    }

    func saveServer() {
        if let u = URL(string: serverText.trimmingCharacters(in: .whitespaces)), u.scheme?.hasPrefix("http") == true {
            Store.serverURL = u
            lastResult = "サーバー URL を保存"
        } else {
            lastResult = "URL が不正"
        }
    }

    /// 一覧を JSON で直接書き換える（試作の上書きと同じ形 [{title, subtitle}] も読める）
    func saveIdeasJSON() {
        guard let list = try? JSONDecoder().decode([Idea].self, from: Data(ideasText.utf8)) else {
            lastResult = "一覧の JSON が読めない"
            return
        }
        Ideas.list = list
        logIdeasChange()
        lastResult = "一覧を保存（\(list.count) 件）"
        refresh()
    }

    func resetIdeas() {
        Store.setData(Ideas.file, nil)
        Log.add(kind: "ideas", detail: "既定の一覧に戻した")
        ideasText = ""
        refresh()
    }

    func sendLogs() {
        DispatchQueue.global().async {
            let s = Log.flush()
            DispatchQueue.main.async { self.lastResult = "記録: \(s)" }
        }
    }
}
