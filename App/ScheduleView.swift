import SwiftUI
import FamilyControls
import ManagedSettings

// 通常ロックで止めるアプリとスケジュールの画面（本番設計 §9.9）。見た目は縁側の部品（Theme.swift）。
//   NormalAppsBlock     ホームの「通常ロックで止めるアプリ」。ロック中も選び直せて、即反映
//   ScheduleBlock       ホームのスケジュール一覧（5個まで）。ロック中も編集できるが、いまのロックは変わらない
//   ScheduleEditSheet   曜日・ロック期間・スーパーロックの時間帯（任意・期間の内側だけ）・1日の流れの帯
//   DayBand             0時〜24時の帯。通常ロックとスーパーロックの時間を色で出す（日をまたぐ分は左端へ回す）

// MARK: - 通常ロックで止めるアプリ

struct NormalAppsBlock: View {
    @EnvironmentObject var model: AppModel
    @State private var picking = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var message: String? = nil

    private var approved: Bool { model.authStatus == .approved }

    var body: some View {
        let sel = model.normalSelection
        let apps = Array(sel.applicationTokens)
        let cats = Array(sel.categoryTokens)
        VStack(alignment: .leading, spacing: 10) {
            Text("通常ロックで止めるアプリ").sectionLabelStyle()
            VStack(alignment: .leading, spacing: 0) {
                if apps.isEmpty && cats.isEmpty {
                    Text("まだ選んでいません")
                        .font(.callout).foregroundStyle(Theme.ink2)
                        .padding(.vertical, 12)
                } else {
                    ForEach(cats.prefix(4), id: \.self) { t in
                        Label(t).foregroundStyle(Theme.ink).padding(.vertical, 10)
                        Rectangle().fill(Theme.line).frame(height: 0.5)
                    }
                    ForEach(apps.prefix(6), id: \.self) { t in
                        Label(t).foregroundStyle(Theme.ink).padding(.vertical, 10)
                        Rectangle().fill(Theme.line).frame(height: 0.5)
                    }
                    let rest = max(0, apps.count - 6) + max(0, cats.count - 4)
                    if rest > 0 {
                        Text("ほか\(rest)個").font(.footnote).foregroundStyle(Theme.ink2).padding(.vertical, 8)
                        Rectangle().fill(Theme.line).frame(height: 0.5)
                    }
                }
                Button("選び直す…") {
                    picking = model.normalSelection
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
            Text(model.normalLockActive
                 ? "ロック中も選び直せます。選び直すとすぐに効きます（外したアプリはその場で使えるようになります）。"
                 : "通常ロックで止まるのは、ここで選んだアプリだけです。ウェブサイトは止めません。")
                .font(.caption).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.footnote).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $picking)
        .onChange(of: showPicker) { _, shown in
            guard !shown, picking != model.normalSelection else { return }
            message = model.setNormalSelection(picking)
        }
    }
}

// MARK: - スケジュール一覧

struct ScheduleBlock: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: LockSchedule? = nil

    private var approved: Bool { model.authStatus == .approved }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("スケジュール").sectionLabelStyle()
            VStack(alignment: .leading, spacing: 0) {
                if model.schedules.isEmpty {
                    Text("まだありません")
                        .font(.callout).foregroundStyle(Theme.ink2)
                        .padding(.vertical, 12)
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                }
                ForEach(model.schedules) { s in
                    Button { editing = s } label: { ScheduleRow(schedule: s) }
                        .buttonStyle(.plain)
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                }
                if model.schedules.count < Schedules.maxCount {
                    Button("スケジュールを足す…") { editing = LockSchedule() }
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
            Text("決まった時刻に、縁側を開かなくても通常ロックが掛かります。スーパーロックの時間帯を入れた日は、その間だけスーパーロックになります。")
                .font(.caption).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { s in
            ScheduleEditSheet(original: s, isNew: !model.schedules.contains { $0.id == s.id })
                .environmentObject(model)
        }
        #if DEBUG
        .onAppear {
            if UIDemo.mode == "schedule-edit", let first = model.schedules.first { editing = first }
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
            if let sup = schedule.superText {
                Text("スーパーロック \(sup)")
                    .font(.footnote).foregroundStyle(Theme.dusk).monospacedDigit()
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
                        Rectangle().fill(Theme.woodLight.opacity(0.45))
                            .frame(width: max(1, x(p.1) - x(p.0)))
                            .offset(x: x(p.0))
                    }
                    if let f = schedule.superFrom, let t = schedule.superTo {
                        ForEach(Array(pieces(schedule.start + f, schedule.start + t).enumerated()), id: \.offset) { _, p in
                            Rectangle().fill(Theme.dusk)
                                .frame(width: max(1, x(p.1) - x(p.0)))
                                .offset(x: x(p.0))
                        }
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
                HStack(spacing: 14) {
                    legend(Theme.woodLight.opacity(0.45), "通常ロック")
                    if schedule.hasSuper { legend(Theme.dusk, "スーパーロック") }
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ロック期間 \(schedule.periodText)" + (schedule.superText.map { "、スーパーロック \($0)" } ?? ""))
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 14, height: 8)
            Text(t).font(.caption).foregroundStyle(Theme.ink2)
        }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SheetHeader(title: isNew ? "スケジュールを足す" : "スケジュール") { dismiss() }

                if model.anyLockActive {
                    Text("いま掛かっているロックは変わりません。変えた中身は次の回から効きます。")
                        .font(.footnote).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 曜日
                VStack(alignment: .leading, spacing: 8) {
                    Text("曜日（ロック期間が始まる日）").sectionLabelStyle()
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

                // ロック期間
                VStack(alignment: .leading, spacing: 8) {
                    Text("ロック期間（通常ロック）").sectionLabelStyle()
                    VStack(spacing: 0) {
                        timeRow("始まり", selection: Binding(get: { s.start }, set: { setStart($0) }),
                                options: Self.slots.map { ($0, LockSchedule.clock($0)) })
                        Rectangle().fill(Theme.line).frame(height: 0.5)
                        timeRow("終わり", selection: Binding(get: { s.start + s.length }, set: { setEnd($0) }),
                                options: endOptions)
                    }
                    .padding(.horizontal, 16)
                    .paperCard(radius: 14)
                }

                // スーパーロックの時間帯（任意）
                VStack(alignment: .leading, spacing: 8) {
                    Text("その中のスーパーロック（入れなくてもよい）").sectionLabelStyle()
                    VStack(spacing: 0) {
                        Toggle(isOn: Binding(get: { s.hasSuper }, set: { setSuper($0) })) {
                            Text("スーパーロックの時間帯を入れる").font(.body).foregroundStyle(Theme.ink)
                        }
                        .tint(Theme.wood)
                        .padding(.vertical, 10)
                        if s.hasSuper {
                            Rectangle().fill(Theme.line).frame(height: 0.5)
                            timeRow("始まり", selection: Binding(get: { s.superFrom ?? 0 }, set: { setSuperFrom($0) }),
                                    options: superFromOptions)
                            Rectangle().fill(Theme.line).frame(height: 0.5)
                            timeRow("終わり", selection: Binding(get: { s.superTo ?? s.length }, set: { s.superTo = $0 }),
                                    options: superToOptions)
                        }
                    }
                    .padding(.horizontal, 16)
                    .paperCard(radius: 14)
                    Text("ロック期間の内側だけ選べます。この間は、スーパーロックで使うアプリ以外が止まり、ウェブサイトも止まります。")
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

    /// ロック期間の終わり: 始まりの15分後〜23時間45分後（翌日は「翌」）
    private var endOptions: [(Int, String)] {
        stride(from: s.start + LockSchedule.step, to: s.start + LockSchedule.dayMinutes, by: LockSchedule.step)
            .map { ($0, LockSchedule.clock($0)) }
    }

    /// スーパーロックの始まり: ロック期間の始まり〜終わりの15分前（期間の始まりからの分）
    private var superFromOptions: [(Int, String)] {
        stride(from: 0, through: s.length - LockSchedule.step, by: LockSchedule.step)
            .map { ($0, LockSchedule.clock(s.start + $0)) }
    }

    /// スーパーロックの終わり: スーパーの始まりの15分後〜ロック期間の終わり
    private var superToOptions: [(Int, String)] {
        let from = (s.superFrom ?? 0) + LockSchedule.step
        guard from <= s.length else { return [] }
        return stride(from: from, through: s.length, by: LockSchedule.step)
            .map { ($0, LockSchedule.clock(s.start + $0)) }
    }

    // MARK: 変更（スーパーの時間帯がロック期間からはみ出さないよう詰める）

    private func setStart(_ v: Int) {
        let len = s.length
        s.start = v
        s.end = (v + len) % LockSchedule.dayMinutes   // 長さを保つ
        clampSuper()
    }

    private func setEnd(_ v: Int) {
        s.end = v % LockSchedule.dayMinutes
        clampSuper()
    }

    private func setSuper(_ on: Bool) {
        if on {
            s.superFrom = 0
            s.superTo = s.length
        } else {
            s.superFrom = nil
            s.superTo = nil
        }
    }

    private func setSuperFrom(_ v: Int) {
        s.superFrom = v
        if let t = s.superTo, t < v + LockSchedule.step { s.superTo = min(s.length, v + LockSchedule.step) }
    }

    private func clampSuper() {
        guard let f = s.superFrom, let t = s.superTo else { return }
        let len = s.length
        if len < LockSchedule.step { return }
        let nt = min(t, len)
        let nf = min(f, nt - LockSchedule.step)
        s.superFrom = max(0, nf)
        s.superTo = max(s.superFrom! + LockSchedule.step, nt)
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
