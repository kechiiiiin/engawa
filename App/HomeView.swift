import SwiftUI
import FamilyControls

// 普段使いのホーム（1画面）。上に縁側からの景色、その下に見るもの、いちばん下に触るもの。
//   ロック中かどうか（理由・時間解除の残り）→ 今日の使用時間と残りの枠 → 個別に解除中 → 代わりにやりたいこと
//   下のボタン: ロック中は アプリを選んで解除／解除する／いまからロック、使えるときは いまからロック
// 見た目は design/mock/index.html が正（色・書体・部品は Theme.swift）

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showUnlock = false
    @State private var showAppUnlock = false
    @State private var showSelfLock = false

    /// 景色に夕暮れを掛けるか（状態が変わると 0.8秒で移る）
    private var dusk: Bool { model.status.locked }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SceneryHero(locked: dusk)
                content
                    .padding(.horizontal, Theme.sideMargin)
                    .padding(.top, -62)   // 景色の溶けたところ（上から 330pt）に重ねる
                    .padding(.bottom, 24)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .ignoresSafeArea(edges: .top)
        .background(Theme.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .navigationTitle("ホーム")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black.opacity(0.01), for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)   // 景色の上なのでステータスバーの文字を明るく
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }   // 「ホーム」は戻るボタン用で、ここには出さない
            ToolbarItem(placement: .topBarLeading) {
                if model.syncing { ProgressView().tint(Theme.onWood) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.ink)
                }
                .accessibilityLabel("設定")
            }
        }
        .refreshable { model.syncOnForeground() }
        .sheet(isPresented: $showUnlock) {
            UnlockView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showAppUnlock) {
            AppUnlockView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showSelfLock) {
            SelfLockSheet(title: selfLockTitle, message: selfLockMessage) { c in
                model.startSelfLock(c)
            }
        }
        #if DEBUG
        .onAppear {
            switch UIDemo.mode {
            case "sheet": showUnlock = true
            case "apps": showAppUnlock = true
            case "selflock": showSelfLock = true
            default: break
            }
        }
        #endif
    }

    // MARK: - 中身

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusBlock

            if model.authStatus != .approved {
                VStack(alignment: .leading, spacing: 12) {
                    Text("スクリーンタイムの許可がまだです。ロックも使用時間の計測も、許可してから動きます。")
                        .font(.callout).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("スクリーンタイムを許可する（Face ID）") { model.requestAuth() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(18)
                .paperCard()
            }

            usageBlock

            if !model.appUnlocks.isEmpty {
                appUnlocksBlock
            }

            ideaCard

            if model.selection.applicationTokens.isEmpty && model.selection.webDomainTokens.isEmpty {
                Text("許可アプリ（ロック中も使えるアプリ）がまだありません。設定から選べます。")
                    .noteStyle()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        let st = model.status
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.day.string(from: Date()))
                .font(.system(.footnote, weight: .medium))
                .tracking(1)
                .foregroundStyle(Theme.ink2)

            if st.locked {
                headline("ロック中", dot: Theme.dusk)
                Text(lockedSubtitle)
                    .font(.subheadline).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.appUnlocks.isEmpty {
                    Text("\(model.appUnlocks.count)個のアプリを個別に解除中")
                        .noteStyle()
                }
            } else if let until = model.unlockUntil {
                headline("解除中", dot: Theme.gold)
                Text("残り \(Text(remaining(until)).fontWeight(.semibold).foregroundStyle(Theme.ink))（\(Self.time.string(from: until)) まで）")
                    .font(.subheadline).foregroundStyle(Theme.ink2).monospacedDigit()
                Text("終わると戻ります: \(st.reason.label(selfUntil: model.selfLockUntil))")
                    .noteStyle()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                headline("使えます", dot: Theme.field)
                if model.quotaExhausted {
                    Text("今日の枠を使い切りました")
                        .font(.subheadline).foregroundStyle(Theme.dusk)
                } else {
                    Text("今日はあと \(Text("約\(AppSettings.duration(max(0, model.settings.quotaMinutes - model.usedMinutes)))").fontWeight(.semibold).foregroundStyle(Theme.ink))")
                        .font(.subheadline).foregroundStyle(Theme.ink2).monospacedDigit()
                }
            }

            if !model.unlockMessage.isEmpty {
                Text(model.unlockMessage)
                    .noteStyle()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func headline(_ title: String, dot: Color) -> some View {
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

    /// ロックの理由。枠だけのときは、いつ戻るかも添える
    private var lockedSubtitle: String {
        let st = model.status
        var s = st.reason.label(selfUntil: model.selfLockUntil)
        if st.reason == .quota {
            s = "今日の枠を使い切りました。"
            let next = Quota.nextReset()
            let day = Calendar.current.isDateInToday(next) ? "" : "明日 "
            s += "\n\(day)\(AppSettings.clock(Quota.effectiveResetMinutes)) にもどります。"
        }
        return s
    }

    @ViewBuilder
    private var usageBlock: some View {
        let quota = model.settings.quotaMinutes
        let used = model.usedMinutes
        let exhausted = model.quotaExhausted
        let ratio = min(1, Double(used) / Double(max(quota, 1)))
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("使った \(Text("約\(AppSettings.duration(used))").font(.system(.subheadline, weight: .semibold)).foregroundStyle(Theme.ink))")
                Spacer(minLength: 8)
                Text("枠 \(AppSettings.duration(quota))")
            }
            .font(.footnote)
            .foregroundStyle(Theme.ink2)
            .monospacedDigit()

            Capsule()
                .fill(Theme.paper2)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule()
                            .fill(LinearGradient(colors: exhausted ? [Color(hex: 0x9A6A47), Theme.dusk] : [Color(hex: 0xC48A3A), Theme.gold],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(ratio > 0 ? 6 : 0, g.size.width * ratio))
                    }
                }
                .clipShape(Capsule())
                .accessibilityElement()
                .accessibilityLabel("今日の使用時間")
                .accessibilityValue("\(AppSettings.duration(used)) ／ \(AppSettings.duration(quota))")

            Text("毎日 \(AppSettings.clock(Quota.effectiveResetMinutes)) に0に戻ります（数え方: \(model.settings.countMode.label)・\(Quota.registeredStep ?? 5)分刻みの目安）")
                .font(.caption).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appUnlocksBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("個別に解除中").sectionLabelStyle()
            VStack(spacing: 0) {
                ForEach(Array(model.appUnlocks.enumerated()), id: \.element.token) { i, u in
                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 0.5) }
                    HStack {
                        Label(u.token)
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        Text("残り \(remaining(u.untilDate))")
                            .font(.callout).foregroundStyle(Theme.ink2).monospacedDigit()
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
            .paperCard(radius: 14)
            Text(model.status.locked
                 ? "時間が来ると、またロックされます。"
                 : "いまはロックがかかっていないので、ほかのアプリも使えます。ロックがかかってもこの時間までは使えます。")
                .font(.caption).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ideaCard: some View {
        let lead = model.status.locked
        return VStack(alignment: .leading, spacing: 0) {
            Text("代わりにやりたいこと").sectionLabelStyle()
            Text(model.idea.title)
                .font(Theme.mincho(lead ? 28 : 22, relativeTo: lead ? .title : .title2))
                .tracking(1)
                .foregroundStyle(Theme.ink)
                .padding(.top, lead ? 8 : 6)
                .fixedSize(horizontal: false, vertical: true)
            if !model.idea.subtitle.isEmpty {
                Text(model.idea.subtitle)
                    .font(.footnote).foregroundStyle(Theme.ink2)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button {
                    model.shuffleIdea()
                } label: {
                    Label("ほかの案", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Theme.wood)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, lead ? 20 : 18)
        .padding(.top, lead ? 20 : 16)
        .padding(.bottom, lead ? 12 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: - 下のボタン

    private var actions: some View {
        VStack(spacing: 10) {
            if model.status.locked {
                Button("アプリを選んで解除") { showAppUnlock = true }
                    .buttonStyle(SecondaryButtonStyle())
                Button("解除する") { showUnlock = true }
                    .buttonStyle(PrimaryButtonStyle())
                Button(model.selfLockUntil == nil ? "いまからロック" : "セルフロックを延ばす") { showSelfLock = true }
                    .buttonStyle(PlainWoodButtonStyle())
                    .disabled(model.authStatus != .approved)
            } else {
                Button(model.selfLockUntil == nil ? "いまからロック" : "セルフロックを延ばす") { showSelfLock = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.authStatus != .approved)
            }
        }
        .padding(.horizontal, Theme.sideMargin)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(
            Theme.paper
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Theme.paper.opacity(0), Theme.paper], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                        .offset(y: -16)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: -

    private var selfLockTitle: String {
        model.selfLockUntil.map { "セルフロック中（\(Self.time.string(from: $0))まで）。延ばしますか" } ?? "いまからロックしますか"
    }

    private var selfLockMessage: String {
        var lines = ["選んだ時間が来ると自動で終わります。"]
        if model.selfLockUntil != nil {
            lines.append("今の終わりより短くはなりません（短い時間を選んだときは何も変えません）。")
        }
        if model.unlockUntil != nil || !model.appUnlocks.isEmpty {
            lines.append(model.selfLockUntil == nil
                         ? "解除中の時間・個別の解除は終わりにします。"
                         : "延びるときは、解除中の時間・個別の解除を終わりにします。")
        }
        return lines.joined(separator: "\n")
    }

    private func remaining(_ until: Date) -> String {
        let sec = max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
        let m = (sec + 59) / 60
        return m >= 1 ? "\(m)分" : "1分未満"
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f
    }()
}

/// いまからロック: 時間を選ぶ（中身は以前の確認ダイアログと同じ。選んだら startSelfLock）
struct SelfLockSheet: View {
    let title: String
    let message: String
    var start: (SelfLock.Choice) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "いまからロック") { dismiss() }
                Text(title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                Text("時間が来なくても、自分でロックをかけます。途中で使うときは、ふだんどおり理由を書いて解除します。\n" + message)
                    .font(.subheadline).foregroundStyle(Theme.ink2)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    ForEach(SelfLock.Choice.allCases) { c in
                        Button("\(c.label)（\(LockReason.clock.string(from: c.until()))まで）") {
                            start(c)
                            dismiss()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button("やめる") { dismiss() }
                        .buttonStyle(PlainWoodButtonStyle())
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, Theme.sideMargin)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.paper)
        .presentationCornerRadius(28)
    }
}

/// 解除: 理由を一言（必須）＋時間を選ぶ。
/// ⚠️ IME の確定の Enter で送らない: 送信は「解除する」ボタンだけ（onSubmit を付けない・複数行の欄で Return は改行）
struct UnlockView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var minutes = 15
    @FocusState private var focused: Bool

    private var trimmed: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "解除する") { dismiss() }
                Text("少しだけ開けますね。なにをしたいか、ひとこと残してください。")
                    .font(.subheadline).foregroundStyle(Theme.ink2)
                    .lineSpacing(3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                Text("いまのロック: \(model.status.reason.label)")
                    .font(.caption).foregroundStyle(Theme.ink3)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)

                FieldLabel(title: "理由", trailing: "必須")
                    .padding(.top, 22)
                ReasonField(text: $reason, placeholder: "例: 地図で道を調べる")
                    .focused($focused)
                    .padding(.top, 8)
                if Unlocks.reasonLength(reason) > Unlocks.reasonLimit {
                    Text("\(Unlocks.reasonLimit)字までにしてください").font(.footnote).foregroundStyle(Theme.danger)
                        .padding(.top, 6)
                }
                Text("理由は記録に残り、止めるアプリや枠の見直しに使います。")
                    .font(.caption).foregroundStyle(Theme.ink3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                FieldLabel(title: "時間")
                    .padding(.top, 22)
                MinuteSegment(choices: Unlocks.minuteChoices, selection: $minutes)
                    .padding(.top, 8)
            }
            .padding(.horizontal, Theme.sideMargin)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                model.unlock(minutes: minutes, reason: reason)
                dismiss()
            } label: {
                Text("\(minutes)分 解除する").monospacedDigit()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(trimmed.isEmpty || Unlocks.reasonLength(reason) > Unlocks.reasonLimit)
            .padding(.horizontal, Theme.sideMargin)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Theme.paper)
        }
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.paper)
        .presentationCornerRadius(28)
        .onAppear { focused = true }
    }
}

/// 欄の小見出し（左に名前・右に「必須」など）
struct FieldLabel: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).sectionLabelStyle()
            Spacer()
            if let trailing {
                Text(trailing).font(.system(.caption, weight: .medium)).foregroundStyle(Theme.ink3)
            }
        }
    }
}

/// アプリ個別の解除: アプリを選ぶ（ロックされているものを1つ以上）→ 理由（必須）→ 時間。
/// ⚠️ IME の確定の Enter で送らない: 送信は「解除する」ボタンだけ（onSubmit を付けない・複数行の欄で Return は改行）
struct AppUnlockView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pick = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var reason = ""
    @State private var minutes = 15
    @State private var error: String?

    private var trimmed: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var check: AppUnlocks.Check { AppUnlocks.check(pick) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "アプリを選んで解除") { dismiss() }

                FieldLabel(title: "解除するアプリ（\(check.targets.count)個）")
                    .padding(.top, 18)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(check.targets), id: \.self) { token in
                        Label(token)
                            .foregroundStyle(Theme.ink)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Rectangle().fill(Theme.line).frame(height: 0.5)
                    }
                    Button(pick.applicationTokens.isEmpty ? "アプリを選ぶ…" : "選び直す…") { showPicker = true }
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Theme.wood)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .paperCard(radius: 14)
                .padding(.top, 8)
                ForEach(check.notes, id: \.self) { n in
                    Text(n).font(.footnote).foregroundStyle(Theme.caution)
                        .padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let e = check.error, !(pick.applicationTokens.isEmpty && pick.categoryTokens.isEmpty && pick.webDomainTokens.isEmpty) {
                    Text(e).font(.footnote).foregroundStyle(Theme.danger)
                        .padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("ロックされているアプリを1つ以上、アプリごとに選びます。カテゴリで選ぶと個別の解除になりません。")
                    .font(.caption).foregroundStyle(Theme.ink3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                FieldLabel(title: "理由", trailing: "必須")
                    .padding(.top, 22)
                ReasonField(text: $reason, placeholder: "例: 地図で道を調べる")
                    .padding(.top, 8)
                if Unlocks.reasonLength(reason) > Unlocks.reasonLimit {
                    Text("\(Unlocks.reasonLimit)字までにしてください").font(.footnote).foregroundStyle(Theme.danger)
                        .padding(.top, 6)
                }
                Text("理由は記録に残ります。アプリ名は記録に送らず、数だけ送ります。")
                    .font(.caption).foregroundStyle(Theme.ink3)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                FieldLabel(title: "時間")
                    .padding(.top, 22)
                MinuteSegment(choices: Unlocks.minuteChoices, selection: $minutes)
                    .padding(.top, 8)
            }
            .padding(.horizontal, Theme.sideMargin)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                Button {
                    if let e = model.unlockApps(pick, minutes: minutes, reason: reason) {
                        error = e
                    } else {
                        dismiss()
                    }
                } label: {
                    Text("\(check.targets.count)個のアプリを\(minutes)分 解除する").monospacedDigit()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!check.ok || trimmed.isEmpty || Unlocks.reasonLength(reason) > Unlocks.reasonLimit)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.sideMargin)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Theme.paper)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.paper)
        .presentationCornerRadius(28)
        .familyActivityPicker(isPresented: $showPicker, selection: $pick)
        .onChange(of: pick) { _, _ in error = nil }
    }
}
