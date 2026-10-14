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
                let domains = model.selection.webDomainTokens.count
                LabeledContent("選んでいるもの", value: "アプリ \(apps)・サイト \(domains)")
                Button("許可アプリを選び直す") { showPicker = true }
                if apps + domains > 50 {
                    Text("50個を超えています。ロックの例外にできるのは合わせて50個までです。")
                        .font(.footnote).foregroundStyle(.red)
                }
                if !model.selection.categoryTokens.isEmpty {
                    Text("カテゴリで選んだものはロックの例外になりません。アプリを個別に選んでください。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("許可アプリ")
            } footer: {
                Text("ロック中も使えるアプリです。")
            }

            Section {
                Picker("1日の枠", selection: binding(\.quotaMinutes)) {
                    ForEach(AppSettings.quotaChoices, id: \.self) { Text(AppSettings.duration($0)).tag($0) }
                }
                Picker("リセット時刻", selection: binding(\.resetMinutes)) {
                    ForEach(AppSettings.resetChoices, id: \.self) { Text(AppSettings.clock($0)).tag($0) }
                }
            } header: {
                Text("枠")
            } footer: {
                Text("枠を使い切るとロックします。リセット時刻に使用時間が0に戻り、枠のロックが外れます（手動ロックは外れません）。")
            }

            Section("代わりにやりたいこと") {
                NavigationLink {
                    IdeasEditView()
                } label: {
                    LabeledContent("一覧", value: "\(model.ideas.filter(\.isUsable).count) 件")
                }
            }

            Section {
                NavigationLink("開発者向け") { DeveloperView() }
            }
        }
        .navigationTitle("設定")
        .familyActivityPicker(isPresented: $showPicker, selection: $model.selection)
        .onChange(of: model.selection) { _, s in model.saveSelection(s) }
    }

    private func binding(_ kp: WritableKeyPath<AppSettings, Int>) -> Binding<Int> {
        Binding(get: { model.settings[keyPath: kp] },
                set: { v in var s = model.settings; s[keyPath: kp] = v; model.saveSettings(s) })
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
                            .font(.body.weight(.semibold))
                        TextField("説明", text: $idea.subtitle, axis: .vertical)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { ideas.remove(atOffsets: $0) }
                .onMove { ideas.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("ロック画面に、ここから1つずつ出ます。タイトルが空のものは出ません。全部消すと「いまはロック中」の固定文になります。")
            }
            Section {
                Button {
                    ideas.append(Idea(title: "", subtitle: ""))
                } label: {
                    Label("足す", systemImage: "plus")
                }
                Button("既定の10件に戻す", role: .destructive) {
                    ideas = Ideas.defaults
                }
            }
        }
        .navigationTitle("やりたいこと")
        .toolbar { EditButton() }
        .onAppear {
            if !loaded { ideas = Ideas.list; loaded = true }
        }
        .onChange(of: ideas) { _, l in model.saveIdeas(l) }
        .onDisappear { model.logIdeasChange() }
    }
}
