import Foundation
import DeviceActivity

// スケジュール（本番設計 §9.9・2026-11-08 本人と決定）。
//
//   1個 = 曜日の組 ＋ ロック期間（通常ロック）＋ その中のスーパーロックの時間帯（任意・期間の内側だけ）。5個まで。
//   ロック期間は日をまたげる（21:00〜翌7:00）。曜日は「ロック期間が始まる日」の曜日。
//
//   仕組み:
//   - 決め方は時刻の計算（apply）。いまがどれかの回の中にあれば、その回の終わりを通常ロック／スーパーロックの期限として
//     保存する（伸ばすだけで縮めない）。あとは手動のロックと同じ期限の仕組み（目覚まし・reconcile）で外れる。
//     スケジュールを消しても縮めても、保存した期限はそのまま＝いま掛かっている回は元の期限まで続く（受け入れ条件7）
//   - 編集・追加した時刻（effectiveFrom）より前に始まった回には効かない＝「次の回から効く」。保存した瞬間に
//     いきなりロックが掛かることもない。始まった回は中身を写して確定する（Run）ので、その回のまだ来ていない
//     スーパーの時間帯も、編集・削除で消せない
//   - アプリを開かなくても切り替わるよう、DeviceActivity の予定を「毎日くり返す」で登録して、始まり・終わりに
//     MonitorExt を起こす（曜日は登録せず、起きたときに apply が曜日を見る）。1個につき ロック期間 と
//     スーパーの時間帯 の最大2件。5個で10件、終わりの目覚まし2件（.strictLockEnd・.normalLockEnd）、確定済みの回の
//     スーパーの始まり（.runSuperStart）、最初のロック解除前の拾い直し（.retryAfterUnlock）と合わせて14件。
//     iOS の上限は「1つのアプリと拡張で同時に20件」（Apple のドキュメント
//     DeviceActivityCenter.MonitoringError.excessiveActivities）なので、5個の上限の中で超えない
//   - 予定の間隔は15分以上が要る（短いと intervalTooShort）。画面は15分刻みで、短い時間帯を作らせない

struct LockSchedule: Codable, Identifiable, Equatable {
    var id: String = String(UUID().uuidString.prefix(8))
    /// Calendar の曜日（1=日 … 7=土）。ロック期間が始まる日
    var weekdays: [Int] = [2, 3, 4, 5, 6]
    /// ロック期間の始まり・終わり（0時からの分）。終わり ≤ 始まり なら翌日
    var start: Int = 21 * 60
    var end: Int = 7 * 60
    /// スーパーロックの時間帯（ロック期間の始まりからの分）。無ければ通常ロックだけ
    var superFrom: Int? = nil
    var superTo: Int? = nil
    /// この中身にした時刻。これより前に始まった回には効かない（次の回から効く）
    var effectiveFrom: String = ISO.now

    static let step = 15
    static let dayMinutes = 24 * 60

    /// ロック期間の長さ（分）。始まり＝終わりは作らせない（0 を返す）
    var length: Int { (end - start + Self.dayMinutes) % Self.dayMinutes }

    var hasSuper: Bool { superFrom != nil && superTo != nil }

    /// 保存できない理由（無ければ nil）
    var invalidReason: String? {
        if weekdays.isEmpty { return "曜日を1つ以上選んでください。" }
        if length < Self.step { return "ロック期間は\(Self.step)分以上にしてください。" }
        if let f = superFrom, let t = superTo {
            if f < 0 || t > length || t - f < Self.step {
                return "スーパーロックの時間帯は、ロック期間の内側で\(Self.step)分以上にしてください。"
            }
        } else if (superFrom == nil) != (superTo == nil) {
            return "スーパーロックの時間帯を選び直してください。"
        }
        return nil
    }

    /// 0時からの分を「21:00」に。1440 以上は「翌7:00」
    static func clock(_ m: Int) -> String {
        let d = m / dayMinutes
        let r = m % dayMinutes
        return (d > 0 ? "翌" : "") + String(format: "%d:%02d", r / 60, r % 60)
    }

    /// ロック期間の始まりからの分を、0時からの分に（日をまたげば 1440 以上）
    func minuteOfDay(offset: Int) -> Int { start + offset }

    var periodText: String { "\(Self.clock(start))〜\(Self.clock(start + length))" }
    var superText: String? {
        guard let f = superFrom, let t = superTo else { return nil }
        return "\(Self.clock(start + f))〜\(Self.clock(start + t))"
    }

    static let weekdayNames = ["日", "月", "火", "水", "木", "金", "土"]   // 1=日
    /// 曜日の並びは月曜はじまり
    static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var weekdaysText: String {
        let set = Set(weekdays)
        if set.count == 7 { return "毎日" }
        if set == [2, 3, 4, 5, 6] { return "平日" }
        if set == [1, 7] { return "土日" }
        return Self.weekdayOrder.filter(set.contains).map { Self.weekdayNames[$0 - 1] }.joined(separator: "・")
    }

    // MARK: 回

    struct Occurrence {
        var normal: DateInterval
        var superLock: DateInterval?
    }

    /// now を含みうる回（今日始まる回と、昨日始まって日をまたぐ回）
    func occurrences(around now: Date, calendar: Calendar = .current) -> [Occurrence] {
        guard invalidReason == nil else { return [] }
        let today = calendar.startOfDay(for: now)
        var out: [Occurrence] = []
        for back in [1, 0] {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let s = calendar.date(byAdding: .minute, value: start, to: day) else { continue }
            let e = s.addingTimeInterval(TimeInterval(length * 60))
            var sup: DateInterval?
            if let f = superFrom, let t = superTo {
                sup = DateInterval(start: s.addingTimeInterval(TimeInterval(f * 60)), end: s.addingTimeInterval(TimeInterval(t * 60)))
            }
            out.append(Occurrence(normal: DateInterval(start: s, end: e), superLock: sup))
        }
        return out
    }

    // MARK: DeviceActivity の予定（毎日くり返す）

    var normalActivity: DeviceActivityName { DeviceActivityName("sched.\(id).n") }
    var superActivity: DeviceActivityName { DeviceActivityName("sched.\(id).s") }

    static func daily(from a: Int, to b: Int) -> DeviceActivitySchedule {
        let s = a % dayMinutes, e = b % dayMinutes
        return DeviceActivitySchedule(intervalStart: DateComponents(hour: s / 60, minute: s % 60),
                                      intervalEnd: DateComponents(hour: e / 60, minute: e % 60),
                                      repeats: true)
    }

    var activities: [(DeviceActivityName, DeviceActivitySchedule)] {
        var out = [(normalActivity, Self.daily(from: start, to: start + length))]
        if let f = superFrom, let t = superTo {
            out.append((superActivity, Self.daily(from: start + f, to: start + t)))
        }
        return out
    }
}

enum Schedules {
    static let file = "schedules.json"
    /// 画面で作れる数（§9.9 本人）。DeviceActivity は1個につき最大2件なので、5個で10件
    static let maxCount = 5
    /// iOS の同時登録の上限（Apple のドキュメント: an app and its extensions combined, twenty）
    static let systemActivityLimit = 20
    static let prefix = "sched."

    static var all: [LockSchedule] { load() ?? [] }

    /// 読めないとき（壊れている・最初のロック解除前）は nil。ファイルが無ければ空
    static func load() -> [LockSchedule]? {
        guard FileManager.default.fileExists(atPath: Store.url(file).path) else { return [] }
        return Store.codable(file, as: [LockSchedule].self)
    }

    /// 保存して予定を登録し直す（本体から）。断るときは理由。iOS への登録に失敗したら保存を戻す
    static func save(_ s: LockSchedule) -> String? {
        if let r = s.invalidReason { return r }
        let before = load() ?? []
        var list = before
        var item = s
        item.effectiveFrom = ISO.now   // 次の回から効く
        if let i = list.firstIndex(where: { $0.id == s.id }) {
            list[i] = item
        } else {
            guard list.count < maxCount else { return "スケジュールは\(maxCount)個までです。" }
            list.append(item)
        }
        Store.setCodable(file, list)
        guard all == list else { return "スケジュールを保存できませんでした。もう一度お試しください。" }
        if let e = syncMonitoring(route: "schedule") {
            // iOS に登録できなかった: 保存を戻し、予定も元に合わせる（一覧と iOS の予定をずらさない）
            Store.setCodable(file, before)
            _ = syncMonitoring(route: "schedule-rollback")
            Log.add(kind: "schedule", ok: false, error: e, detail: "保存を戻した \(item.id)")
            return e + "（保存していません）"
        }
        Log.add(kind: "schedule", detail: "保存 \(item.id) \(item.weekdaysText) \(item.periodText) super=\(item.superText ?? "-")")
        return nil
    }

    /// 消す（本体から）。いま掛かっている回（確定済みの回のスーパーの時間帯を含む）はそのまま（受け入れ条件7）
    static func delete(id: String) {
        Store.setCodable(file, all.filter { $0.id != id })
        let ok = !all.contains { $0.id == id }
        let e = syncMonitoring(route: "schedule")
        Log.add(kind: "schedule", ok: ok && e == nil, error: ok ? e : "削除を保存できなかった", detail: "削除 \(id)")
    }

    // MARK: 確定済みの回（始まった回の中身を写したもの）
    //
    //   回が始まったとき（apply がロック期間の中だと判断したとき）に、その回の終わりとスーパーの時間帯を写しておく。
    //   以後その回は、スケジュールを編集・削除しても写した中身で進む（まだ来ていないスーパーの時間帯も消せない・§9.9 の7）。
    //   回の判定は「回の始まりが effectiveFrom より後か」の1つだけ（進行中の回に足した・変えたスケジュールは、
    //   ロック期間もスーパーの時間帯も次の回から）。ロック期間の終わりを過ぎたら消す

    struct Run: Codable, Equatable {
        var scheduleID: String
        var normalStart: Date
        var normalEnd: Date
        var superStart: Date?
        var superEnd: Date?
    }

    static let runsFile = "schedule-runs.json"

    static var runs: [Run] {
        get { Store.codable(runsFile, as: [Run].self) ?? [] }
        set { Store.setCodable(runsFile, newValue.isEmpty ? nil : newValue) }
    }

    /// 確定済みの回のうち、これから来るスーパーの始まりでいちばん早いもの（一発の目覚ましの対象）
    static func nextRunSuperStart(after now: Date) -> Date? {
        runs.compactMap(\.superStart).filter { $0 > now }.min()
    }

    /// いまがどれかの回の中なら、その回の終わりまで通常ロック／スーパーロックの期限を伸ばす（縮めない）。
    /// reconcile の頭で呼ぶ。lead: 始まりの目覚ましが少し早く来たとき用。grace: 終わりの目覚ましが少し早く来たとき、
    /// 終わりかけの回を当て直さないため
    static func apply(now: Date, lead: TimeInterval, strictGrace: TimeInterval, normalGrace: TimeInterval, route: String) {
        let before = runs
        var list = before.filter { $0.normalEnd > now }
        // 始まった回を確定する（中身はこの時点のスケジュールから写す）
        for s in all {
            guard let from = ISO.parse(s.effectiveFrom) else { continue }
            for o in s.occurrences(around: now) where o.normal.start >= from {
                guard now >= o.normal.start.addingTimeInterval(-lead), now < o.normal.end else { continue }
                if list.contains(where: { $0.scheduleID == s.id && abs($0.normalStart.timeIntervalSince(o.normal.start)) < 1 }) { continue }
                list.append(Run(scheduleID: s.id, normalStart: o.normal.start, normalEnd: o.normal.end,
                                superStart: o.superLock?.start, superEnd: o.superLock?.end))
                Log.add(kind: "scheduleRun", route: route,
                        detail: "確定 \(s.id) \(ISO.string(o.normal.start))〜\(ISO.string(o.normal.end))"
                            + (o.superLock.map { " super=\(ISO.string($0.start))〜\(ISO.string($0.end))" } ?? ""))
            }
        }
        if list != before { runs = list }
        // 確定済みの回だけで決める
        var normalTo: Date?
        var strictTo: Date?
        for r in list {
            if now >= r.normalStart.addingTimeInterval(-lead), now < r.normalEnd.addingTimeInterval(-normalGrace) {
                normalTo = max(normalTo ?? r.normalEnd, r.normalEnd)
            }
            if let ss = r.superStart, let se = r.superEnd,
               now >= ss.addingTimeInterval(-lead), now < se.addingTimeInterval(-strictGrace) {
                strictTo = max(strictTo ?? se, se)
            }
        }
        if let n = normalTo, (Store.normalLockUntil ?? .distantPast) < n.addingTimeInterval(-1) {
            Store.normalLockUntil = n
            Log.add(kind: "normalLock", route: route, detail: "schedule until=\(ISO.string(n))")
        }
        if let t = strictTo, (Store.strictLockUntil ?? .distantPast) < t.addingTimeInterval(-1) {
            // 登録の確かめ中なら終える（スーパーロック中は登録できない・startStrictLock と同じ）
            if !StrictLock.isActive(now) { KeepApps.stop(route: route) }
            Store.strictLockUntil = t
            Log.add(kind: "strictLock", route: route, detail: "schedule until=\(ISO.string(t))")
        }
    }

    /// 予定を、保存してあるスケジュールに合わせる（本体から: 保存・削除・起動）。失敗したら理由。
    /// スケジュールのファイルが読めない（壊れている・データ保護中）ときは予定に触らない（黙って全部止めない）
    @discardableResult
    static func syncMonitoring(route: String) -> String? {
        guard let list = load() else {
            Log.add(kind: "scheduleMonitor", route: route, ok: false, error: "スケジュールが読めないので予定はそのまま")
            return nil
        }
        let center = DeviceActivityCenter()
        var desired: [DeviceActivityName: DeviceActivitySchedule] = [:]
        for s in list where s.invalidReason == nil {
            for (n, sc) in s.activities { desired[n] = sc }
        }
        let current = center.activities.filter { $0.rawValue.hasPrefix(prefix) }
        let stale = current.filter { desired[$0] == nil }
        if !stale.isEmpty { center.stopMonitoring(stale) }
        var errors: [String] = []
        for (name, sc) in desired.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let have = center.schedule(for: name), same(have, sc) { continue }
            do {
                try center.startMonitoring(name, during: sc)
            } catch {
                errors.append("\(name.rawValue): \(Wake.describe(error))")
            }
        }
        if !stale.isEmpty || !errors.isEmpty {
            Log.add(kind: "scheduleMonitor", route: route, ok: errors.isEmpty,
                    error: errors.isEmpty ? nil : errors.joined(separator: " / "),
                    detail: "登録=\(desired.count) 外した=\(stale.count) 全体=\(center.activities.count)")
        }
        return errors.isEmpty ? nil : "スケジュールの予定を iOS に登録できませんでした。時刻を変えてもう一度お試しください。"
    }

    private static func same(_ a: DeviceActivitySchedule, _ b: DeviceActivitySchedule) -> Bool {
        a.repeats == b.repeats
            && a.intervalStart.hour == b.intervalStart.hour && a.intervalStart.minute == b.intervalStart.minute
            && a.intervalEnd.hour == b.intervalEnd.hour && a.intervalEnd.minute == b.intervalEnd.minute
    }
}
