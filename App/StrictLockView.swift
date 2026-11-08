import SwiftUI
import FamilyControls
import ManagedSettings

// スーパーロックの画面（本番設計 §9.6・§9.8。型名は厳格ロック＝Strict のまま、画面上の呼び方はスーパーロック）。
// 見た目は縁側の部品（Theme.swift）。
//   StrictLockedHome   スーパーロック中のホーム。残り時間と終了時刻。解除の入口は置かない
//                      （通常ロックで残すアプリの選び直しとスケジュールの編集はできる。どちらもスーパーロックを弱めない）
//   StrictWaitingHome  ホーム（ロックなし・通常ロック中）。通常ロックとスーパーロックの2つの始め方（§9.9）、
//                      通常ロックで残すアプリ、スーパーロックで使うアプリ、スケジュール
//   KeepAppsSheet      スーパーロックで使うアプリ（登録済み・追加する・許可一覧と標準アプリの一言）
//   StrictStartSheet   時間の選択 → 確認（通常ロック・スーパーロック）。「やめる」では何も変えない

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

    /// 見出しの上の日付（「11月8日 日曜日」）
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 EEEE"
        return f
    }()
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
                Text(StatusHeadline.day.string(from: Date()))
                    .font(.system(.footnote, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(Theme.ink2)
                StatusHeadline(title: "スーパーロック中", dot: Theme.dusk)
                if let until = model.strictLockUntil {
                    Text("残り \(Text(StrictLock.remaining(until)).fontWeight(.semibold).foregroundStyle(Theme.ink))（\(StrictLock.clock(until)) まで）")
                        .font(.subheadline).foregroundStyle(Theme.ink2).monospacedDigit()
                }
                Text("解除はできません")
                    .noteStyle()
                if let n = model.normalLockUntil, let st = model.strictLockUntil, n > st {
                    Text("スーパーロックが終わったあと、\(StrictLock.clock(n)) まで通常ロックが続きます。")
                        .noteStyle()
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 20) {
                    NormalAppsBlock()
                    ScheduleBlock()
                }
                .padding(.top, 16)
            }
        } actions: {
            EmptyView()
        }
    }
}

// MARK: - トークンなしのホーム

struct StrictWaitingHome: View {
    @EnvironmentObject var model: AppModel
    @State private var startKind: LockKind? = nil
    @State private var showKeep = false
    @State private var demoMinutes: Int? = nil

    private var approved: Bool { model.authStatus == .approved }

    var body: some View {
        SceneryPage(locked: false) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(StatusHeadline.day.string(from: Date()))
                        .font(.system(.footnote, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(Theme.ink2)
                    if model.normalLockActive, let until = model.normalLockUntil {
                        StatusHeadline(title: "通常ロック中", dot: Theme.caution)
                        Text("残り \(Text(StrictLock.remaining(until)).fontWeight(.semibold).foregroundStyle(Theme.ink))（\(StrictLock.clock(until)) まで）")
                            .font(.subheadline).foregroundStyle(Theme.ink2).monospacedDigit()
                        Text("残すアプリ以外を止めています。解除はできません")
                            .noteStyle()
                    } else {
                        StatusHeadline(title: "使えます", dot: Theme.field)
                        Text("止めたいときに、時間を決めてロックします。")
                            .font(.subheadline).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !approved {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("スクリーンタイムの許可がまだです。スーパーロックは、許可してから使えます。")
                            .font(.callout).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("スクリーンタイムを許可する") { model.requestAuth() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(18)
                    .paperCard()
                }
                if model.keepVerifying {
                    VerifyingNote()
                }
                NormalAppsBlock()
                keepBlock
                ScheduleBlock()
            }
        } actions: {
            HStack(spacing: 10) {
                Button(model.normalLockActive ? "通常ロック中" : "通常ロック") { startKind = .normal }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!approved || model.normalLockActive)
                Button("スーパーロック") { startKind = .strict }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!approved || model.keepApps.count > KeepApps.limit)
            }
            .padding(.horizontal, Theme.sideMargin)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background(Theme.paper.ignoresSafeArea(edges: .bottom))
        }
        .sheet(item: $startKind) { kind in
            StrictStartSheet(kind: kind, initialMinutes: demoMinutes).environmentObject(model)
        }
        .sheet(isPresented: $showKeep) {
            KeepAppsSheet().environmentObject(model)
        }
        #if DEBUG
        .onAppear {
            if let m = UIDemo.strictSheetMinutes {
                demoMinutes = m > 0 ? m : nil
                startKind = UIDemo.mode == "normal-confirm" ? .normal : .strict
            }
            if UIDemo.mode == "keep-apps" { showKeep = true }
        }
        #endif
    }

    private var keepBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("スーパーロックで使うアプリ").sectionLabelStyle()
            VStack(alignment: .leading, spacing: 0) {
                if model.keepApps.isEmpty {
                    Text("まだ登録していません")
                        .font(.callout).foregroundStyle(Theme.ink2)
                        .padding(.vertical, 12)
                } else {
                    ForEach(model.keepApps, id: \.self) { token in
                        Label(token)
                            .foregroundStyle(Theme.ink)
                            .padding(.vertical, 10)
                        Rectangle().fill(Theme.line).frame(height: 0.5)
                    }
                }
                Button("登録・削除…") { showKeep = true }
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
            Text("スーパーロック中も使えるアプリです。縁側は止まらないので、ロック中も開いて残り時間を見られます。電話・メッセージなど iOS に最初から入っているアプリも止まりません。")
                .font(.caption).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 登録の確かめ中の案内（ホームとシートで共用）。「終える」で一時的な止めを全部外す
private struct VerifyingNote: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("確かめ中のアプリが\(model.keepPending)個あります")
                .font(.system(.callout, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("選んだアプリを1つずつ開いて、出てきた画面の「スーパーロックで使えるようにする」を押してください。一覧にないアプリは「閉じる」だけが出て、登録できません。")
                .font(.callout).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("確かめ中のアプリは、終えるまで一時的に止まっています。")
                .font(.footnote).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Button("終える") { model.stopKeepVerify() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(18)
        .paperCard()
    }
}

// MARK: - スーパーロックで使うアプリ（§9.8 B）
// 上から ①登録済み（削除できる）②追加する ③許可一覧と標準アプリの一言（地の文）。
// スーパーロック中はホームごと StrictLockedHome になるのでここへは来ない（KeepApps 側でも断る）

struct KeepAppsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidates = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var message: String? = nil

    private var approved: Bool { model.authStatus == .approved }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SheetHeader(title: "スーパーロックで使うアプリ") { dismiss() }

                // ① 登録済み
                VStack(alignment: .leading, spacing: 8) {
                    Text("登録済み").sectionLabelStyle()
                    VStack(alignment: .leading, spacing: 0) {
                        if model.keepApps.isEmpty {
                            Text("まだ登録していません")
                                .font(.callout).foregroundStyle(Theme.ink2)
                                .padding(.vertical, 12)
                        }
                        ForEach(Array(model.keepApps.enumerated()), id: \.element) { i, token in
                            if i > 0 { Rectangle().fill(Theme.line).frame(height: 0.5) }
                            HStack {
                                Label(token).foregroundStyle(Theme.ink)
                                Spacer(minLength: 12)
                                if !model.strictLockActive {
                                    Button("削除") { model.removeKeepApp(token) }
                                        .font(.system(.callout, weight: .medium))
                                        .foregroundStyle(Theme.danger)
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 16)
                    .paperCard(radius: 14)
                }

                // ② 追加する
                if model.keepVerifying {
                    VerifyingNote()
                } else if !model.strictLockActive {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("追加する…") {
                            candidates = FamilyActivitySelection()
                            message = nil
                            showPicker = true
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!approved)
                        Text("登録したいアプリを選ぶと、そのアプリを一時的に止めます。開いて出てきた画面のボタンで登録します。")
                            .font(.footnote).foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // ③ 許可一覧（押せるものに見えないよう、カードにも行にもしない地の文）
                VStack(alignment: .leading, spacing: 6) {
                    Text("登録できるのは次のアプリだけです")
                        .font(.footnote.weight(.medium)).foregroundStyle(Theme.ink2)
                    Text(KeepApps.allowList.map(\.name).joined(separator: "・"))
                        .font(.footnote).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("電話・メッセージなど iOS に最初から入っているアプリは、登録しなくても使えます")
                        .font(.footnote).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
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
        .familyActivityPicker(isPresented: $showPicker, selection: $candidates)
        .onChange(of: showPicker) { _, shown in
            // ピッカーを閉じたら、選んだ候補で確かめを始める（何も選ばずに閉じたら何もしない）
            guard !shown else { return }
            message = model.startKeepVerify(candidates)
        }
    }
}

// MARK: - 時間の選択 → 確認

/// ホームの2つの始め方（§9.9）
enum LockKind: String, Identifiable {
    case normal, strict
    var id: String { rawValue }
    var name: String { self == .normal ? "通常ロック" : "スーパーロック" }
}

struct StrictStartSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var kind: LockKind = .strict
    /// 見た目の確認用（UIDemo）: 確認の段から出す
    var initialMinutes: Int? = nil
    @State private var minutes: Int? = nil
    @State private var error: String? = nil

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
            Text(kind == .normal ? "通常ロックは、残すアプリ以外のアプリを止めます。始めると、時間が来るまで解除できません。"
                                 : "始めると、時間が来るまで解除できません。")
                .font(.subheadline).foregroundStyle(Theme.ink2)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.everyMinute) { ctx in
                VStack(spacing: 10) {
                    ForEach(StrictLock.minuteChoices, id: \.self) { m in
                        Button("\(StrictLock.duration(m))（\(StrictLock.clock(ctx.date.addingTimeInterval(TimeInterval(m * 60)), now: ctx.date))まで）") {
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

    @ViewBuilder
    private func confirm(_ m: Int) -> some View {
        if kind == .normal { confirmNormal(m) } else { confirmStrict(m) }
    }

    private func confirmNormal(_ m: Int) -> some View {
        let keep = model.normalKeep
        let tooMany = keep.count > NormalLock.appLimit
        return TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                Text("\(StrictLock.clock(ctx.date.addingTimeInterval(TimeInterval(m * 60)), now: ctx.date)) まで通常ロック")
                    .font(Theme.mincho(26, relativeTo: .title))
                    .tracking(1)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Text("始めると、途中で止める方法はありません。残すアプリは、ロック中も選び直せます。")
                    .font(.subheadline).foregroundStyle(Theme.ink2)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    row(title: "止まるもの", text: "残すアプリと縁側以外のすべてのアプリ。電話・メッセージなど iOS に最初から入っているアプリは止まりません。ウェブサイトは止めません。")
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                    row(title: "残すアプリ", text: keep.isEmpty ? "選んでいません。ホームの「通常ロックで残すアプリ」で、ロック中も足せます。" : "\(keep.count)個")
                    if !keep.isEmpty {
                        ForEach(Array(keep.prefix(6)), id: \.self) { t in
                            Label(t).foregroundStyle(Theme.ink).padding(.bottom, 8)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .paperCard(radius: 14)
                .padding(.top, 20)

                if let message = tooMany ? NormalLock.tooManyApps : error {
                    Text(message).font(.footnote).foregroundStyle(Theme.danger)
                        .padding(.top, 10)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    if let e = model.startNormalLock(minutes: m) { error = e } else { dismiss() }
                } label: {
                    Text("\(StrictLock.duration(m))通常ロックする").monospacedDigit()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(tooMany)
                .padding(.top, 22)
                Button("やめる") { dismiss() }
                    .buttonStyle(PlainWoodButtonStyle())
                    .padding(.top, 10)
            }
        }
    }

    private func confirmStrict(_ m: Int) -> some View {
        let keep = model.keepApps
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
                    row(title: "止まるもの", text: "スーパーロックで使うアプリと縁側以外のすべてのアプリと、すべてのウェブサイト。電話・メッセージなど iOS に最初から入っているアプリは止まりません。")
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                    row(title: "変えられなくなるもの", text: "この iPhone のアプリは、どれも削除できなくなります。日付と時刻も自動設定のままになります。")
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                    row(title: "使えるアプリ", text: keep.isEmpty ? "登録していません。縁側は開けるので、残り時間はいつでも見られます。" : "\(keep.count)個")
                    if !keep.isEmpty {
                        ForEach(Array(keep.prefix(6)), id: \.self) { t in
                            Label(t).foregroundStyle(Theme.ink).padding(.bottom, 8)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .paperCard(radius: 14)
                .padding(.top, 20)

                if let message = keep.count > KeepApps.limit ? StrictLock.tooManyKeepApps : error {
                    Text(message).font(.footnote).foregroundStyle(Theme.danger)
                        .padding(.top, 10)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    if let e = model.startStrictLock(minutes: m) { error = e } else { dismiss() }
                } label: {
                    Text("\(StrictLock.duration(m))スーパーロックする").monospacedDigit()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(keep.count > KeepApps.limit)
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
