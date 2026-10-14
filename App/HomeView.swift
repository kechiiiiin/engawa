import SwiftUI
import FamilyControls

// 普段使いのホーム（1画面）。上に見るもの、下に触るもの。
//   ロック中かどうか（理由・時間解除の残り）→ 今日の使用時間と残りの枠 → 解除する → 代わりにやりたいこと

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showUnlock = false

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
                }
                if !model.unlockMessage.isEmpty {
                    Text(model.unlockMessage).font(.footnote).foregroundStyle(.secondary)
                }
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
                Text(st.reason.label).foregroundStyle(.secondary)
            } else if let until = model.unlockUntil {
                Label("解除中", systemImage: "lock.open.fill")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.blue)
                Text("残り \(remaining(until))（\(Self.time.string(from: until)) まで）")
                    .font(.headline)
                Text("終わると戻ります: \(st.reason.label)")
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
                    if reason.count > Unlocks.reasonLimit {
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
                    .disabled(trimmed.isEmpty || reason.count > Unlocks.reasonLimit)
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
