import Foundation
import DeviceActivity

// スケジュール（本番設計 §9.9・§9.11・2026-11-08 本人と決定）。
//
//   通常ロックとスーパーロックで別々に持つ（§9.11「スケジュールも別管理で」）。1個 = 種類（通常／スーパー）＋曜日の組＋時間帯。
//   種類ごとに5個まで。時間帯は日をまたげる（21:00〜翌7:00）。曜日は「時間帯が始まる日」の曜日。
//   §9.9 の「ロック期間の中のスーパーの時間帯」はやめた。古い schedules.json は読むときに2つに分ける（migrate）。
//
//   仕組み:
//   - 決め方は時刻の計算（apply）。いまがどれかの回の中にあれば、その回の終わりを通常ロック／スーパーロックの期限として
//     保存する（伸ばすだけで縮めない）。あとは手動のロックと同じ期限の仕組み（目覚まし・reconcile）で外れる。
//     重なったときはスーパーが勝ち、スーパーが終わって通常の期限内なら通常に戻る（Shield.reconcile の strict > normal > none）
//   - 編集・追加した時刻（effectiveFrom）より前に始まった回には効かない＝「次の回から効く」。保存した瞬間に
//     いきなりロックが掛かることもない。始まった回は中身を写して確定する（Run）ので、スケジュールを消しても縮めても、
//     その回は元の終わりまで続く（§9.9 の7・§9.11 の5）
//   - アプリを開かなくても切り替わるよう、DeviceActivity の予定を「毎日くり返す」で登録して、始まり・終わりに
//     MonitorExt を起こす（曜日は登録せず、起きたときに apply が曜日を見る）。
//
//   DeviceActivity の監視の数（iOS の上限は「1つのアプリと拡張で同時に20件」・Apple のドキュメント
//   DeviceActivityCenter.MonitoringError.excessiveActivities）:
//     スケジュール 1個につき1件（sched.<id>.n／sched.<id>.s）× 通常5個＋スーパー5個   = 10件
//     ロックの終わりの目覚まし（.strictLockEnd・.normalLockEnd）                        =  2件
//     確定済みの回のスーパーの始まり（.runSuperStart・一発）                            =  1件
//     最初のロック解除前の拾い直し（.retryAfterUnlock・一発）                           =  1件
//     合計 最大14件（上限20件に6件の余裕）。syncMonitoring は種類ごとに maxCount 個までしか登録しない
//   - 予定の間隔は15分以上が要る（短いと intervalTooShort）。画面は15分刻みで、短い時間帯を作らせない

/// ロックの種類（§9.11 のタブ・スケジュールの種類・始め方）
enum LockKind: String, Codable, Identifiable, CaseIterable {
    case normal, strict
    var id: String { rawValue }
    /// 画面上の呼び方。通常ロックは「ロック」とだけ出す（2026-11-08 本人「画面上はロックだけでOK」・§9.11）
    var name: String { self == .normal ? "ロック" : "スーパーロック" }
    /// DeviceActivity の名前の末尾（MonitorExt が ".s" でスーパーの終わりを見分ける）
    var activitySuffix: String { self == .normal ? "n" : "s" }
}

struct LockSchedule: Codable, Identifiable, Equatable {
    var id: String
    var kind: LockKind
    /// Calendar の曜日（1=日 … 7=土）。時間帯が始まる日
    var weekdays: [Int]
    /// 時間帯の始まり・終わり（0時からの分）。終わり ≤ 始まり なら翌日
    var start: Int
    var end: Int
    /// この中身にした時刻。これより前に始まった回には効かない（次の回から効く）
    var effectiveFrom: String

    static let step = 15
    static let dayMinutes = 24 * 60

    init(id: String = String(UUID().uuidString.prefix(8)), kind: LockKind = .normal, weekdays: [Int] = [2, 3, 4, 5, 6],
         start: Int = 21 * 60, end: Int = 7 * 60, effectiveFrom: String = ISO.now) {
        self.id = id
        self.kind = kind
        self.weekdays = weekdays
        self.start = start
        self.end = end
        self.effectiveFrom = effectiveFrom
    }

    /// 時間帯の長さ（分）。始まり＝終わりは作らせない（0 を返す）
    var length: Int { (end - start + Self.dayMinutes) % Self.dayMinutes }

    /// 保存できない理由（無ければ nil）
    var invalidReason: String? {
        if weekdays.isEmpty { return "曜日を1つ以上選んでください。" }
        if length < Self.step { return "時間帯は\(Self.step)分以上にしてください。" }
        return nil
    }

    /// 0時からの分を「21:00」に。1440 以上は「翌7:00」
    static func clock(_ m: Int) -> String {
        let d = m / dayMinutes
        let r = m % dayMinutes
        return (d > 0 ? "翌" : "") + String(format: "%d:%02d", r / 60, r % 60)
    }

    var periodText: String { "\(Self.clock(start))〜\(Self.clock(start + length))" }

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

    /// now を含みうる回（今日始まる回と、昨日始まって日をまたぐ回）
    func occurrences(around now: Date, calendar: Calendar = .current) -> [DateInterval] {
        guard invalidReason == nil else { return [] }
        let today = calendar.startOfDay(for: now)
        var out: [DateInterval] = []
        for back in [1, 0] {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let s = calendar.date(byAdding: .minute, value: start, to: day) else { continue }
            out.append(DateInterval(start: s, end: s.addingTimeInterval(TimeInterval(length * 60))))
        }
        return out
    }

    // MARK: DeviceActivity の予定（毎日くり返す・1個につき1件）

    /// 通常は §9.9 と同じ名前（sched.<id>.n）なので、引き継いだ通常のスケジュールは登録し直さずに済む
    var activityName: DeviceActivityName { DeviceActivityName("\(Schedules.prefix)\(id).\(kind.activitySuffix)") }

    var activitySchedule: DeviceActivitySchedule {
        let s = start % Self.dayMinutes, e = (start + length) % Self.dayMinutes
        return DeviceActivitySchedule(intervalStart: DateComponents(hour: s / 60, minute: s % 60),
                                      intervalEnd: DateComponents(hour: e / 60, minute: e % 60),
                                      repeats: true)
    }
}

enum Schedules {
    static let file = "schedules.json"
    /// 画面で作れる数（種類ごと・§9.11 本人）。DeviceActivity は1個につき1件なので、通常5個＋スーパー5個で10件
    static let maxCount = 5
    /// iOS の同時登録の上限（Apple のドキュメント: an app and its extensions combined, twenty）
    static let systemActivityLimit = 20
    static let prefix = "sched."

    static var all: [LockSchedule] { load() ?? [] }

    static func of(_ kind: LockKind, in list: [LockSchedule]) -> [LockSchedule] { list.filter { $0.kind == kind } }

    /// 読めないとき（壊れている・最初のロック解除前）は nil。ファイルが無ければ空。
    /// §9.9 の形（種類なし・スーパーの時間帯つき）は、読むたびに §9.11 の形へ分ける（migrateIfNeeded が書き戻す）
    static func load() -> [LockSchedule]? {
        guard FileManager.default.fileExists(atPath: Store.url(file).path) else { return [] }
        guard let raw = Store.codable(file, as: [StoredSchedule].self) else { return nil }
        return migrate(raw).list
    }

    // MARK: §9.9 の形からの引き継ぎ（§9.11）
    //
    //   §9.9 の1個（曜日 W・ロック期間 start〜end・その中のスーパーの時間帯 superFrom〜superTo＝期間の始まりからの分）を
    //     通常: 同じ id・曜日 W・start〜end・effectiveFrom はそのまま（DeviceActivity の名前も sched.<id>.n のまま）
    //     スーパー（時間帯があれば）: id＝元の id＋"s"・時間帯は (start+superFrom)〜(start+superTo)。
    //       曜日はスーパーが始まる日の曜日（ロック期間が日をまたいでからスーパーが始まるときは、翌日へずらす。
    //       例: 月〜金 21:00〜翌7:00 の中の 1:00〜5:00 → 火〜土 1:00〜5:00）。
    //       effectiveFrom は元の値＋superFrom 分（「ロック期間の始まり ≥ effectiveFrom」と同じ回だけが効くように。
    //       引き継いだ瞬間に、元は効かなかった回のスーパーが掛かり出さない）
    //   に分ける。確定済みの回（schedule-runs.json）も同じく2つに分ける（flatten）。スーパーの回の id も元の id＋"s" なので、
    //   引き継いだスーパーのスケジュールが同じ回を二重に確定しない。まだ来ていないスーパーの始まりは .runSuperStart が起こす。
    //   進行中の回は元の終わりまで続く（弱めない）

    /// schedules.json の1個（§9.9 の形も §9.11 の形も読める）
    struct StoredSchedule: Decodable {
        var id: String
        var kind: LockKind?
        var weekdays: [Int]
        var start: Int
        var end: Int
        var superFrom: Int?
        var superTo: Int?
        var effectiveFrom: String?
    }

    static func migrate(_ raw: [StoredSchedule]) -> (list: [LockSchedule], migrated: Bool) {
        var out: [LockSchedule] = []
        var migrated = false
        let day = LockSchedule.dayMinutes
        for r in raw {
            if let k = r.kind {
                out.append(LockSchedule(id: r.id, kind: k, weekdays: r.weekdays, start: r.start, end: r.end,
                                        effectiveFrom: r.effectiveFrom ?? ISO.now))
                continue
            }
            migrated = true
            let eff = r.effectiveFrom ?? ISO.now
            out.append(LockSchedule(id: r.id, kind: .normal, weekdays: r.weekdays, start: r.start, end: r.end, effectiveFrom: eff))
            guard let f = r.superFrom, let t = r.superTo, f >= 0, t - f >= LockSchedule.step else { continue }
            let s0 = r.start + f
            let shift = s0 / day
            let weekdays = r.weekdays.map { ($0 - 1 + shift) % 7 + 1 }.sorted()
            let superEff = ISO.parse(eff).map { ISO.string($0.addingTimeInterval(TimeInterval(f * 60))) } ?? ISO.now
            out.append(LockSchedule(id: r.id + "s", kind: .strict, weekdays: weekdays,
                                    start: s0 % day, end: (r.start + t) % day, effectiveFrom: superEff))
        }
        return (out, migrated)
    }

    /// §9.9 の形の schedules.json・schedule-runs.json を §9.11 の形で書き戻す（本体の起動時）。何度呼んでも同じ。
    /// 書き戻さなくても読むたびに同じ形へ分けるので、拡張が先に起きても同じに動く（id も名前も決まった作り方）
    static func migrateIfNeeded(route: String) {
        if let raw = Store.codable(file, as: [StoredSchedule].self) {
            let (list, migrated) = migrate(raw)
            if migrated {
                Store.setCodable(file, list)
                Log.add(kind: "scheduleMigrate", route: route, ok: load() == list,
                        detail: "§9.9→§9.11 \(raw.count)個→通常\(of(.normal, in: list).count)個・スーパー\(of(.strict, in: list).count)個")
            }
        }
        if let raw = Store.codable(runsFile, as: [StoredRun].self), raw.contains(where: { $0.kind == nil }) {
            let list = flatten(raw)
            runs = list
            Log.add(kind: "scheduleMigrate", route: route, detail: "確定済みの回 \(raw.count)件→\(list.count)件")
        }
    }

    /// 保存して予定を登録し直す（本体から）。断るときは理由。iOS への登録に失敗したら保存を戻す
    static func save(_ s: LockSchedule) -> String? {
        if let r = s.invalidReason { return r }
        // 読めないとき（壊れている・データ保護中）は変えない（空として書いて、全部を消してしまわない）
        guard let before = load() else { return unreadableMessage }
        var list = before
        var item = s
        item.effectiveFrom = ISO.now   // 次の回から効く
        if let i = list.firstIndex(where: { $0.id == s.id }) {
            item.kind = list[i].kind   // 種類は変えない
            list[i] = item
        } else {
            guard of(s.kind, in: list).count < maxCount else { return "\(s.kind.name)のスケジュールは\(maxCount)個までです。" }
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
        Log.add(kind: "schedule", detail: "保存 \(item.id) \(item.kind.rawValue) \(item.weekdaysText) \(item.periodText)")
        return nil
    }

    static let unreadableMessage = "スケジュールを読み込めないため、変更できません。"

    /// 消す（本体から）。いま掛かっている回（確定済みの回）はそのまま（§9.9 の7）。断るときは理由
    static func delete(id: String) -> String? {
        // 読めないとき（壊れている・データ保護中）は変えない（空として書いて、全部を消してしまわない）
        guard let before = load() else {
            Log.add(kind: "schedule", ok: false, error: "読めないので消さない", detail: "削除 \(id)")
            return unreadableMessage
        }
        Store.setCodable(file, before.filter { $0.id != id })
        let ok = load().map { !$0.contains { $0.id == id } } ?? false
        let e = syncMonitoring(route: "schedule")
        Log.add(kind: "schedule", ok: ok && e == nil, error: ok ? e : "削除を保存できなかった", detail: "削除 \(id)")
        return ok ? nil : "スケジュールを消せませんでした。もう一度お試しください。"
    }

    // MARK: 確定済みの回（始まった回の中身を写したもの）
    //
    //   回が始まったとき（apply が時間帯の中だと判断したとき）に、その回の種類と始まり・終わりを写しておく。
    //   以後その回は、スケジュールを編集・削除しても写した中身で進む（§9.9 の7）。回の判定は「回の始まりが
    //   effectiveFrom より後か」の1つだけ（進行中の回に足した・変えたスケジュールは次の回から）。終わりを過ぎたら消す

    struct Run: Codable, Equatable {
        var scheduleID: String
        var kind: LockKind
        var start: Date
        var end: Date
    }

    /// schedule-runs.json の1件（§9.9 の形＝normalStart〜superEnd も読める）
    struct StoredRun: Decodable {
        var scheduleID: String
        var kind: LockKind?
        var start: Date?
        var end: Date?
        var normalStart: Date?
        var normalEnd: Date?
        var superStart: Date?
        var superEnd: Date?
    }

    static func flatten(_ raw: [StoredRun]) -> [Run] {
        var out: [Run] = []
        for r in raw {
            if let k = r.kind, let s = r.start, let e = r.end {
                out.append(Run(scheduleID: r.scheduleID, kind: k, start: s, end: e))
                continue
            }
            // §9.9 の形: ロック期間 → 通常の回、スーパーの時間帯 → スーパーの回（id は引き継いだスーパーのスケジュールと同じ）
            if let s = r.normalStart, let e = r.normalEnd {
                out.append(Run(scheduleID: r.scheduleID, kind: .normal, start: s, end: e))
            }
            if let s = r.superStart, let e = r.superEnd {
                out.append(Run(scheduleID: r.scheduleID + "s", kind: .strict, start: s, end: e))
            }
        }
        return out
    }

    static let runsFile = "schedule-runs.json"

    static var runs: [Run] {
        get { Store.codable(runsFile, as: [StoredRun].self).map(flatten) ?? [] }
        set { Store.setCodable(runsFile, newValue.isEmpty ? nil : newValue) }
    }

    /// 確定済みのスーパーの回のうち、これから始まるものでいちばん早いもの（一発の目覚ましの対象）。
    /// §9.11 では回は始まってから確定するので、ふつうは §9.9 から引き継いだ回と、少し早く確定した回だけが対象
    static func nextRunStrictStart(after now: Date) -> Date? {
        runs.filter { $0.kind == .strict }.map(\.start).filter { $0 > now }.min()
    }

    /// いまがどれかの回の中なら、その回の終わりまで通常ロック／スーパーロックの期限を伸ばす（縮めない）。
    /// reconcile の頭で呼ぶ。lead: 始まりの目覚ましが少し早く来たとき用。grace: 終わりの目覚ましが少し早く来たとき、
    /// 終わりかけの回を当て直さないため
    static func apply(now: Date, lead: TimeInterval, strictGrace: TimeInterval, normalGrace: TimeInterval, route: String) {
        let before = runs
        var list = before.filter { $0.end > now }
        // 始まった回を確定する（中身はこの時点のスケジュールから写す）
        for s in all {
            guard let from = ISO.parse(s.effectiveFrom) else { continue }
            for o in s.occurrences(around: now) where o.start >= from {
                guard now >= o.start.addingTimeInterval(-lead), now < o.end else { continue }
                if list.contains(where: { $0.scheduleID == s.id && $0.kind == s.kind && abs($0.start.timeIntervalSince(o.start)) < 1 }) { continue }
                list.append(Run(scheduleID: s.id, kind: s.kind, start: o.start, end: o.end))
                Log.add(kind: "scheduleRun", route: route,
                        detail: "確定 \(s.id) \(s.kind.rawValue) \(ISO.string(o.start))〜\(ISO.string(o.end))")
            }
        }
        if list != before { runs = list }
        // 確定済みの回だけで決める
        var normalTo: Date?
        var strictTo: Date?
        for r in list where now >= r.start.addingTimeInterval(-lead) {
            switch r.kind {
            case .normal:
                if now < r.end.addingTimeInterval(-normalGrace) { normalTo = max(normalTo ?? r.end, r.end) }
            case .strict:
                if now < r.end.addingTimeInterval(-strictGrace) { strictTo = max(strictTo ?? r.end, r.end) }
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
    /// スケジュールのファイルが読めない（壊れている・データ保護中）ときは予定に触らない（黙って全部止めない）。
    /// 種類ごとに maxCount 個までしか登録しない（監視の数の見積もり＝最大14件を超えない）
    @discardableResult
    static func syncMonitoring(route: String) -> String? {
        guard let list = load() else {
            Log.add(kind: "scheduleMonitor", route: route, ok: false, error: "スケジュールが読めないので予定はそのまま")
            return nil
        }
        let center = DeviceActivityCenter()
        var desired: [DeviceActivityName: DeviceActivitySchedule] = [:]
        for kind in LockKind.allCases {
            for s in of(kind, in: list).filter({ $0.invalidReason == nil }).prefix(maxCount) {
                desired[s.activityName] = s.activitySchedule
            }
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
        return errors.isEmpty ? nil : "スケジュールの予定を iOS に設定できませんでした。時刻を変えてもう一度お試しください。"
    }

    private static func same(_ a: DeviceActivitySchedule, _ b: DeviceActivitySchedule) -> Bool {
        a.repeats == b.repeats
            && a.intervalStart.hour == b.intervalStart.hour && a.intervalStart.minute == b.intervalStart.minute
            && a.intervalEnd.hour == b.intervalEnd.hour && a.intervalEnd.minute == b.intervalEnd.minute
    }
}
