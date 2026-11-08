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
    /// 通常ロックで残すアプリ（§9.10・ロック中も選び直せる）
    @Published var normalKeep: Set<ApplicationToken> = NormalLock.keepApps
    /// スケジュール（5個まで・§9.9）
    @Published var schedules: [LockSchedule] = Schedules.all

    var strictLockUntil: Date? { status.strictLockUntil.flatMap(ISO.parse) }
    /// スーパーロック中か（解除の入口を出さない。ホームごと StrictLockedHome になる）
    var strictLockActive: Bool { strictLockUntil.map { $0 > Date() } ?? false }
    var normalLockUntil: Date? { status.normalLockUntil.flatMap(ISO.parse) }
    /// 通常ロック中か（スーパーロックと重なっていても true）
    var normalLockActive: Bool { normalLockUntil.map { $0 > Date() } ?? false }
    /// どちらかのロック中（スケジュールの編集が「次の回から」になる案内を出す）
    var anyLockActive: Bool { strictLockActive || normalLockActive }

    /// 表示を App Group から読み直す（軽い）
    func refresh() {
        authStatus = AuthorizationCenter.shared.authorizationStatus
        status = Shield.status
        keepApps = KeepApps.registered
        keepVerifying = KeepApps.isVerifying
        keepPending = KeepApps.pendingCount
        normalKeep = NormalLock.keepApps
        schedules = Schedules.all
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
        // 期限が来たか、スケジュールの回が始まったら決め直す（拡張が起きなかったときの網）
        let now = Date()
        let expired = [Store.strictLockUntil, Store.normalLockUntil].contains { $0.map { $0 <= now } ?? false }
        if expired || !Schedules.all.isEmpty { Shield.reconcile(route: "sync-fallback") }
        refresh()
    }

    // MARK: スーパーロック（§9.6）

    /// 断るときは理由を返す（画面に出す）。済んだら nil
    func startStrictLock(minutes: Int) -> String? {
        if let e = Shield.startStrictLock(minutes: minutes) { return e }
        refresh()
        return nil
    }

    // MARK: 通常ロック（§9.9）

    func startNormalLock(minutes: Int) -> String? {
        if let e = Shield.startNormalLock(minutes: minutes) { return e }
        refresh()
        return nil
    }

    /// 残すアプリを選び直す（ロック中も即反映）。断るとき・カテゴリを捨てたときは理由
    func setNormalKeep(_ sel: FamilyActivitySelection) -> String? {
        let e = Shield.setNormalKeep(sel)
        refresh()
        return e
    }

    // MARK: スケジュール（§9.9）

    /// 保存する。いま掛かっているロックは変えず、次の回から効く。断るときは理由
    func saveSchedule(_ s: LockSchedule) -> String? {
        let e = Schedules.save(s)
        refresh()
        return e
    }

    func deleteSchedule(id: String) {
        Schedules.delete(id: id)
        refresh()
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
        // 通常ロック中は候補を通常ロックの例外に入れる（Shield.normalExceptions）
        Shield.reconcile(route: "keepVerify")
        refresh()
        return nil
    }

    func stopKeepVerify() {
        KeepApps.stop()
        // 例外に入れていた候補を、通常ロック中なら通常ロックで止め直す
        Shield.reconcile(route: "keepVerify")
        refresh()
    }

    func removeKeepApp(_ token: ApplicationToken) {
        KeepApps.remove(token)
        refresh()
    }
}
