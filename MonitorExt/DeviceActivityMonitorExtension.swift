import DeviceActivity
import Foundation
import ManagedSettings

// 使う監視は、ロックの終わり（.strictLockEnd・.normalLockEnd）、確定済みの回のスーパーの始まり（.runSuperStart）、
// 最初のロック解除前の拾い直し（.retryAfterUnlock・ふつうの決め直しで拾う）と、スケジュールの毎日の予定（sched.<id>.n＝通常ロックの
// スケジュール、sched.<id>.s＝スーパーロックのスケジュール・Shared/Schedule.swift）（本番設計 §9.9・§9.11）。合わせて最大14件（20件の上限内）。
// どのコールバックでも記録を残し、期限とスケジュールを確かめて決め直す（期限後に止めを残さない・アプリを開かなくても切り替わる）。
// ネットワークは使わない。メモリ上限は約6MB の報告があるので、外部ライブラリは入れない。
// 旧版が登録した監視（枠の daily など）が呼ばれても、ここでは決め直すだけ（本体の起動時に止める）

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    /// 目覚ましが少し早く呼ばれても切り替えられる余裕（秒）
    static let slack: TimeInterval = 120

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        wake("intervalDidStart", activity)
        switch activity {
        case .strictLockEnd, .normalLockEnd:
            // 少し早く呼ばれても外せるよう2分の余裕を見て決め直し、まだ先の期限が残っていればそこへ登録し直す
            // （forceFor: 少し早すぎて対象が変わらなかったとき用）
            var hint = WakeHint()
            if activity == .strictLockEnd { hint.strictGrace = Self.slack } else { hint.normalGrace = Self.slack }
            let st = Shield.reconcile(route: activity.rawValue, hint: hint)
            Wake.armExpiryWakes(route: activity.rawValue, forceFor: activity)
            done(activity, st)
        case .runSuperStart:
            // 確定済みの回のスーパーの始まり。少し早く呼ばれても掛けられるよう余裕を見る。次の始まりへの登録し直しは
            // reconcile の中で対象が変わったときだけ（force しない: 早く呼ばれたときに同じ時刻へ何度も登録し直さない）
            let st = Shield.reconcile(route: activity.rawValue, hint: WakeHint(lead: Self.slack))
            done(activity, st)
        case _ where Self.isSchedule(activity):
            // スケジュールの始まり（通常・スーパー）。少し早く呼ばれても掛けられるよう余裕を見る
            let st = Shield.reconcile(route: activity.rawValue, hint: WakeHint(lead: Self.slack))
            done(activity, st)
        default:
            finish()
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        wake("intervalDidEnd", activity)
        if Self.isSchedule(activity) {
            // スケジュールの終わり。期限は終わりの目覚まし（.strictLockEnd・.normalLockEnd）でも外れるが、ここでも決め直す（二重の網）
            let st = Shield.reconcile(route: activity.rawValue, hint: Self.endHint(for: activity, now: Date()))
            done(activity, st)
            return
        }
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

    static func isSchedule(_ a: DeviceActivityName) -> Bool { a.rawValue.hasPrefix(Schedules.prefix) }

    /// スケジュールの終わり（sched.<id>.n／sched.<id>.s）で渡す余裕。余裕は「いまの期限」全体に効くので、
    /// その期限がこのスケジュールの回の終わりそのもので、しかも slack のうちに来るときだけ渡す。
    /// 手動のロックや別のスケジュールの回で期限がそれより先なら（例: 手動のスーパー 5:01 まで・スケジュール 23:00〜5:00）
    /// 余裕 0 で決め直し、ちょうどの期限は .strictLockEnd／.normalLockEnd に任せる（別のロックを早く終わらせない）。
    /// 期限が回の終わりと同じなら今までと同じ余裕なので、外れるのが今より遅くなることはない
    static func endHint(for activity: DeviceActivityName, now: Date) -> WakeHint {
        var hint = WakeHint()
        let raw = activity.rawValue.dropFirst(Schedules.prefix.count)
        guard let dot = raw.lastIndex(of: ".") else { return hint }
        let id = String(raw[..<dot])
        let kind: LockKind
        switch raw[raw.index(after: dot)...] {
        case Substring(LockKind.strict.activitySuffix): kind = .strict
        case Substring(LockKind.normal.activitySuffix): kind = .normal
        default: return hint
        }
        guard let until = kind == .strict ? Store.strictLockUntil : Store.normalLockUntil,
              until <= now.addingTimeInterval(slack),
              Schedules.runs.contains(where: { $0.scheduleID == id && $0.kind == kind && abs($0.end.timeIntervalSince(until)) < 1 })
        else { return hint }
        if kind == .strict { hint.strictGrace = slack } else { hint.normalGrace = slack }
        return hint
    }

    private func done(_ activity: DeviceActivityName, _ st: LockStatus) {
        Log.add(LogRecord(kind: activity.rawValue, route: activity.rawValue, locked: st.locked,
                          appliedAt: ISO.now, ok: true,
                          detail: "mode=\(st.mode ?? "-") strict=\(st.strictLockUntil ?? "-") normal=\(st.normalLockUntil ?? "-")"))
    }

    /// どのコールバックでも、期限切れのロックが掛かったままなら外し、スケジュールの回の中なら掛ける（自己修復）
    private func finish() {
        Shield.reconcile(route: "sync-fallback")
    }
}
