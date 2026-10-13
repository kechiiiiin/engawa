import DeviceActivity
import Foundation
import ManagedSettings

// 全コールバックで「目覚めた記録」を残す（受け入れ条件18）。
// ネットワークは Net の同期待ち（タイムアウト10秒）。失敗しても記録だけ残して返る（同19）。
// メモリ上限は約6MB の報告があるので、外部ライブラリは入れない。

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        wake("intervalDidStart", activity)
        if activity == .relock {
            relock()
        } else if activity == .pollA || activity == .pollB {
            keepOtherPollAlive(activity)
        }
        finish(activity)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        wake("intervalDidEnd", activity)
        if activity == .pollA || activity == .pollB {
            // 次の分を登録し直す（15分空けて次の間隔。start/end と warning で約5〜10分おきに起きる）
            if Store.routes.poll {
                let err = Wake.armPoll(activity, start: Date().addingTimeInterval(Wake.interval))
                Log.add(kind: "arm", route: "R4", ok: err == nil, error: err, detail: "rearm \(activity.rawValue)")
            }
        } else if activity == .relock {
            DeviceActivityCenter().stopMonitoring([.relock])
        }
        finish(activity)
    }

    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
        wake("intervalWillStartWarning", activity)
        finish(activity)
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        wake("intervalWillEndWarning", activity)
        finish(activity)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        Log.add(kind: "threshold", route: route(for: activity), detail: "\(activity.rawValue) \(event.rawValue)")
        if activity == .usage {
            // 最後の段まで来たら登録し直して数え直す（includesPastActivity=false なので登録時点から）
            if event == Wake.usageEventName(Store.usageMaxRegistered) || event == Wake.usageEventName(Store.usageN),
               Store.routes.usageWake {
                Wake.armUsage(n: Store.usageN)
            }
        } else if activity == .test2, event.rawValue == "E-all", Store.routes.thresholdLock {
            Shield.lockNow()
            Log.add(LogRecord(kind: "thresholdLock", route: "test2", locked: true, appliedAt: ISO.now, ok: Shield.isShielded))
        }
        finish(activity)
    }

    override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventWillReachThresholdWarning(event, activity: activity)
        Log.add(kind: "thresholdWarning", route: route(for: activity), detail: "\(activity.rawValue) \(event.rawValue)")
        finish(activity)
    }

    // MARK: -

    private func route(for activity: DeviceActivityName) -> String {
        switch activity {
        case .pollA, .pollB: return "R4"
        case .usage: return "R5"
        case .relock: return "relock"
        case .test2: return "test2"
        default: return activity.rawValue
        }
    }

    private func wake(_ callback: String, _ activity: DeviceActivityName) {
        Log.add(kind: "wake", route: route(for: activity), detail: "\(callback) \(activity.rawValue)")
    }

    /// 時間解除の終わり。そのあいだに別の指示（無期限解除など）が来ていたら掛けない
    private func relock() {
        let until = Store.unlockUntil
        if let until, until <= Date().addingTimeInterval(120) {
            Shield.lockNow()
            Store.unlockUntil = nil
            Log.add(LogRecord(kind: "relock", route: "relock", version: Store.appliedVersion, locked: true,
                              appliedAt: ISO.now, ok: Shield.isShielded, error: Shield.isShielded ? nil : "読み戻しで shield なし",
                              detail: "unlockUntil=\(ISO.string(until))"))
        } else {
            Log.add(kind: "relock", route: "relock", ok: true, detail: "掛けない（unlockUntil=\(until.map(ISO.string) ?? "なし")）")
        }
    }

    /// もう片方の目覚ましが途切れていたら継ぎ直す
    private func keepOtherPollAlive(_ activity: DeviceActivityName) {
        guard Store.routes.poll else { return }
        let other: DeviceActivityName = activity == .pollA ? .pollB : .pollA
        if !DeviceActivityCenter().activities.contains(other) {
            let err = Wake.armPoll(other, start: Date().addingTimeInterval(Wake.interval / 2))
            Log.add(kind: "arm", route: "R4", ok: err == nil, error: err, detail: "revive \(other.rawValue)")
        }
    }

    /// 経路がオンならサーバーを見に行って反映し、記録を送る
    private func finish(_ activity: DeviceActivityName) {
        let r = Store.routes
        let wantsSync = ((activity == .pollA || activity == .pollB) && r.poll) || (activity == .usage && r.usageWake)
        if wantsSync {
            Shield.sync(route: route(for: activity))
        }
        Log.flush()
    }
}
