import SwiftUI
import FamilyControls

// 普段使いのホーム（1画面）。上に見るもの、下に触るもの。
//   ロック中かどうか（理由・時間解除の残り）→ 解除する／アプリを選んで解除 → 個別に解除中
//   → いまからロック（セルフロック）→ 今日の使用時間と残りの枠 → 代わりにやりたいこと

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showUnlock = false
    @State private var showAppUnlock = false
    @State private var showSelfLock = false

    var body: some View {
        List {
            if model.authStatus != .approved {
                Section {
                    Text("スクリーンタイムの許可がまだです。ロックも使用時間の計測も、許可してから動きます。")
                        .font(.callout)
                    Button("スクリーンタイムを許可する（Face ID）") { model.requestAuth() }
                }
            }

            Section {
                statusBlock
                    .padding(.vertical, 8)
                if model.status.locked {
                    Button {
                        showUnlock = true
                    } label: {
                        Label("解除する", systemImage: "lock.open")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .padding(.vertical, 4)
                    Button {
                        showAppUnlock = true
                    } label: {
                        Label("アプリを選んで解除", systemImage: "app.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .padding(.bottom, 4)
                }
                if !model.unlockMessage.isEmpty {
                    Text(model.unlockMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !model.appUnlocks.isEmpty {
                Section {
                    ForEach(model.appUnlocks, id: \.token) { u in
                        HStack {
                            Label(u.token)
                            Spacer()
                            Text("残り \(remaining(u.untilDate))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("個別に解除中")
                } footer: {
                    Text(model.status.locked
                         ? "時間が来ると、またロックされます。"
                         : "いまはロックがかかっていないので、ほかのアプリも使えます。ロックがかかってもこの時間までは使えます。")
                }
            }

            Section {
                Button {
                    showSelfLock = true
                } label: {
                    Label(model.selfLockUntil == nil ? "いまからロック" : "セルフロックを延ばす", systemImage: "lock")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.authStatus != .approved)
            } footer: {
                Text("時間が来なくても、自分でロックをかけます。途中で使うときは、ふだんどおり理由を書いて解除します。")
            }

            Section("今日の使用時間") {
                usageBlock
            }

            Section("代わりにやりたいこと") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.idea.title).font(.title3.weight(.semibold))
                    if !model.idea.subtitle.isEmpty {
                        Text(model.idea.subtitle).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Button("ほかの案") { model.shuffleIdea() }
                    .font(.footnote)
            }

            if model.selection.applicationTokens.isEmpty && model.selection.webDomainTokens.isEmpty {
                Section {
                    Text("許可アプリ（ロック中も使えるアプリ）がまだありません。設定から選べます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("縁側")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
            }
            ToolbarItem(placement: .topBarLeading) {
                if model.syncing { ProgressView() }
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
        .confirmationDialog(selfLockTitle, isPresented: $showSelfLock, titleVisibility: .visible) {
            ForEach(SelfLock.Choice.allCases) { c in
                Button("\(c.label)（\(LockReason.clock.string(from: c.until()))まで）") { model.startSelfLock(c) }
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text(selfLockMessage)
        }
    }

    // MARK: -

    @ViewBuilder
    private var statusBlock: some View {
        let st = model.status
        VStack(alignment: .leading, spacing: 6) {
            if st.locked {
                Label("ロック中", systemImage: "lock.fill")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.orange)
                Text(st.reason.label(selfUntil: model.selfLockUntil)).foregroundStyle(.secondary)
                if !model.appUnlocks.isEmpty {
                    Text("\(model.appUnlocks.count)個のアプリを個別に解除中")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if let until = model.unlockUntil {
                Label("解除中", systemImage: "lock.open.fill")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.blue)
                Text("残り \(remaining(until))（\(Self.time.string(from: until)) まで）")
                    .font(.headline)
                Text("終わると戻ります: \(st.reason.label(selfUntil: model.selfLockUntil))")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("使えます", systemImage: "sun.max")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var usageBlock: some View {
        let quota = model.settings.quotaMinutes
        let used = model.usedMinutes
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("約 \(AppSettings.duration(used))").font(.title2.weight(.semibold))
                Text("／ 枠 \(AppSettings.duration(quota))").foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(used, quota)), total: Double(max(quota, 1)))
                .tint(model.quotaExhausted ? .orange : .accentColor)
            if model.quotaExhausted {
                Text("今日の枠を使い切りました").font(.callout).foregroundStyle(.orange)
            } else {
                Text("残り 約 \(AppSettings.duration(max(0, quota - used)))").font(.callout)
            }
            Text("毎日 \(AppSettings.clock(Quota.effectiveResetMinutes)) に0に戻ります（数え方: \(model.settings.countMode.label)・\(Quota.registeredStep ?? 5)分刻みの目安）")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

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

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f
    }()
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
        NavigationStack {
            Form {
                Section {
                    Text(model.status.reason.label).foregroundStyle(.secondary)
                } header: {
                    Text("いまのロック")
                }
                Section {
                    TextField("例: 地図で道を調べる", text: $reason, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focused)
                    if Unlocks.reasonLength(reason) > Unlocks.reasonLimit {
                        Text("\(Unlocks.reasonLimit)字までにしてください").font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("理由（必須）")
                } footer: {
                    Text("理由は記録に残り、止めるアプリや枠の見直しに使います。")
                }
                Section("時間") {
                    Picker("時間", selection: $minutes) {
                        ForEach(Unlocks.minuteChoices, id: \.self) { Text("\($0)分").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Button {
                        model.unlock(minutes: minutes, reason: reason)
                        dismiss()
                    } label: {
                        Text("\(minutes)分 解除する").frame(maxWidth: .infinity)
                    }
                    .disabled(trimmed.isEmpty || Unlocks.reasonLength(reason) > Unlocks.reasonLimit)
                }
            }
            .navigationTitle("解除する")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
            }
            .onAppear { focused = true }
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
        NavigationStack {
            Form {
                Section {
                    Button(pick.applicationTokens.isEmpty ? "アプリを選ぶ" : "選び直す") { showPicker = true }
                    ForEach(Array(check.targets), id: \.self) { token in
                        Label(token)
                    }
                    ForEach(check.notes, id: \.self) { n in
                        Text(n).font(.footnote).foregroundStyle(.orange)
                    }
                    if let e = check.error, !(pick.applicationTokens.isEmpty && pick.categoryTokens.isEmpty && pick.webDomainTokens.isEmpty) {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("解除するアプリ（\(check.targets.count)個）")
                } footer: {
                    Text("ロックされているアプリを1つ以上、アプリごとに選びます。カテゴリで選ぶと個別の解除になりません。")
                }
                Section {
                    TextField("例: 地図で道を調べる", text: $reason, axis: .vertical)
                        .lineLimit(2...5)
                    if Unlocks.reasonLength(reason) > Unlocks.reasonLimit {
                        Text("\(Unlocks.reasonLimit)字までにしてください").font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("理由（必須）")
                } footer: {
                    Text("理由は記録に残ります。アプリ名は記録に送らず、数だけ送ります。")
                }
                Section("時間") {
                    Picker("時間", selection: $minutes) {
                        ForEach(Unlocks.minuteChoices, id: \.self) { Text("\($0)分").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Button {
                        if let e = model.unlockApps(pick, minutes: minutes, reason: reason) {
                            error = e
                        } else {
                            dismiss()
                        }
                    } label: {
                        Text("\(check.targets.count)個のアプリを\(minutes)分 解除する").frame(maxWidth: .infinity)
                    }
                    .disabled(!check.ok || trimmed.isEmpty || Unlocks.reasonLength(reason) > Unlocks.reasonLimit)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("アプリを選んで解除")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
            }
            .familyActivityPicker(isPresented: $showPicker, selection: $pick)
            .onChange(of: pick) { _, _ in error = nil }
        }
    }
}
