import SwiftUI
import FamilyControls
import DeviceActivity
import ManagedSettings

// 本体の状態。ホームとシートで共有する（本番設計 §9.8: トークンの有無によらず同じ画面）。

final class AppModel: ObservableObject {
    @Published var authStatus: AuthorizationStatus = AuthorizationCenter.shared.authorizationStatus
    @Published var status: LockStatus = Shield.status
    /// スーパーロックで使うアプリ（許可一覧から登録したもの・§9.8 B）
    @Published var keepApps: [ApplicationToken] = KeepApps.registered
    /// 登録の確かめ中か（候補を一時的に止めている）・止めている候補の数
    @Published var keepVerifying = KeepApps.isVerifying
    @Published var keepPending = KeepApps.pendingCount

    var strictLockUntil: Date? { status.strictLockUntil.flatMap(ISO.parse) }
    /// スーパーロック中か（解除の入口を出さない。ホームごと StrictLockedHome になる）
    var strictLockActive: Bool { strictLockUntil.map { $0 > Date() } ?? false }

    /// 表示を App Group から読み直す（軽い）
    func refresh() {
        authStatus = AuthorizationCenter.shared.authorizationStatus
        status = Shield.status
        keepApps = KeepApps.registered
        keepVerifying = KeepApps.isVerifying
        keepPending = KeepApps.pendingCount
    }

    func requestAuth() {
        Task { @MainActor in
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                Log.add(kind: "auth", ok: true)
            } catch {
                Log.add(kind: "auth", ok: false, error: String(describing: error))
            }
            self.refresh()
        }
    }

    /// 前面に来るたび。期限切れのスーパーロックを外し、終わりの目覚ましが消えていれば継ぎ直す
    func syncOnForeground() {
        Log.add(kind: "foreground", route: "R1")
        Log.trimLog()
        Shield.reconcile(route: "R1")
        refresh()
    }

    /// 前面にいるあいだの見回り（期限が来たら外す・残り時間の表示）
    func tick() {
        if Store.strictLockUntil.map({ $0 <= Date() }) ?? false { Shield.reconcile(route: "sync-fallback") }
        refresh()
    }

    // MARK: スーパーロック（§9.6）

    /// 断るときは理由を返す（画面に出す）。済んだら nil
    func startStrictLock(minutes: Int) -> String? {
        if let e = Shield.startStrictLock(minutes: minutes) { return e }
        refresh()
        return nil
    }

    // MARK: スーパーロックで使うアプリ（§9.8 B）

    /// 候補を一時的に止めて確かめを始める。断るときは理由を返す
    func startKeepVerify(_ candidates: FamilyActivitySelection) -> String? {
        guard !StrictLock.isActive() else { return "スーパーロック中は追加できません。" }
        let apps = candidates.applicationTokens.subtracting(KeepApps.registeredSet)
        guard !apps.isEmpty else {
            return candidates.categoryTokens.isEmpty && candidates.applicationTokens.isEmpty
                ? nil
                : "まだ登録していないアプリを、1つずつ選んでください（カテゴリでは選べません）。"
        }
        KeepApps.start(apps)
        refresh()
        return nil
    }

    func stopKeepVerify() {
        KeepApps.stop()
        refresh()
    }

    func removeKeepApp(_ token: ApplicationToken) {
        KeepApps.remove(token)
        refresh()
    }
}
