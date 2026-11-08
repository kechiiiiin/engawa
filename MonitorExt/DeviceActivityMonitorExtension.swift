import DeviceActivity
import Foundation
import ManagedSettings

// 使う監視はスーパーロックの終わり（.strictLockEnd）だけ（本番設計 §9.8 C）。
// どのコールバックでも記録を残し、期限を確かめて決め直す（期限後に止めを残さない）。
// ネットワークは使わない。メモリ上限は約6MB の報告があるので、外部ライブラリは入れない。
// 旧版が登録した監視（枠の daily など）が呼ばれても、ここでは決め直すだけ（本体の起動時に止める）

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        wake("intervalDidStart", activity)
        if activity == .strictLockEnd {
            // 少し早く呼ばれても外せるよう2分の余裕を見て決め直し、まだ先の期限が残っていればそこへ登録し直す
            // （force: 少し早すぎて対象が変わらなかったとき用）
            let st = Shield.reconcile(route: activity.rawValue, grace: 120)
            Wake.armExpiryWakes(route: activity.rawValue, force: true)
            Log.add(LogRecord(kind: activity.rawValue, route: activity.rawValue, locked: st.locked,
                              appliedAt: ISO.now, ok: Shield.isShielded == st.locked,
                              detail: st.strictLockUntil.map { "strictLockUntil=\($0)" }))
        }
        finish()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        wake("intervalDidEnd", activity)
        finish()
    }

    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
        wake("intervalWillStartWarning", activity)
        finish()
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        wake("intervalWillEndWarning", activity)
        finish()
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        Log.add(kind: "threshold", route: activity.rawValue, detail: event.rawValue)
        finish()
    }

    // MARK: -

    private func wake(_ callback: String, _ activity: DeviceActivityName) {
        Log.add(kind: "wake", route: activity.rawValue, detail: callback)
    }

    /// どのコールバックでも、期限切れのスーパーロックが掛かったままなら外す（自己修復）
    private func finish() {
        Shield.reconcile(route: "sync-fallback")
    }
}
