import SwiftUI
import FamilyControls
import ManagedSettings

// 通常ロックの使えるアプリとスケジュールの画面（本番設計 §9.9・§9.10・§9.11）。見た目は縁側の部品（Theme.swift）。
// 画面上は通常ロックを「ロック」とだけ呼ぶ（§9.11）。
//   NormalAppsBlock     ロックのタブの「使えるアプリ」。ロック中も追加・削除できて、即反映
//   ScheduleBlock       各タブのスケジュール一覧（種類ごとに5個まで）。ロック中も編集できるが、いまのロックは変わらない
//   ScheduleEditSheet   曜日・時間帯・1日の流れの帯
//   DayBand             0時〜24時の帯。時間帯を種類の色で出す（日をまたぐ分は左端へ回す）

// MARK: - ロックの使えるアプリ（§9.10）

struct NormalAppsBlock: View {
    @EnvironmentObject var model: AppModel
    @State private var picking = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var message: String? = nil

    private var approved: Bool { model.authStatus == .approved }

    private var caption: String {
        if model.strictLockActive {
            return "スーパーロック中は、ここにある使えるアプリも止まります。スーパーロックのあとにロックが続くときに使えます。"
        }
        if model.normalLockActive {
            return "ロック中も追加と削除ができます。追加したアプリはすぐに使え、削除したアプリはすぐに止まります。"
        }
        return "ロック中は、ここにある使えるアプリと縁側、電話・メッセージなど iOS に最初から入っているアプリだけが使えます。ウェブサイトは止めません。カテゴリごとは追加できないので、アプリを1つずつ選んでください。"
    }

    /// 1つだけ削除する（ロック中も即反映）
    private func remove(_ token: ApplicationToken) {
        var sel = NormalLock.keepSelection
        sel.applicationTokens.remove(token)
        message = model.setNormalKeep(sel)
    }

    var body: some View {
        let apps = Array(model.normalKeep)
        VStack(alignment: .leading, spacing: 10) {
            Text("使えるアプリ").sectionLabelStyle()
            VStack(alignment: .leading, spacing: 0) {
                if apps.isEmpty {
                    Text("まだ追加していません（縁側と iOS に最初から入っているアプリ以外は、全部止まります）")
                        .font(.callout).foregroundStyle(Theme.ink2)
                        .padding(.vertical, 12)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(apps, id: \.self) { t in
                        HStack {
                            Label(t).foregroundStyle(Theme.ink)
                            Spacer(minLength: 12)
                            Button("削除") { remove(t) }
                                .font(.system(.callout, weight: .medium))
                                .foregroundStyle(Theme.danger)
                                .buttonStyle(.plain)
                        }
                        .padding(.vertical, 10)
                        Rectangle().fill(Theme.line).frame(height: 0.5)
                    }
                }
                Button("追加する…") {
                    picking = NormalLock.keepSelection
                    message = nil
                    showPicker = true
                }
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Theme.wood)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .disabled(!approved)
            }
            .padding(.horizontal, 16)
            .paperCard(radius: 14)
            Text(caption)
                .font(.caption).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.footnote).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .familyActivityPicker(headerText: "名前を検索欄に打つと、カテゴリを開かずに選べます", isPresented: $showPicker, selection: $picking)
        .onChange(of: showPicker) { _, shown in
            guard !shown else { return }
            guard picking.applicationTokens != model.normalKeep || !picking.categoryTokens.isEmpty else { return }
            message = model.setNormalKeep(picking)
        }
    }
}

// MARK: - スケジュール一覧（種類ごと・§9.11）

struct ScheduleBlock: View {
    @EnvironmentObject var model: AppModel
    let kind: LockKind
    @State private var editing: LockSchedule? = nil

    private var approved: Bool { model.authStatus == .approved }
    private var list: [LockSchedule] { Schedules.of(kind, in: model.schedules) }

    private var caption: String {
        kind == .normal
            ? "決まった時刻に、縁側を開かなくてもロックが掛かります。スーパーロックのスケジュールと重なったときは、スーパーロックが優先されます。"
            : "決まった時刻に、縁側を開かなくてもスーパーロックが掛かります。終わったときにロックの時間内なら、ロックに戻ります。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("スケジュール").sectionLabelStyle()
            VStack(alignment: .leading, spacing: 0) {
                if list.isEmpty {
                    Text("まだありません")
                        .font(.callout).foregroundStyle(Theme.ink2)
                        .padding(.vertical, 12)
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                }
                ForEach(list) { s in
                    Button { editing = s } label: { ScheduleRow(schedule: s) }
                        .buttonStyle(.plain)
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                }
                if list.count < Schedules.maxCount {
                    Button("スケジュールを追加…") { editing = LockSchedule(kind: kind) }
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Theme.wood)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .disabled(!approved)
                } else {
                    Text("スケジュールは\(Schedules.maxCount)個までです")
                        .font(.footnote).foregroundStyle(Theme.ink2)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
            .paperCard(radius: 14)
            Text(caption)
                .font(.caption).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { s in
            ScheduleEditSheet(original: s, isNew: !model.schedules.contains { $0.id == s.id })
                .environmentObject(model)
        }
        #if DEBUG
        .onAppear {
            if UIDemo.mode == "schedule-edit", kind == .normal, let first = list.first { editing = first }
        }
        #endif
    }
}

private struct ScheduleRow: View {
    let schedule: LockSchedule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(schedule.weekdaysText)
                    .font(.system(.callout, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(schedule.periodText)
                    .font(.callout).foregroundStyle(Theme.ink).monospacedDigit()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3)
            }
            DayBand(schedule: schedule, compact: true)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - 1日の流れの帯

struct DayBand: View {
    let schedule: LockSchedule
    var compact = false

    private var color: Color { schedule.kind == .strict ? Theme.dusk : Theme.woodLight.opacity(0.45) }

    /// 0時からの分の区間（日をまたぐ分は2つに割る）
    private func pieces(_ a: Int, _ b: Int) -> [(Int, Int)] {
        let day = LockSchedule.dayMinutes
        let s = a % day, e = s + (b - a)
        return e <= day ? [(s, e)] : [(s, day), (0, e - day)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (m: Int) in w * CGFloat(m) / CGFloat(LockSchedule.dayMinutes) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.paper2)
                    ForEach(Array(pieces(schedule.start, schedule.start + schedule.length).enumerated()), id: \.offset) { _, p in
                        Rectangle().fill(color)
                            .frame(width: max(1, x(p.1) - x(p.0)))
                            .offset(x: x(p.0))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: compact ? 8 : 18)
            if !compact {
                HStack {
                    ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                        Text("\(h)").font(.caption2).foregroundStyle(Theme.ink3).monospacedDigit()
                        if h != 24 { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(schedule.kind.name) \(schedule.periodText)")
    }
}

// MARK: - 編集

struct ScheduleEditSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let original: LockSchedule
    let isNew: Bool
    @State private var s: LockSchedule
    @State private var error: String? = nil
    @State private var confirmDelete = false

    init(original: LockSchedule, isNew: Bool) {
        self.original = original
        self.isNew = isNew
        _s = State(initialValue: original)
    }

    /// 15分刻みの時刻（0:00〜23:45）
    private static let slots = Array(stride(from: 0, to: LockSchedule.dayMinutes, by: LockSchedule.step))

    private var note: String {
        s.kind == .normal
            ? "この時間帯は、使えるアプリ以外のアプリが止まります。ウェブサイトは止めません。"
            : "この時間帯は、使えるアプリ以外のアプリと、すべてのウェブサイトが止まります。アプリの削除もできなくなり、日付と時刻は自動設定のままになります。"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SheetHeader(title: isNew ? "\(s.kind.name)のスケジュールを追加" : "\(s.kind.name)のスケジュール") { dismiss() }

                if model.anyLockActive {
                    Text("いま掛かっているロックは変わりません。変えた中身は次の回から効きます。")
                        .font(.footnote).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 曜日
                VStack(alignment: .leading, spacing: 8) {
                    Text("曜日（始まる日）").sectionLabelStyle()
                    HStack(spacing: 6) {
                        ForEach(LockSchedule.weekdayOrder, id: \.self) { d in
                            let on = s.weekdays.contains(d)
                            Button {
                                if on { s.weekdays.removeAll { $0 == d } } else { s.weekdays.append(d) }
                            } label: {
                                Text(LockSchedule.weekdayNames[d - 1])
                                    .font(.system(.callout, weight: .semibold))
                                    .foregroundStyle(on ? Theme.onWood : Theme.woodDark)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(Circle().fill(on ? Theme.wood : Color(hex: 0xEBE1D2)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }

                // 時間帯
                VStack(alignment: .leading, spacing: 8) {
                    Text("時間帯").sectionLabelStyle()
                    VStack(spacing: 0) {
                        timeRow("始まり", selection: Binding(get: { s.start }, set: { setStart($0) }),
                                options: Self.slots.map { ($0, LockSchedule.clock($0)) })
                        Rectangle().fill(Theme.line).frame(height: 0.5)
                        timeRow("終わり", selection: Binding(get: { s.start + s.length }, set: { s.end = $0 % LockSchedule.dayMinutes }),
                                options: endOptions)
                    }
                    .padding(.horizontal, 16)
                    .paperCard(radius: 14)
                    Text(note)
                        .font(.caption).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 1日の流れ
                VStack(alignment: .leading, spacing: 8) {
                    Text("1日の流れ").sectionLabelStyle()
                    DayBand(schedule: s)
                        .padding(16)
                        .paperCard(radius: 14)
                }

                if let message = error ?? s.invalidReason {
                    Text(message).font(.footnote).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    Button("保存する") {
                        if let e = model.saveSchedule(s) { error = e } else { dismiss() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(s.invalidReason != nil)
                    if !isNew {
                        Button("このスケジュールを消す") { confirmDelete = true }
                            .buttonStyle(PlainWoodButtonStyle())
                            .foregroundStyle(Theme.danger)
                    }
                    Button("やめる") { dismiss() }
                        .buttonStyle(PlainWoodButtonStyle())
                }
            }
            .padding(.horizontal, Theme.sideMargin)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.paper)
        .presentationCornerRadius(28)
        .confirmationDialog("このスケジュールを消しますか", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                model.deleteSchedule(id: original.id)
                dismiss()
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text(model.anyLockActive ? "いま掛かっているロックは、元の時刻まで続きます。" : "次の回から掛からなくなります。")
        }
    }

    // MARK: 選べる時刻

    /// 終わり: 始まりの15分後〜23時間45分後（翌日は「翌」）
    private var endOptions: [(Int, String)] {
        stride(from: s.start + LockSchedule.step, to: s.start + LockSchedule.dayMinutes, by: LockSchedule.step)
            .map { ($0, LockSchedule.clock($0)) }
    }

    private func setStart(_ v: Int) {
        let len = s.length
        s.start = v
        s.end = (v + len) % LockSchedule.dayMinutes   // 長さを保つ
    }

    private func timeRow(_ title: String, selection: Binding<Int>, options: [(Int, String)]) -> some View {
        HStack {
            Text(title).font(.body).foregroundStyle(Theme.ink)
            Spacer(minLength: 12)
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { o in Text(o.1).tag(o.0) }
            }
            .pickerStyle(.menu)
            .tint(Theme.wood)
            .monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}
