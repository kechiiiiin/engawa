import SwiftUI
import FamilyControls

// 設定: 許可アプリの選び直し・1日の枠・リセット時刻・やりたいこと一覧・（奥に）開発者向け。
// 変更はすぐ効く（2026-10-14 本人判断で、アプリ内で緩める抜け道は許容）。

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showPicker = false

    var body: some View {
        Form {
            Section {
                let apps = model.selection.applicationTokens.count
                let cats = model.selection.categoryTokens.count
                let domains = model.selection.webDomainTokens.count

                if apps == 0 && cats == 0 && domains == 0 {
                    Text("まだ選んでいません")
                        .font(.callout).foregroundStyle(Theme.ink2)
                } else {
                    ForEach(Array(model.selection.applicationTokens), id: \.self) { token in
                        Label(token)
                    }
                    ForEach(Array(model.selection.categoryTokens), id: \.self) { token in
                        Label(token)
                    }
                    ForEach(Array(model.selection.webDomainTokens), id: \.self) { token in
                        Label(token)
                    }
                }
                Button(apps + cats + domains == 0 ? "アプリを選ぶ…" : "選び直す…") { showPicker = true }
                    .foregroundStyle(Theme.wood)
                if apps + domains > 50 {
                    Text("50個を超えています。ロックの例外にできるのは合わせて50個までです。")
                        .font(.footnote).foregroundStyle(Theme.danger)
                }
                if !model.selection.categoryTokens.isEmpty {
                    Text("カテゴリで選んだものはロックの例外になりません。アプリを個別に選んでください。")
                        .font(.footnote).foregroundStyle(Theme.caution)
                }
            } header: {
                SettingsHeader(title: "許可アプリ", count: (model.selection.applicationTokens.count
                                                         + model.selection.categoryTokens.count
                                                         + model.selection.webDomainTokens.count))
            } footer: {
                Text("ロック中も使えるアプリです。電話・メッセージ・FaceTime・マップは iOS の仕様で常に止まりません。")
                    .foregroundStyle(Theme.ink3)
            }

            Section {
                Picker("1日の枠", selection: binding(\.quotaMinutes)) {
                    ForEach(AppSettings.quotaChoices, id: \.self) { Text(AppSettings.duration($0)).tag($0) }
                }
                Picker("リセット時刻", selection: binding(\.resetMinutes)) {
                    ForEach(AppSettings.resetChoices, id: \.self) { Text(AppSettings.clock($0)).tag($0) }
                }
            } header: {
                SettingsHeader(title: "一日のきまり")
            } footer: {
                Text("枠を使い切るとロックします。リセット時刻に使用時間が0に戻り、枠のロックが外れます（手動ロックは外れません）。")
                    .foregroundStyle(Theme.ink3)
            }

            Section {
                let usable = model.ideas.filter(\.isUsable)
                ForEach(usable) { idea in
                    Text(idea.title)
                        .font(Theme.mincho(16, relativeTo: .body, bold: false))
                        .tracking(0.5)
                }
                NavigationLink {
                    IdeasEditView()
                } label: {
                    Text(usable.isEmpty ? "追加する" : "追加・編集する")
                        .foregroundStyle(Theme.wood)
                }
            } header: {
                SettingsHeader(title: "やりたいこと")
            } footer: {
                Text("ホームとロック画面に、ここから1つずつ出ます。")
                    .foregroundStyle(Theme.ink3)
            }

            Section {
                NavigationLink {
                    DeveloperView()
                } label: {
                    Text("開発者向け").foregroundStyle(Theme.ink2)
                }
            }
        }
        .settingsStyle()
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.large)
        .familyActivityPicker(isPresented: $showPicker, selection: $model.selection)
        .onChange(of: model.selection) { _, s in model.saveSelection(s) }
    }

    private func binding(_ kp: WritableKeyPath<AppSettings, Int>) -> Binding<Int> {
        Binding(get: { model.settings[keyPath: kp] },
                set: { v in var s = model.settings; s[keyPath: kp] = v; model.saveSettings(s) })
    }
}

/// 設定の節の見出し（ゴシック・字間を空ける）
struct SettingsHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            if let count, count > 0 {
                Text("\(count)件").monospacedDigit()
            }
        }
        .font(.system(.footnote, weight: .semibold))
        .tracking(1.3)
        .foregroundStyle(Theme.ink2)
        .textCase(nil)
    }
}

extension View {
    /// 設定の Form／List を生成りの地と障子紙の行にする
    func settingsStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.paper.ignoresSafeArea())
            .listRowBackground(Theme.card)
            .listRowSeparatorTint(Theme.line)
            .foregroundStyle(Theme.ink)
            .tint(Theme.wood)
            .environment(\.defaultMinListRowHeight, 46)
    }
}

/// やりたいこと一覧の編集（追加・削除・並べ替え）。ロック画面にはここからランダムに1つ出る
struct IdeasEditView: View {
    @EnvironmentObject var model: AppModel
    @State private var ideas: [Idea] = []
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                ForEach($ideas) { $idea in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("タイトル（短く）", text: $idea.title)
                            .font(Theme.mincho(17, relativeTo: .body))
                            .tracking(0.5)
                        TextField("説明", text: $idea.subtitle, axis: .vertical)
                            .font(.footnote)
                            .foregroundStyle(Theme.ink2)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { ideas.remove(atOffsets: $0) }
                .onMove { ideas.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("ロック画面に、ここから1つずつ出ます。タイトルが空のものは出ません。全部消すと「いまはロック中」の固定文になります。")
                    .foregroundStyle(Theme.ink3)
            }
            Section {
                Button {
                    ideas.append(Idea(title: "", subtitle: ""))
                } label: {
                    Label("足す", systemImage: "plus")
                        .foregroundStyle(Theme.wood)
                }
                Button("既定の10件に戻す", role: .destructive) {
                    ideas = Ideas.defaults
                }
                .foregroundStyle(Theme.danger)
            }
        }
        .settingsStyle()
        .navigationTitle("やりたいこと")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { EditButton() }
        .onAppear {
            if !loaded { ideas = Ideas.list; loaded = true }
        }
        .onChange(of: ideas) { _, l in model.saveIdeas(l) }
        .onDisappear { model.logIdeasChange() }
    }
}
