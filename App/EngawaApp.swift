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

/// 最初の画面（ホーム）。下のタブで「ロック」（通常ロック）と「スーパーロック」を分ける（本番設計 §9.11）。
/// トークンの有無によらず同じ画面（§9.8 C）。前面に来るたび見直し、前面にいるあいだは20秒ごとに見回る。
/// 開いたとき（起動・裏から戻ったとき）は、スーパーロック中ならスーパーロックのタブ、それ以外（ロック中・ロックなし）は
/// ロックのタブを出す（§9.11「ロック中ならそのタブ、ロックなしなら通常ロックのタブ」。両方掛かっていればスーパー＝効いている方）
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: LockKind = .normal
    @State private var wasBackground = false
    private let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $tab) {
            Tab(LockKind.normal.name, systemImage: "lock", value: LockKind.normal) {
                NavigationStack { LockTab(kind: .normal) }
            }
            Tab(LockKind.strict.name, systemImage: "lock.shield", value: LockKind.strict) {
                NavigationStack { LockTab(kind: .strict) }
            }
        }
        .tint(Theme.wood)
        .onChange(of: scenePhase) { _, phase in
            if isDemo { return }
            if phase == .background { wasBackground = true }
            if phase == .active {
                model.syncOnForeground()
                if wasBackground { tab = Self.openingTab(model) }
                wasBackground = false
            }
        }
        .onReceive(timer) { _ in
            if isDemo { return }
            if scenePhase == .active { model.tick() }
        }
        .onAppear {
            #if DEBUG
            if let mode = UIDemo.mode {
                UIDemo.apply(mode, to: model)
                tab = UIDemo.tab ?? Self.openingTab(model)
                return
            }
            #endif
            model.refresh()
            tab = Self.openingTab(model)
            if model.authStatus == .notDetermined { model.requestAuth() }
        }
    }

    /// 開いたときのタブ（§9.11）
    static func openingTab(_ model: AppModel) -> LockKind {
        model.strictLockActive ? .strict : .normal
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
/// mode: usable／strict-locked／normal-locked／both-locked／strict-sheet／strict-confirm／normal-confirm／keep-apps／schedules／
/// schedule-edit／strict-tab（スーパーロックのタブを出す）
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

    /// 開くタブ（nil なら openingTab のとおり）
    static var tab: LockKind? {
        switch mode {
        case "strict-sheet", "strict-confirm", "keep-apps", "strict-tab": return .strict
        case "normal-confirm": return .normal
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
        case "both-locked":
            model.status = LockStatus(locked: true, updatedAt: ISO.now,
                                      strictLockUntil: ISO.string(Date().addingTimeInterval(60 * 60)),
                                      normalLockUntil: ISO.string(Date().addingTimeInterval(3 * 3600)), mode: "strict")
            model.schedules = demoSchedules
        case "schedules", "schedule-edit", "strict-tab":
            model.status = LockStatus(locked: false, updatedAt: ISO.now)
            model.schedules = demoSchedules
        default:
            model.status = LockStatus(locked: false, updatedAt: ISO.now)
        }
    }

    static let demoSchedules: [LockSchedule] = [
        LockSchedule(id: "demo1", kind: .normal, weekdays: [2, 3, 4, 5, 6], start: 21 * 60, end: 7 * 60),
        LockSchedule(id: "demo2", kind: .normal, weekdays: [1, 7], start: 9 * 60, end: 12 * 60),
        LockSchedule(id: "demo1s", kind: .strict, weekdays: [2, 3, 4, 5, 6], start: 23 * 60, end: 5 * 60),
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
        // §9.9 の形のスケジュール（ロック期間＋その中のスーパー）を、通常とスーパーの2つに分けて書き戻す（§9.11）
        Schedules.migrateIfNeeded(route: "launch")
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
