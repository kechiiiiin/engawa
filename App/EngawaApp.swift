import SwiftUI
import Combine
import UIKit
import UserNotifications

@main
struct EngawaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() {
        Theme.applyNavigationAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Theme.wood)
                // ダークモードは今回は作らない（2026-10-14）: Info.plist の UIUserInterfaceStyle=Light で固定
        }
    }
}

/// 最初の画面（ホーム）。前面に来るたび R1、前面にいるあいだは20秒ごとに見回る
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView()
                .navigationDestination(for: String.self) { _ in SettingsView() }
        }
        .onChange(of: scenePhase) { _, phase in
            if isDemo { return }
            if phase == .active { model.syncOnForeground() }
        }
        .onReceive(timer) { _ in
            if isDemo { return }
            if scenePhase == .active { model.tick() }
        }
        .onAppear {
            #if DEBUG
            if let mode = UIDemo.mode {
                UIDemo.apply(mode, to: model)
                if mode == "settings" { path = ["settings"] }
                return
            }
            #endif
            model.refresh()
            if model.authStatus == .notDetermined { model.requestAuth() }  // 受け入れ条件9
        }
    }

    private var isDemo: Bool {
        #if DEBUG
        return UIDemo.mode != nil
        #else
        return false
        #endif
    }
}

#if DEBUG
/// 見た目の確認用（シミュレータでスクリーンショットを撮るため）。`-engawaUIDemo <mode>` で起動したときだけ、
/// 表示用の状態を画面の model にだけ入れ、同期・見回り・許可の要求・通知の登録をしない（シミュレータ用）。
/// mode: usable／locked／unlocked／selflock／selflock-custom／sheet／apps／settings。Debug ビルドだけ
enum UIDemo {
    static let mode: String? = UserDefaults.standard.string(forKey: "engawaUIDemo")

    static func apply(_ mode: String, to model: AppModel) {
        let now = Date()
        model.authStatus = .approved
        var s = model.settings
        s.quotaMinutes = 120
        s.resetMinutes = 240
        model.settings = s
        model.unlockMessage = ""
        model.appUnlocks = []
        switch mode {
        case "locked", "sheet", "apps":
            model.usage = UsageState(periodStart: ISO.now, allMin: 120)
            model.status = LockStatus(locked: true, reason: .quota, unlockUntil: nil, unlockSource: nil, updatedAt: ISO.now)
            model.idea = Idea(title: "外を5分歩く", subtitle: "玄関を出て、角を一つ曲がって戻ってくるだけ。")
        case "unlocked":
            model.usage = UsageState(periodStart: ISO.now, allMin: 120)
            model.status = LockStatus(locked: false, reason: .quota, unlockUntil: ISO.string(now.addingTimeInterval(12 * 60)),
                                      unlockSource: "app", updatedAt: ISO.now)
            model.idea = Idea(title: "縁側でお茶を淹れる", subtitle: "")
        case "selflock":
            model.usage = UsageState(periodStart: ISO.now, allMin: 48)
            model.status = LockStatus(locked: true, reason: .selfLock, unlockUntil: nil, unlockSource: nil, updatedAt: ISO.now,
                                      selfLockUntil: ISO.string(now.addingTimeInterval(3600)))
            model.idea = Idea(title: "本を10ページ読む", subtitle: "読みかけの本を開いてみませんか。10ページで止めてもいい。")
        default:   // usable／settings
            model.usage = UsageState(periodStart: ISO.now, allMin: 48)
            model.status = LockStatus(locked: false, reason: .none, unlockUntil: nil, unlockSource: nil, updatedAt: ISO.now)
            model.idea = Idea(title: "縁側でお茶を淹れる", subtitle: "")
        }
        if mode == "settings" {
            model.ideas = [Idea(title: "外を5分歩く", subtitle: ""), Idea(title: "縁側でお茶を淹れる", subtitle: ""),
                           Idea(title: "本を10ページ読む", subtitle: "")]
        }
    }
}
#endif

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.trimLog()   // log.jsonl の trim は本体だけが行う
        LaunchConfig.importFiles()
        LaunchConfig.migrateFromSpike()
        Store.migrateCountModeIfNeeded()
        LaunchConfig.applyArguments()
        Log.add(kind: "launch", detail: Store.routes.summary)
        Shield.reconcile(route: "launch")

        #if DEBUG
        if UIDemo.mode != nil { return true }   // 見た目の確認だけ。通知の許可・APNs 登録はしない
        #endif
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Log.add(kind: "notifAuth", ok: granted, error: error?.localizedDescription)
        }
        application.registerForRemoteNotifications()
        return true
    }

    // 受け入れ条件12: APNs のデバイストークンを POST /device へ
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        DispatchQueue.global().async {
            let body = try? JSONSerialization.data(withJSONObject: [
                "token": hex, "env": "sandbox", "bundle": Bundle.main.bundleIdentifier ?? "",
            ])
            switch Net.request("POST", "/device", body: body) {
            case .success(let (code, _)):
                Log.add(kind: "device", ok: (200..<300).contains(code), error: (200..<300).contains(code) ? nil : "HTTP \(code)")
            case .failure(let e):
                Log.add(kind: "device", ok: false, error: e.localizedDescription)
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.add(kind: "device", ok: false, error: "APNs 登録失敗: \(error.localizedDescription)")
    }

    // 受け入れ条件13: 経路 R2 サイレントプッシュ（終了状態では呼ばれない・公式）
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let isSilent = ((userInfo["aps"] as? [String: Any])?["content-available"] as? Int) == 1
            && (userInfo["aps"] as? [String: Any])?["alert"] == nil
        guard isSilent else { completionHandler(.noData); return }
        Log.add(kind: "wake", route: "R2", detail: "state=\(UIApplication.shared.applicationState.rawValue)")
        guard Store.routes.silentPush else { completionHandler(.noData); return }
        DispatchQueue.global().async {
            let r = Shield.sync(route: "R2")
            Log.flush(timeout: 8)
            completionHandler(r?.applied == true ? .newData : .noData)
        }
    }

    // 端末のロックが解除された（データ保護が解けた）。本体が動いているときだけ呼ばれる
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        Log.add(kind: "deviceUnlocked", detail: "state=\(application.applicationState.rawValue)")
    }

    // 前面にいるときも通知を出す
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// 起動引数とファイル取り込み（受け入れ条件15）。値は画面・記録に出さない
enum LaunchConfig {
    /// `make import-token` が devicectl でアプリのコンテナ tmp/ に置くファイル。取り込んだら消す
    static func importFiles() {
        let tmp = FileManager.default.temporaryDirectory
        let tokenFile = tmp.appendingPathComponent("engawa-import-token")
        if let s = try? String(contentsOf: tokenFile, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { Store.token = t }
            try? FileManager.default.removeItem(at: tokenFile)
            Log.add(kind: "import", ok: !t.isEmpty, detail: "token（値は記録しない）")
        }
        let serverFile = tmp.appendingPathComponent("engawa-import-server")
        if let s = try? String(contentsOf: serverFile, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: t), u.scheme?.hasPrefix("http") == true { Store.serverURL = u }
            try? FileManager.default.removeItem(at: serverFile)
            Log.add(kind: "import", ok: true, detail: "server=\(t)")
        }
    }

    /// 試作（ロックの層が1つ）から入れ替えた直後に1回だけ: 今の shield から手動ロックを推して残し、
    /// 次の同期でサーバーの状態を読み直させる（appliedVersion を0に）
    static func migrateFromSpike() {
        guard Store.string("manualLock") == nil else { return }
        let manual = Store.manualLock   // ファイルが無いときは shield と時間解除から推した値
        Store.manualLock = manual
        Store.appliedVersion = 0
        Log.add(kind: "migrate", detail: "manualLock=\(manual)（試作から。次の同期でサーバーを読み直す）")
    }

    /// `-engawaRoutes poll,alertPush`（書いたものだけオン）／`-engawaServer URL`／`-engawaRegisterTest2 YES`
    /// ⚠️ devicectl で渡すときは引数の前に `--`
    static func applyArguments() {
        let ud = UserDefaults.standard
        if let csv = ud.string(forKey: "engawaRoutes") {
            let r = Routes(csv: csv)
            Store.routes = r
            Log.add(kind: "routes", detail: "起動引数: \(r.summary)")
            Wake.reconcile(r)
        }
        if let s = ud.string(forKey: "engawaServer"), let u = URL(string: s) {
            Store.serverURL = u
        }
        if ud.bool(forKey: "engawaRegisterTest2") {
            _ = Wake.armTest2()
        }
        if let n = ud.string(forKey: "engawaUsageN").flatMap(Int.init) {
            Store.usageN = n
            if Store.routes.usageWake { Wake.armUsage(n: n) }
        }
    }
}
