import SwiftUI
import UIKit
import UserNotifications

@main
struct SeigenSpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.trimLog()   // log.jsonl の trim は本体だけが行う
        LaunchConfig.importFiles()
        LaunchConfig.applyArguments()
        Log.add(kind: "launch", detail: Store.routes.summary)

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
        let tokenFile = tmp.appendingPathComponent("seigen-import-token")
        if let s = try? String(contentsOf: tokenFile, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { Store.token = t }
            try? FileManager.default.removeItem(at: tokenFile)
            Log.add(kind: "import", ok: !t.isEmpty, detail: "token（値は記録しない）")
        }
        let serverFile = tmp.appendingPathComponent("seigen-import-server")
        if let s = try? String(contentsOf: serverFile, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: t), u.scheme?.hasPrefix("http") == true { Store.serverURL = u }
            try? FileManager.default.removeItem(at: serverFile)
            Log.add(kind: "import", ok: true, detail: "server=\(t)")
        }
    }

    /// `-seigenRoutes poll,alertPush`（書いたものだけオン）／`-seigenServer URL`／`-seigenRegisterTest2 YES`
    /// ⚠️ devicectl で渡すときは引数の前に `--`
    static func applyArguments() {
        let ud = UserDefaults.standard
        if let csv = ud.string(forKey: "seigenRoutes") {
            let r = Routes(csv: csv)
            Store.routes = r
            Log.add(kind: "routes", detail: "起動引数: \(r.summary)")
            Wake.reconcile(r)
        }
        if let s = ud.string(forKey: "seigenServer"), let u = URL(string: s) {
            Store.serverURL = u
        }
        if ud.bool(forKey: "seigenRegisterTest2") {
            _ = Wake.armTest2()
        }
        if let n = ud.string(forKey: "seigenUsageN").flatMap(Int.init) {
            Store.usageN = n
            if Store.routes.usageWake { Wake.armUsage(n: n) }
        }
    }
}
