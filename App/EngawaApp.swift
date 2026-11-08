import SwiftUI
import Combine
import UIKit

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

/// 最初の画面（ホーム）。トークンの有無によらず同じ画面（本番設計 §9.8 C）。
/// 前面に来るたび見直し、前面にいるあいだは20秒ごとに見回る
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            if model.strictLockActive {
                StrictLockedHome()
            } else {
                StrictWaitingHome()
            }
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
                return
            }
            #endif
            model.refresh()
            if model.authStatus == .notDetermined { model.requestAuth() }
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
/// 表示用の状態を画面の model にだけ入れ、見回り・許可の要求をしない。Debug ビルドだけ。
/// mode: usable／strict-locked／normal-locked／strict-sheet／strict-confirm／normal-confirm／keep-apps／schedules／schedule-edit
enum UIDemo {
    static let mode: String? = UserDefaults.standard.string(forKey: "engawaUIDemo")
    /// スーパーロックのシートを開いて出す: 0＝時間の選択、それ以外＝その長さの確認
    static var strictSheetMinutes: Int? {
        switch mode {
        case "strict-sheet": return 0
        case "strict-confirm", "normal-confirm": return 120
        default: return nil
        }
    }

    static func apply(_ mode: String, to model: AppModel) {
        model.authStatus = .approved
        switch mode {
        case "strict-locked":
            model.status = LockStatus(locked: true, updatedAt: ISO.now,
                                      strictLockUntil: ISO.string(Date().addingTimeInterval(2 * 3600)), mode: "strict")
            model.schedules = demoSchedules
        case "normal-locked":
            model.status = LockStatus(locked: true, updatedAt: ISO.now,
                                      normalLockUntil: ISO.string(Date().addingTimeInterval(90 * 60)), mode: "normal")
            model.schedules = demoSchedules
        case "schedules", "schedule-edit":
            model.status = LockStatus(locked: false, updatedAt: ISO.now)
            model.schedules = demoSchedules
        default:
            model.status = LockStatus(locked: false, updatedAt: ISO.now)
        }
    }

    static let demoSchedules: [LockSchedule] = [
        LockSchedule(id: "demo1", weekdays: [2, 3, 4, 5, 6], start: 21 * 60, end: 7 * 60, superFrom: 2 * 60, superTo: 8 * 60),
        LockSchedule(id: "demo2", weekdays: [1, 7], start: 9 * 60, end: 12 * 60),
    ]
}
#endif

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.trimLog()   // log.jsonl の trim は本体だけが行う
        Log.add(kind: "launch")
        #if DEBUG
        if UIDemo.mode != nil { return true }   // 見た目の確認だけ。止めの掛け外しはしない
        #endif
        // 旧版の監視（枠・目覚まし・解除の終わり）を止める（§9.8 C）
        Shield.cleanupLegacy()
        // 登録の確かめの一時的な止めは、起動し直したら残さない（途中で閉じても止めが残り続けない・§9.8 B）。
        // 試し（claude/allow-verify）のストアも外す
        KeepApps.stop(route: "launch")
        KeepApps.legacyVerifyStore.clearAllSettings()
        // スケジュールの予定が iOS に登録されているか合わせる（消えていれば登録し直す・§9.9）
        Schedules.syncMonitoring(route: "launch")
        // サーバーは使わない（§9.8 C）: 通知の許可・APNs の登録はしない
        Shield.reconcile(route: "launch")
        return true
    }

    // 端末のロックが解除された（データ保護が解けた）。本体が動いているときだけ呼ばれる。
    // 再起動直後は期限が読めず reconcile が何もしないので、読めるようになったここで決め直す
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        Log.add(kind: "deviceUnlocked", detail: "state=\(application.applicationState.rawValue)")
        Shield.reconcile(route: "deviceUnlocked")
    }
}
