import SwiftUI
import UIKit

// スーパーロックの途中解除で使う「書き写し」（本番設計 §10.1・受け入れ条件4・5）。
//
//   - 入力欄は UITextView を包む（SwiftUI の TextField では切れない設定があるため）:
//     予測変換・自動修正・スペルチェック・スマート句読点・インライン予測・作文ツールを切り、貼り付け・ドロップを拒む。
//     ⚠️ 日本語のかな漢字変換の候補は IME そのものなので切れない（変換しないと漢字が打てない）。
//        英字キーボードの予測（QuickType）は autocorrectionType = .no で出ない
//   - ⚠️ IME の変換中（markedTextRange != nil）は判定しない・Enter を確定や送信に使わない。
//     変換中は SwiftUI 側の text を更新せず、確定してから渡す。改行は入れない（送信は画面のボタンだけ）
//   - 一致は完全一致（前後の空白だけ除く。SuperLock.matches）

/// 書き写す欄（貼り付け不可・予測変換なし）。text は IME の変換が確定したときだけ更新する
struct CopyTextField: UIViewRepresentable {
    @Binding var text: String
    /// IME の変換中か（変換中は一致を判定しない）
    @Binding var composing: Bool
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> NoPasteTextView {
        let v = NoPasteTextView()
        v.delegate = context.coordinator
        v.pasteDelegate = context.coordinator
        v.textDropDelegate = context.coordinator
        v.text = text

        // 予測変換・自動修正・スペルチェックなどを切る
        v.autocorrectionType = .no
        v.spellCheckingType = .no
        v.autocapitalizationType = .none
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.smartInsertDeleteType = .no
        v.inlinePredictionType = .no
        v.mathExpressionCompletionType = .no
        v.writingToolsBehavior = .none
        v.textContentType = nil
        v.keyboardType = .default
        v.allowsEditingTextAttributes = false
        v.dataDetectorTypes = []
        v.isFindInteractionEnabled = false
        // キーボードの上の段（iPad のショートカットの貼り付けボタンなど）を出さない
        v.inputAssistantItem.leadingBarButtonGroups = []
        v.inputAssistantItem.trailingBarButtonGroups = []

        // 見た目（ReasonField と同じ: 障子紙の上に本文の大きさ）
        v.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17))
        v.adjustsFontForContentSizeCategory = true
        v.textColor = UIColor(Theme.ink)
        v.tintColor = UIColor(Theme.wood)
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        v.textContainer.lineFragmentPadding = 4
        v.returnKeyType = .default
        v.accessibilityLabel = placeholder
        return v
    }

    func updateUIView(_ v: NoPasteTextView, context: Context) {
        context.coordinator.parent = self
        // 変換中は書き戻さない（変換が消えてしまう）
        if v.markedTextRange == nil, v.text != text { v.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate, UITextDropDelegate {
        var parent: CopyTextField
        init(_ parent: CopyTextField) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // 変換中は IME に任せる（確定の Enter はここに改行として来ない）。確定後の改行は入れない（送信にも使わない）
            if textView.markedTextRange == nil, text.contains(where: \.isNewline) { return false }
            return true
        }

        func textViewDidChange(_ textView: UITextView) { publish(textView) }

        // 変換の確定は didChange が来ないことがあるので、選択の変化でも拾う
        func textViewDidChangeSelection(_ textView: UITextView) {
            // updateUIView で text を書き戻したときにも呼ばれるので、画面の更新の外で渡す
            DispatchQueue.main.async { [weak textView] in if let textView { self.publish(textView) } }
        }

        private func publish(_ v: UITextView) {
            let composing = v.markedTextRange != nil
            if parent.composing != composing { parent.composing = composing }
            if !composing, parent.text != v.text { parent.text = v.text }
        }

        // 貼り付け（メニュー・キーボードのショートカット・ユニバーサルクリップボード）を何も入れない形で受ける
        func textPasteConfigurationSupporting(_ s: UITextPasteConfigurationSupporting, transform item: UITextPasteItem) {
            item.setNoResult()
        }

        // ドラッグ＆ドロップで文字を落とさせない
        func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                               proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
            UITextDropProposal(operation: .cancel)
        }
    }
}

/// 貼り付けを受けつけない UITextView。編集メニューは選択・コピー・切り取り・削除だけ残す
/// （貼り付け・テキストのスキャン・自動入力・置き換え・作文ツールなどは出さない）
final class NoPasteTextView: UITextView {
    private static let allowed: Set<Selector> = [
        #selector(UIResponderStandardEditActions.copy(_:)),
        #selector(UIResponderStandardEditActions.cut(_:)),
        #selector(UIResponderStandardEditActions.select(_:)),
        #selector(UIResponderStandardEditActions.selectAll(_:)),
        #selector(UIResponderStandardEditActions.delete(_:)),
    ]

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard Self.allowed.contains(action) else { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {}
    override func pasteAndMatchStyle(_ sender: Any?) {}
    override func pasteAndGo(_ sender: Any?) {}
    override func pasteAndSearch(_ sender: Any?) {}

    override func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        // 編集メニューから貼り付けなどを落とす（canPerformAction で落ちないものの保険）
        let keep: Set<String> = ["copy:", "cut:", "select:", "selectAll:", "delete:"]
        func filter(_ els: [UIMenuElement]) -> [UIMenuElement] {
            els.compactMap { e in
                if let m = e as? UIMenu { return m.replacingChildren(filter(m.children)) }
                if let c = e as? UICommand { return keep.contains(NSStringFromSelector(c.action)) ? c : nil }
                return nil
            }
        }
        return UIMenu(children: filter(suggestedActions))
    }
}

/// 書き写しの段: 手本の1文 → 欄 → 一致したか。passed は「変換中でなく・完全一致」のときだけ true
struct CopyGate: View {
    let sentence: String
    @Binding var passed: Bool
    @State private var text = ""
    @State private var composing = false

    private var matched: Bool { !composing && SuperLock.matches(text, sentence) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel(title: "この文を書き写す", trailing: "一字一句そのまま")
            Text(sentence)
                .font(Theme.mincho(19, relativeTo: .title3))
                .tracking(0.8)
                .lineSpacing(6)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .paperCard(radius: 14)
                .padding(.top, 8)
                .accessibilityLabel("手本: \(sentence)")

            ZStack(alignment: .topLeading) {
                CopyTextField(text: $text, composing: $composing, placeholder: "上の文をそのまま打つ")
                if text.isEmpty && !composing {
                    Text("上の文をそのまま打つ")
                        .font(.body).foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 140, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(matched ? Theme.field.opacity(0.6) : Theme.wood.opacity(0.14), lineWidth: matched ? 1.5 : 1)
                    )
            )
            .padding(.top, 12)

            status
                .font(.footnote)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)

            Text("貼り付けはできません。句読点もそのまま打ちます。")
                .font(.caption).foregroundStyle(Theme.ink3)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: text) { _, _ in passed = matched }
        .onChange(of: composing) { _, _ in passed = matched }
    }

    @ViewBuilder
    private var status: some View {
        if composing {
            Text("変換中…").foregroundStyle(Theme.ink3)
        } else if matched {
            Label("一致しました", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.field)
        } else if !text.isEmpty && SuperLock.diverges(text, sentence) {
            Text("ちがう字があります。手本と見比べてください。").foregroundStyle(Theme.caution)
        } else {
            Text("\(text.trimmingCharacters(in: .whitespacesAndNewlines).count) ／ \(sentence.count)字")
                .foregroundStyle(Theme.ink2).monospacedDigit()
        }
    }
}
