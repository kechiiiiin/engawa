import SwiftUI
import FamilyControls
import DeviceActivity

// 設定 → 開発者向け。試作の計測用 UI をそのまま残したもの（経路の切り替え・記録・試験2・数え方）。
// 見た目は作り込まない。

struct DeveloperView: View {
    @EnvironmentObject var model: AppModel
    @State private var showCatsPicker = false

    var body: some View {
        Form {
            Section("状態") {
                LabeledContent("認可", value: authText)
                if model.authStatus == .notDetermined || model.authStatus == .denied {
                    Button("スクリーンタイムを認可する（Face ID）") { model.requestAuth() }
                }
                LabeledContent("ロック", value: model.shielded ? "掛かっている" : "外れている")
                LabeledContent("手動ロック（サーバー）", value: Store.manualLock ? "あり" : "なし")
                LabeledContent("ロックの理由", value: model.status.reason.rawValue)
                LabeledContent("スーパーロック", value: model.status.superLockUntil ?? "なし")
                LabeledContent("時間解除", value: model.status.unlockUntil.map { "\($0)（\(model.status.unlockSource ?? "?")）" } ?? "なし")
                LabeledContent("解除の記録（未送信）", value: "\(Unlocks.pendingCount) 件")
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

            Section("枠（数え方）") {
                Picker("数え方", selection: Binding(get: { model.settings.countMode },
                                                 set: { m in var s = model.settings; s.countMode = m; model.saveSettings(s) })) {
                    ForEach(CountMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledContent("期間の始まり", value: model.usage.periodStart)
                LabeledContent("all（すべて）", value: "\(model.usage.allMin) 分")
                LabeledContent("allowed（許可アプリ）", value: "\(model.usage.allowedMin) 分")
                LabeledContent("ロック中に増えた分（数えない）", value: "\(model.lockedMinutes) 分")
                LabeledContent("枠に数える分", value: "\(model.usedMinutes) 分")
                LabeledContent("quota の発火", value: model.usage.quotaHitFor.map { "枠 \($0) 分で発火" } ?? "まだ")
                LabeledContent("刻み・実際のリセット", value: "\(Quota.registeredStep.map(String.init) ?? "—") 分・\(AppSettings.clock(Quota.effectiveResetMinutes))")
                LabeledContent("登録したイベント数", value: Quota.registeredEventCount.map { "\($0) 件" } ?? "—")
                LabeledContent("使い切りの印", value: model.usage.exhaustedFor.map { "枠 \($0) 分で使い切り" } ?? "まだ")
                Button("枠の監視（daily）を登録し直す") { model.armDaily() }
                if !model.dailyResult.isEmpty { Text(model.dailyResult).font(.footnote) }
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

            Section("やりたいこと一覧（JSON で直接）") {
                TextEditor(text: $model.ideasText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 120)
                Button("この JSON で保存") { model.saveIdeasJSON() }
                Button("既定の10件に戻す", role: .destructive) { model.resetIdeas() }
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
        .navigationTitle("開発者向け")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $showCatsPicker, selection: $model.catsSelection)
        .onChange(of: model.catsSelection) { _, s in model.saveCats(s) }
        .onAppear { model.refresh() }
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
