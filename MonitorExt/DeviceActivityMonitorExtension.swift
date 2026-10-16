import DeviceActivity
import Foundation
import ManagedSettings

// 全コールバックで「目覚めた記録」を残す（受け入れ条件18）。
// ネットワークは Net の同期待ち（タイムアウト5秒・記録の送信は4秒）。失敗しても記録だけ残して返る（同19）。
// メモリ上限は約6MB の報告があるので、外部ライブラリは入れない。

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        wake("intervalDidStart", activity)
        if activity == .relock {
            relock()
        } else if activity == .appRelock || activity == .selfLockEnd || activity == .superLockEnd {
            // 個別解除・セルフロック・スーパーロックの終わり（スーパーロックが終われば例外が許可アプリに戻る）。少し早く呼ばれても外せるよう2分の余裕を見て決め直し、
            // まだ先の期限が残っていればそこへ登録し直す（force: 少し早すぎて対象が変わらなかったとき用）
            let st = Shield.reconcile(route: activity.rawValue, grace: 120)
            Wake.armExpiryWakes(route: activity.rawValue, force: true)
            Log.add(LogRecord(kind: activity.rawValue, route: activity.rawValue, version: Store.appliedVersion,
                              locked: st.locked, appliedAt: ISO.now, ok: Shield.isShielded == st.locked,
                              detail: "reason=\(st.reason.rawValue) appUnlocks=\(st.appUnlockCount ?? 0)"
                                  + (st.selfLockUntil.map { " selfLockUntil=\($0)" } ?? "")
                                  + (st.superLockUntil.map { " superLockUntil=\($0)" } ?? "")))
        } else if activity == .daily {
            // リセット時刻: 使用時間を0に戻し、枠ロックを外す（手動ロック・時間解除はそのまま）
            Quota.startNewPeriod()
            Shield.reconcile(route: "reset")
        } else if activity == .pollA || activity == .pollB {
            keepOtherPollAlive(activity)
        }
        finish(activity)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        wake("intervalDidEnd", activity)
        if activity == .daily {
            // 期間の終わり（リセットの1分前）。三層で決め直す（期限切れの時間解除の自己修復も兼ねる）
            Shield.reconcile(route: "dailyEnd")
        } else if activity == .pollA || activity == .pollB {
            // 次の分を登録し直す（15分空けて次の間隔。start/end と warning で約5〜10分おきに起きる）
            if Store.routes.poll {
                let err = Wake.armPoll(activity, start: Date().addingTimeInterval(Wake.interval))
                Log.add(kind: "arm", route: "R4", ok: err == nil, error: err, detail: "rearm \(activity.rawValue)")
            }
        } else if activity == .relock {
            // 新しい時間解除のために登録し直した relock を消さないよう、期限が無いか過ぎているときだけ止める
            if Store.unlockUntil.map({ $0 <= Date() }) ?? true {
                DeviceActivityCenter().stopMonitoring([.relock])
            }
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
        } else if activity == .daily {
            // 段階イベント・quota: 使用時間を記録し、使い切っていれば枠ロック（三層で決める）
            Quota.record(event)
            Shield.reconcile(route: "quota")
        } else if activity == .test2, event.rawValue == "E-all", Store.routes.thresholdLock {
            // 試験2 の「E-all 到達でロック」は枠ロックの印として扱う（三層の外から shield を書かない）
            Quota.markExhaustedForTest()
            let st = Shield.reconcile(route: "test2")
            Log.add(LogRecord(kind: "thresholdLock", route: "test2", locked: st.locked, appliedAt: ISO.now, ok: Shield.isShielded == st.locked))
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
        case .daily: return "daily"
        case .appRelock: return "appRelock"
        case .selfLockEnd: return "selfLockEnd"
        case .superLockEnd: return "superLockEnd"
        default: return activity.rawValue
        }
    }

    private func wake(_ callback: String, _ activity: DeviceActivityName) {
        Log.add(kind: "wake", route: route(for: activity), detail: "\(callback) \(activity.rawValue)")
    }

    /// 時間解除の終わり。時間解除を外して三層で決め直す（手動ロックも枠ロックも無ければ掛からない）。
    /// そのあいだに別の指示（新しい時間解除など）が来ていたら何もしない
    private func relock() {
        let until = Store.unlockUntil
        let target = Store.relockFor
        // 登録したときの対象（relockFor）と今の unlockUntil が同じときだけ外す（古い relock を無視する）
        let matches = until != nil && target != nil && abs(until!.timeIntervalSince(target!)) < 1
        if let until, matches, until <= Date().addingTimeInterval(120) {
            Store.unlockUntil = nil
            Store.relockFor = nil
            Store.unlockSource = nil
            let st = Shield.reconcile(route: "relock")
            Log.add(LogRecord(kind: "relock", route: "relock", version: Store.appliedVersion, locked: st.locked,
                              appliedAt: ISO.now, ok: Shield.isShielded == st.locked,
                              error: Shield.isShielded == st.locked ? nil : "読み戻し不一致",
                              detail: "unlockUntil=\(ISO.string(until)) reason=\(st.reason.rawValue)"))
        } else {
            Log.add(kind: "relock", route: "relock", ok: true,
                    detail: "掛けない（unlockUntil=\(until.map(ISO.string) ?? "なし") relockFor=\(target.map(ISO.string) ?? "なし")）")
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
        // どのコールバックでも、期限切れの時間解除が外れたままなら掛け直す（relock の取りこぼしの自己修復 sync-fallback）
        Shield.reconcile(route: "sync-fallback")
        let r = Store.routes
        let wantsSync = ((activity == .pollA || activity == .pollB) && r.poll) || (activity == .usage && r.usageWake)
        if wantsSync {
            Shield.sync(route: route(for: activity))
        }
        Log.flush()
    }
}
