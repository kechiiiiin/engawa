import SwiftUI
import FamilyControls
import ManagedSettings

// ホームの2つのタブとスーパーロックの画面（本番設計 §9.6・§9.8・§9.11。型名は厳格ロック＝Strict のまま、画面上の呼び方は
// スーパーロック。通常ロックは画面上「ロック」とだけ呼ぶ）。見た目は縁側の部品（Theme.swift）。
//   LockTab           タブ1つ分（ロック／スーパーロック）。いまの状態（ロック中／解除中・残り時間）・今すぐ始める・アプリ・スケジュール。
//                     スーパーロック中は解除の入口を置かない（使えるアプリの追加・削除とスケジュールの編集はできる。どちらもいまのロックを弱めない）
//   KeepAppsSheet     使えるアプリ（一覧・追加する・許可一覧と標準アプリの一言）
//   StrictStartSheet  時間の選択 → 確認（ロック・スーパーロック）。「やめる」では何も変えない

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
                    .padding(.top, SceneryHero.contentOverlap)
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

// MARK: - タブ（§9.11）

struct LockTab: View {
    @EnvironmentObject var model: AppModel
    let kind: LockKind
    @State private var startKind: LockKind? = nil
    @State private var showKeep = false
    @State private var demoMinutes: Int? = nil

    private var approved: Bool { model.authStatus == .approved }
    private var active: Bool { kind == .strict ? model.strictLockActive : model.normalLockActive }
    private var until: Date? { kind == .strict ? model.strictLockUntil : model.normalLockUntil }
    private var lockedDot: Color { kind == .strict ? Theme.dusk : Theme.caution }

    var body: some View {
        SceneryPage(locked: active) {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !approved {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("スクリーンタイムの許可がまだです。\(kind.name)は、許可してから使えます。")
                            .font(.callout).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("スクリーンタイムを許可する") { model.requestAuth() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(18)
                    .paperCard()
                }
                if model.keepVerifying && !model.strictLockActive {
                    VerifyingNote()
                }
                if kind == .normal {
                    NormalAppsBlock()
                } else {
                    keepBlock
                }
                ScheduleBlock(kind: kind)
            }
        } actions: {
            Button(active ? "\(kind.name)中" : "\(kind.name)する") { startKind = kind }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!approved || active || (kind == .strict && model.keepApps.count > KeepApps.limit))
                .padding(.horizontal, Theme.sideMargin)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .background(Theme.paper.ignoresSafeArea(edges: .bottom))
        }
        .sheet(item: $startKind) { k in
            StrictStartSheet(kind: k, initialMinutes: demoMinutes).environmentObject(model)
        }
        .sheet(isPresented: $showKeep) {
            KeepAppsSheet().environmentObject(model)
        }
        #if DEBUG
        .onAppear {
            if let m = UIDemo.strictSheetMinutes, (UIDemo.mode == "normal-confirm") == (kind == .normal) {
                demoMinutes = m > 0 ? m : nil
                startKind = kind
            }
            if UIDemo.mode == "keep-apps", kind == .strict { showKeep = true }
        }
        #endif
    }

    /// いまの状態。見出しはこのタブのロックが掛かっているかだけ（ロック中／解除中・§9.11）。もう一方のロックとの重なりは一言で添える
    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusHeadline(title: active ? "ロック中" : "解除中", dot: active ? lockedDot : Theme.field)
            if active, let until {
                Text("残り \(Text(StrictLock.remaining(until)).fontWeight(.semibold).foregroundStyle(Theme.ink))（\(StrictLock.clock(until)) まで）")
                    .font(.subheadline).foregroundStyle(Theme.ink2).monospacedDigit()
                Text(kind == .strict ? "解除はできません" : "使えるアプリ以外を止めています。解除はできません")
                    .noteStyle()
            } else {
                Text(kind == .strict
                     ? "使えるアプリ以外と、すべてのウェブサイトを止めます。始めると、時間が来るまで解除できません。"
                     : "止めたいときに、時間を決めてロックします。始めると、時間が来るまで解除できません。")
                    .font(.subheadline).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let other = overlapNote {
                Text(other)
                    .noteStyle()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// もう一方のロックとの重なり（スーパーが勝つ・スーパーのあとにロックが残れば戻る）
    private var overlapNote: String? {
        switch kind {
        case .normal:
            guard model.strictLockActive, let st = model.strictLockUntil else { return nil }
            return model.normalLockActive
                ? "いまは \(StrictLock.clock(st)) までスーパーロックが優先されています。ここにある使えるアプリも止まります。"
                : "いまは \(StrictLock.clock(st)) までスーパーロック中です。"
        case .strict:
            guard model.normalLockActive, let n = model.normalLockUntil else { return nil }
            if let st = model.strictLockUntil, model.strictLockActive {
                return n > st ? "スーパーロックが終わったあと、\(StrictLock.clock(n)) までロックが続きます。" : nil
            }
            return "いまは \(StrictLock.clock(n)) までロック中です。スーパーロックを始めると、スーパーロックが優先されます。"
        }
    }

    private var keepBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("使えるアプリ").sectionLabelStyle()
            VStack(alignment: .leading, spacing: 0) {
                if model.keepApps.isEmpty {
                    Text("まだ追加していません")
                        .font(.callout).foregroundStyle(Theme.ink2)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(model.keepApps.enumerated()), id: \.element) { i, token in
                        Label(token)
                            .foregroundStyle(Theme.ink)
                            .padding(.vertical, 10)
                        if i < model.keepApps.count - 1 || !model.strictLockActive {
                            Rectangle().fill(Theme.line).frame(height: 0.5)
                        }
                    }
                }
                // スーパーロック中は追加も削除もできない（入口を出さない・§9.8 B）
                if !model.strictLockActive {
                    Button("追加・削除…") { showKeep = true }
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Theme.wood)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .disabled(!approved)
                }
            }
            .padding(.horizontal, 16)
            .paperCard(radius: 14)
            Text(model.strictLockActive
                 ? "スーパーロック中は、追加も削除もできません。"
                 : "スーパーロック中も使えるアプリです。縁側は止まらないので、ロック中も開いて残り時間を見られます。電話・メッセージなど iOS に最初から入っているアプリも止まりません。")
                .font(.caption).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 追加の確かめ中の案内（ホームとシートで共用）。「終える」で一時的な止めを全部外す
private struct VerifyingNote: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("確かめ中のアプリが\(model.keepPending)個あります")
                .font(.system(.callout, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("選んだアプリを1つずつ開いて、出てきた画面の「使えるアプリに追加する」を押すと追加されます。一覧にないアプリは「閉じる」だけが出て、追加できません。")
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

// MARK: - スーパーロックの使えるアプリ（§9.8 B）
// 上から ①使えるアプリ（削除できる）②追加する ③許可一覧と標準アプリの一言（地の文）。
// スーパーロック中はタブに入口を出さないのでここへは来ない（来ても追加・削除を出さず、KeepApps 側でも断る）

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
                SheetHeader(title: "使えるアプリ") { dismiss() }

                // ① 登録済み
                VStack(alignment: .leading, spacing: 8) {
                    Text("使えるアプリ").sectionLabelStyle()
                    VStack(alignment: .leading, spacing: 0) {
                        if model.keepApps.isEmpty {
                            Text("まだ追加していません")
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
                        Text("追加したいアプリを選ぶと、そのアプリを一時的に止めます。開いて出てきた画面のボタンで追加します。")
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
                    Text("追加できるのは次のアプリだけです")
                        .font(.footnote.weight(.medium)).foregroundStyle(Theme.ink2)
                    Text(KeepApps.allowList.map(\.name).joined(separator: "・"))
                        .font(.footnote).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("電話・メッセージなど iOS に最初から入っているアプリは、追加しなくても使えます")
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
        .familyActivityPicker(headerText: "名前を検索欄に打つと、カテゴリを開かずに選べます", isPresented: $showPicker, selection: $candidates)
        .onChange(of: showPicker) { _, shown in
            // ピッカーを閉じたら、選んだ候補で確かめを始める（何も選ばずに閉じたら何もしない）
            guard !shown else { return }
            message = model.startKeepVerify(candidates)
        }
    }
}

// MARK: - 時間の選択 → 確認

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
            Text(kind == .normal ? "ロックは、使えるアプリ以外のアプリを止めます。始めると、時間が来るまで解除できません。"
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
                Text("\(StrictLock.clock(ctx.date.addingTimeInterval(TimeInterval(m * 60)), now: ctx.date)) までロック")
                    .font(Theme.mincho(26, relativeTo: .title))
                    .tracking(1)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Text("始めると、途中で止める方法はありません。使えるアプリは、ロック中も追加・削除できます。")
                    .font(.subheadline).foregroundStyle(Theme.ink2)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    row(title: "止まるもの", text: "使えるアプリと縁側以外のすべてのアプリ。電話・メッセージなど iOS に最初から入っているアプリは止まりません。ウェブサイトは止めません。")
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                    row(title: "使えるアプリ", text: keep.isEmpty ? "追加していません。ロックのタブの「使えるアプリ」で、ロック中も追加できます。" : "\(keep.count)個")
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
                    Text("\(StrictLock.duration(m))ロックする").monospacedDigit()
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
                    row(title: "止まるもの", text: "使えるアプリと縁側以外のすべてのアプリと、すべてのウェブサイト。電話・メッセージなど iOS に最初から入っているアプリは止まりません。")
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                    row(title: "変えられなくなるもの", text: "この iPhone のアプリは、どれも削除できなくなります。日付と時刻も自動設定のままになります。")
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                    row(title: "使えるアプリ", text: keep.isEmpty ? "追加していません。縁側は開けるので、残り時間はいつでも見られます。" : "\(keep.count)個")
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
