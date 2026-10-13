import SwiftUI
import FamilyControls
import DeviceActivity

// 見た目は作り込まない。試験に要るボタンと表示だけ。

final class AppModel: ObservableObject {
    @Published var authStatus: AuthorizationStatus = AuthorizationCenter.shared.authorizationStatus
    @Published var selection: FamilyActivitySelection = Shield.loadSelection()
    @Published var catsSelection: FamilyActivitySelection = Shield.loadCatsSelection()
    @Published var routes: Routes = Store.routes
    @Published var usageN: Int = Store.usageN
    @Published var serverText: String = Store.serverURL?.absoluteString ?? ""
    @Published var lastResult: String = ""
    @Published var test2Result: String = ""
    @Published var usageResult: String = ""
    @Published var logs: [LogRecord] = []
    @Published var shielded = Shield.isShielded
    @Published var activities: [String] = []
    @Published var ideasText: String = ""

    var hasToken: Bool { Store.token != nil }

    func refresh() {
        authStatus = AuthorizationCenter.shared.authorizationStatus
        shielded = Shield.isShielded
        routes = Store.routes
        logs = Log.recent(300)
        activities = DeviceActivityCenter().activities.map(\.rawValue).sorted()
        if let d = Store.data("ideas.json"), let s = String(data: d, encoding: .utf8) { ideasText = s }
        else if ideasText.isEmpty,
                let u = Bundle.main.url(forResource: "ideas-override-sample", withExtension: "json"),
                let s = try? String(contentsOf: u, encoding: .utf8) { ideasText = s }
    }

    func requestAuth() {
        Task { @MainActor in
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                Log.add(kind: "auth", ok: true)
            } catch {
                Log.add(kind: "auth", ok: false, error: String(describing: error))
            }
            self.refresh()
        }
    }

    /// 経路 R1: 前面に来るたび
    func syncOnForeground() {
        Log.add(kind: "foreground", route: "R1")   // 試験1-3: 開いてから反映までを測る起点
        DispatchQueue.global().async {
            Wake.reconcile(Store.routes)   // 途切れた目覚ましを継ぎ直す
            let r = Shield.sync(route: "R1")
            let sent = Log.flush()
            DispatchQueue.main.async {
                self.lastResult = (r?.message ?? "取得失敗（記録を見てください）") + " / 記録: \(sent)"
                self.refresh()
            }
        }
    }

    func saveSelection(_ s: FamilyActivitySelection) {
        Shield.saveSelection(s)
        Log.add(kind: "selection", detail: "apps=\(s.applicationTokens.count) domains=\(s.webDomainTokens.count) cats=\(s.categoryTokens.count)")
        // ロック中なら許可アプリを入れ直して掛け直す
        if Shield.isShielded { Shield.lockNow() }
        refresh()
    }

    func saveCats(_ s: FamilyActivitySelection) {
        Shield.saveCatsSelection(s)
        Log.add(kind: "catsSelection", detail: "cats=\(s.categoryTokens.count)")
    }

    func setRoutes(_ r: Routes) {
        Store.routes = r
        Log.add(kind: "routes", detail: "画面: \(r.summary)")
        Wake.reconcile(r)
        refresh()
    }

    func armUsage() {
        Store.usageN = usageN
        let (n, errs) = Wake.armUsage(n: usageN)
        usageResult = "登録できた N=\(n)（これまでの最大 \(Store.usageMaxRegistered)）" + (errs.isEmpty ? "" : "\n" + errs.joined(separator: "\n"))
        refresh()
    }

    func armTest2() {
        let r = Wake.armTest2()
        test2Result = r.isEmpty ? "登録した" : r.joined(separator: "\n")
        refresh()
    }

    func saveServer() {
        if let u = URL(string: serverText.trimmingCharacters(in: .whitespaces)), u.scheme?.hasPrefix("http") == true {
            Store.serverURL = u
            lastResult = "サーバー URL を保存"
        } else {
            lastResult = "URL が不正"
        }
    }

    func saveIdeas() {
        let d = Data(ideasText.utf8)
        struct I: Decodable { var title: String; var subtitle: String }
        guard let list = try? JSONDecoder().decode([I].self, from: d), !list.isEmpty else {
            lastResult = "上書き一覧の JSON が読めない"
            return
        }
        Store.setData("ideas.json", d)
        Log.add(kind: "ideas", detail: "上書き \(list.count) 件")
        lastResult = "上書き一覧を保存（\(list.count) 件）"
    }

    func clearIdeas() {
        Store.setData("ideas.json", nil)
        Log.add(kind: "ideas", detail: "上書きを消した")
        ideasText = ""
        refresh()
    }

    func sendLogs() {
        DispatchQueue.global().async {
            let s = Log.flush()
            DispatchQueue.main.async { self.lastResult = "記録: \(s)" }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPicker = false
    @State private var showCatsPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("状態") {
                    LabeledContent("認可", value: authText)
                    if model.authStatus == .notDetermined || model.authStatus == .denied {
                        Button("スクリーンタイムを認可する（Face ID）") { model.requestAuth() }
                    }
                    LabeledContent("ロック", value: model.shielded ? "掛かっている" : "外れている")
                    LabeledContent("反映済みの版", value: "\(Store.appliedVersion)")
                    LabeledContent("最後の同期", value: Store.lastSync ?? "まだ")
                    LabeledContent("トークン", value: model.hasToken ? "あり" : "なし（make import-token）")
                    LabeledContent("監視中", value: model.activities.joined(separator: ", "))
                    if !model.lastResult.isEmpty { Text(model.lastResult).font(.footnote) }
                    Button("今すぐ同期（R1）") { model.syncOnForeground() }
                }

                Section("サーバー") {
                    TextField("https://…", text: $model.serverText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("URL を保存") { model.saveServer() }
                }

                Section("許可アプリ") {
                    let apps = model.selection.applicationTokens.count
                    let domains = model.selection.webDomainTokens.count
                    LabeledContent("選択", value: "アプリ \(apps)／ドメイン \(domains)／カテゴリ \(model.selection.categoryTokens.count)")
                    if apps + domains > 50 {
                        Text("⚠️ 50個を超えています。all(except:) の例外は合わせて50個まで").foregroundStyle(.red)
                    }
                    if !model.selection.categoryTokens.isEmpty {
                        Text("カテゴリで選んだものはロックの例外にできません（アプリを個別に選ぶ）").font(.footnote).foregroundStyle(.orange)
                    }
                    Button("許可アプリを選ぶ") { showPicker = true }
                }

                Section("経路（R1 は常にオン）") {
                    Toggle("R2 サイレントプッシュ", isOn: routeBinding(\.silentPush))
                    Toggle("R3 alert プッシュ＋NSE", isOn: routeBinding(\.alertPush))
                    Toggle("R4 予定の目覚まし（15分×2本）", isOn: routeBinding(\.poll))
                    Toggle("R5 使用量の目覚まし", isOn: routeBinding(\.usageWake))
                    Picker("R5 の段数 N", selection: $model.usageN) {
                        Text("60").tag(60); Text("120").tag(120); Text("240").tag(240)
                    }
                    Button("R5 を N 段で登録し直す") { model.armUsage() }
                    if !model.usageResult.isEmpty { Text(model.usageResult).font(.footnote) }
                    Button("R4 を登録し直す") { _ = Wake.armBothPolls(); model.refresh() }
                }

                Section("試験2（数え方）") {
                    LabeledContent("すべてのカテゴリ", value: "\(model.catsSelection.categoryTokens.count) 個")
                    Button("「すべてのカテゴリ」を選ぶ（E-cats 用）") { showCatsPicker = true }
                    Button("試験2 の監視を登録") { model.armTest2() }
                    Toggle("E-all 到達でロックする", isOn: routeBinding(\.thresholdLock))
                    if !model.test2Result.isEmpty { Text(model.test2Result).font(.footnote) }
                }

                Section("ロック画面の文言（上書き）") {
                    TextEditor(text: $model.ideasText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                    Button("上書きを読み込む（保存）") { model.saveIdeas() }
                    Button("上書きを消す（バンドル内に戻す）", role: .destructive) { model.clearIdeas() }
                }

                Section("記録（新しい順・\(model.logs.count) 件）") {
                    Button("記録をサーバーへ送る") { model.sendLogs() }
                    Button("表示を更新") { model.refresh() }
                    ForEach(model.logs) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.ts.suffix(18)) \(r.proc) \(r.kind) \(r.route ?? "")")
                                .font(.caption.monospaced())
                            if let line = detailLine(r) {
                                Text(line).font(.caption2).foregroundStyle(r.ok == false ? .red : .secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("制限試作")
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $model.selection)
        .familyActivityPicker(isPresented: $showCatsPicker, selection: $model.catsSelection)
        .onChange(of: model.selection) { _, s in model.saveSelection(s) }
        .onChange(of: model.catsSelection) { _, s in model.saveCats(s) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.syncOnForeground() }
        }
        .onAppear {
            model.refresh()
            if model.authStatus == .notDetermined { model.requestAuth() }  // 受け入れ条件9
        }
    }

    private var authText: String {
        switch model.authStatus {
        case .approved: return "承認済み"
        case .denied: return "拒否"
        case .notDetermined: return "未決定"
        default: return String(describing: model.authStatus)   // iOS 27 の .approvedWithDataAccess など
        }
    }

    private func routeBinding(_ kp: WritableKeyPath<Routes, Bool>) -> Binding<Bool> {
        Binding(get: { model.routes[keyPath: kp] },
                set: { v in var r = model.routes; r[keyPath: kp] = v; model.routes = r; model.setRoutes(r) })
    }

    private func detailLine(_ r: LogRecord) -> String? {
        var parts: [String] = []
        if let v = r.version { parts.append("v\(v)") }
        if let l = r.locked { parts.append(l ? "locked" : "unlocked") }
        if let ok = r.ok { parts.append(ok ? "ok" : "NG") }
        if let e = r.error { parts.append(e) }
        if let d = r.detail { parts.append(d) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
