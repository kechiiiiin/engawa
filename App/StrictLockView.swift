import SwiftUI
import FamilyControls

// 厳格ロックの画面（本番設計 §9.6）。見た目は HomeView と同じ部品（Theme.swift）。
//   StrictLockedHome   ロック中のホーム。残り時間と終了時刻だけで、操作を置かない（トークンの有無によらない）
//   StrictWaitingHome  トークンなしのホーム。許可 → 残すアプリ → ロックを始める
//   StrictStartSheet   時間の選択 → 確認。「やめる」では何も変えない

/// ホームの大きな状態の見出し（明朝＋小さな丸）
struct StatusHeadline: View {
    let title: String
    let dot: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(Theme.mincho(38, relativeTo: .largeTitle))
                .tracking(2.3)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Circle()
                .fill(dot)
                .frame(width: 9, height: 9)
                .background(Circle().fill(dot.opacity(0.16)).frame(width: 17, height: 17))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 景色の上に中身を重ねる、ホームと同じ組み方
private struct SceneryPage<Content: View, Actions: View>: View {
    let locked: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SceneryHero(locked: locked)
                content
                    .padding(.horizontal, Theme.sideMargin)
                    .padding(.top, -62)
                    .padding(.bottom, 24)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectHidden(true, for: .top)   // 景色の上をぼかさない
        .ignoresSafeArea(edges: .top)
        .background(Theme.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .navigationTitle("ホーム")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black.opacity(0.01), for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)   // 景色の上なのでステータスバーの文字を明るく
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }   // 「ホーム」は出さない
        }
    }
}

// MARK: - ロック中のホーム

struct StrictLockedHome: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SceneryPage(locked: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text(HomeView.day.string(from: Date()))
                    .font(.system(.footnote, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(Theme.ink2)
                StatusHeadline(title: "ロック中", dot: Theme.dusk)
                if let until = model.strictLockUntil {
                    Text("残り \(Text(StrictLock.remaining(until)).fontWeight(.semibold).foregroundStyle(Theme.ink))（\(StrictLock.clock(until)) まで）")
                        .font(.subheadline).foregroundStyle(Theme.ink2).monospacedDigit()
                }
                Text("解除はできません")
                    .noteStyle()
            }
        } actions: {
            EmptyView()
        }
    }
}

// MARK: - トークンなしのホーム

struct StrictWaitingHome: View {
    @EnvironmentObject var model: AppModel
    @State private var showPicker = false
    @State private var showStart = false
    @State private var demoMinutes: Int?

    private var approved: Bool { model.authStatus == .approved }

    var body: some View {
        SceneryPage(locked: false) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(HomeView.day.string(from: Date()))
                        .font(.system(.footnote, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(Theme.ink2)
                    StatusHeadline(title: "使えます", dot: Theme.field)
                    Text("止めたいときに、時間を決めてロックします。")
                        .font(.subheadline).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !approved {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("スクリーンタイムの許可がまだです。ロックは、許可してから使えます。")
                            .font(.callout).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("スクリーンタイムを許可する") { model.requestAuth() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(18)
                    .paperCard()
                }
                keepBlock
            }
        } actions: {
            Button("ロックを始める") { showStart = true }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!approved || model.superSelection.applicationTokens.count > AppUnlocks.limit)
                .padding(.horizontal, Theme.sideMargin)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .background(Theme.paper.ignoresSafeArea(edges: .bottom))
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $model.superSelection)
        .onChange(of: model.superSelection) { _, s in model.saveSuperSelection(s) }
        .sheet(isPresented: $showStart) {
            StrictStartSheet(initialMinutes: demoMinutes).environmentObject(model)
        }
        #if DEBUG
        .onAppear { if let m = UIDemo.strictSheetMinutes { demoMinutes = m > 0 ? m : nil; showStart = true } }
        #endif
    }

    private var keepBlock: some View {
        let sel = model.superSelection
        return VStack(alignment: .leading, spacing: 10) {
            Text("残すアプリ").sectionLabelStyle()
            VStack(alignment: .leading, spacing: 0) {
                if sel.applicationTokens.isEmpty {
                    Text("まだ選んでいません")
                        .font(.callout).foregroundStyle(Theme.ink2)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(sel.applicationTokens), id: \.self) { token in
                        Label(token)
                            .foregroundStyle(Theme.ink)
                            .padding(.vertical, 10)
                        Rectangle().fill(Theme.line).frame(height: 0.5)
                    }
                }
                Button(sel.applicationTokens.isEmpty ? "アプリを選ぶ…" : "選び直す…") { showPicker = true }
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
            if sel.applicationTokens.count > AppUnlocks.limit {
                Text(StrictLock.tooManyKeepApps)
                    .font(.footnote).foregroundStyle(Theme.danger)
            }
            if !sel.categoryTokens.isEmpty {
                Text("カテゴリで選んだものは残りません。アプリを個別に選んでください。")
                    .font(.footnote).foregroundStyle(Theme.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("ロック中も使えるアプリです。縁側は選ばなくても止まらないので、ロック中も開いて残り時間を見られます。電話などは iOS の仕様で止まりません。")
                .font(.caption).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 時間の選択 → 確認

struct StrictStartSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// 見た目の確認用（UIDemo）: 確認の段から出す
    var initialMinutes: Int? = nil
    @State private var minutes: Int?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let minutes {
                    confirm(minutes)
                } else {
                    choose
                }
            }
            .padding(.horizontal, Theme.sideMargin)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.paper)
        .presentationCornerRadius(28)
        .onAppear { if minutes == nil { minutes = initialMinutes } }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "どのくらい止めますか") { dismiss() }
            Text("始めると、時間が来るまで解除できません。")
                .font(.subheadline).foregroundStyle(Theme.ink2)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.everyMinute) { ctx in
                VStack(spacing: 10) {
                    ForEach(StrictLock.minuteChoices, id: \.self) { m in
                        Button("\(AppSettings.duration(m))（\(StrictLock.clock(ctx.date.addingTimeInterval(TimeInterval(m * 60)), now: ctx.date))まで）") {
                            withAnimation(.easeOut(duration: 0.2)) { minutes = m }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .monospacedDigit()
                    }
                }
            }
            .padding(.top, 22)
            Button("やめる") { dismiss() }
                .buttonStyle(PlainWoodButtonStyle())
                .padding(.top, 10)
        }
    }

    private func confirm(_ m: Int) -> some View {
        let keep = model.superSelection.applicationTokens
        return TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                Text("\(StrictLock.clock(ctx.date.addingTimeInterval(TimeInterval(m * 60)), now: ctx.date)) まで解除できません")
                    .font(Theme.mincho(26, relativeTo: .title))
                    .tracking(1)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Text("始めると、途中で止める方法はありません。時間が来ると、自動で使えるようになります。")
                    .font(.subheadline).foregroundStyle(Theme.ink2)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    row(title: "止まるもの", text: "残すアプリと縁側以外のすべて。電話などは iOS の仕様で止まりません。")
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                    row(title: "変えられなくなるもの", text: "この iPhone のアプリは、どれも削除できなくなります。日付と時刻も自動設定のままになります。")
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                    row(title: "残すアプリ", text: keep.isEmpty ? "ありません。縁側は開けるので、残り時間はいつでも見られます。" : "\(keep.count)個")
                    if !keep.isEmpty {
                        ForEach(Array(keep.prefix(6)), id: \.self) { t in
                            Label(t).foregroundStyle(Theme.ink).padding(.bottom, 8)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .paperCard(radius: 14)
                .padding(.top, 20)

                if let message = keep.count > AppUnlocks.limit ? StrictLock.tooManyKeepApps : error {
                    Text(message).font(.footnote).foregroundStyle(Theme.danger)
                        .padding(.top, 10)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    if let e = model.startStrictLock(minutes: m) { error = e } else { dismiss() }
                } label: {
                    Text("\(AppSettings.duration(m))ロックする").monospacedDigit()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(keep.count > AppUnlocks.limit)
                .padding(.top, 22)
                Button("やめる") { dismiss() }
                    .buttonStyle(PlainWoodButtonStyle())
                    .padding(.top, 10)
            }
        }
    }

    private func row(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).sectionLabelStyle()
            Text(text)
                .font(.callout).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
