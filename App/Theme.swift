import SwiftUI
import UIKit

// 見た目の決まりごと（design/mock/index.html が正）。色・書体・ボタン・カード・景色。
// 機能やロックの論理はここに置かない。ダークモードは対象外（EngawaApp で .light に固定）。

enum Theme {
    // 地
    static let paper = Color(hex: 0xF4ECDF)    // 生成り
    static let paper2 = Color(hex: 0xEDE2D0)   // 一段沈んだ生成り
    static let card = Color(hex: 0xFBF7F0)     // 障子紙
    static let line = Color(hex: 0xE2D5C0)     // 細い罫
    // 文字
    static let ink = Color(hex: 0x3B2F25)
    static let ink2 = Color(hex: 0x7B6A57)
    static let ink3 = Color(hex: 0xA8977F)
    // 差し色
    static let wood = Color(hex: 0x7A4E2D)
    static let woodDark = Color(hex: 0x5E3B21)
    static let woodLight = Color(hex: 0x865834)
    static let gold = Color(hex: 0xD6A048)
    static let field = Color(hex: 0x6F8F47)
    static let dusk = Color(hex: 0x8C5A3C)
    static let onWood = Color(hex: 0xFBF4E8)
    static let danger = Color(hex: 0xB0442C)
    static let caution = Color(hex: 0xA8641E)

    static let sideMargin: CGFloat = 24

    /// 明朝（見出し・やりたいこと）。Dynamic Type に合わせて大きくなる
    static func mincho(_ size: CGFloat, relativeTo style: Font.TextStyle = .body, bold: Bool = true) -> Font {
        .custom(bold ? "HiraMinProN-W6" : "HiraMinProN-W3", size: size, relativeTo: style)
    }

    /// 設定などの大見出し（UINavigationBar の large title）も明朝にする
    static func applyNavigationAppearance() {
        let ink = UIColor(Theme.ink)
        let large = UIFont(name: "HiraMinProN-W6", size: 32).map { UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: $0) }
        let inline = UIFont(name: "HiraMinProN-W6", size: 17).map { UIFontMetrics(forTextStyle: .headline).scaledFont(for: $0) }
        let bar = UINavigationBar.appearance()
        var largeAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: ink, .kern: 2.4]
        if let large { largeAttrs[.font] = large }
        var inlineAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: ink, .kern: 1.0]
        if let inline { inlineAttrs[.font] = inline }
        bar.largeTitleTextAttributes = largeAttrs
        bar.titleTextAttributes = inlineAttrs
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - ボタン

/// 主ボタン（縁側の板の色）。高さは最低 54pt（文字が大きくなれば伸びる）
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .tracking(1)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.onWood)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.woodLight, Theme.woodDark], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .shadow(color: Theme.woodDark.opacity(isEnabled ? 0.35 : 0), radius: 7, y: 5)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 二番手のボタン（板の色を薄く敷く）
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .tracking(1)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.woodDark)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(configuration.isPressed ? Color(hex: 0xE3D6C4) : Color(hex: 0xEBE1D2))   // 生成りに板の色を 7% 敷いた色（不透明）
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.wood.opacity(0.16), lineWidth: 1)
                    )
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 文字だけのボタン（板の色）
struct PlainWoodButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .medium))
            .foregroundStyle(Theme.wood)
            .frame(maxWidth: .infinity, minHeight: 44)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

// MARK: - カード

/// 障子紙のカード（角丸 18・ごく弱い影と細い縁）
struct PaperCard: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Theme.wood.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: Color(hex: 0x5A3C1E).opacity(0.10), radius: 9, y: 6)
            )
    }
}

extension View {
    func paperCard(radius: CGFloat = 18) -> some View { modifier(PaperCard(radius: radius)) }

    /// 小さな見出し（「代わりにやりたいこと」「理由」など）
    func sectionLabelStyle() -> some View {
        self.font(.system(.caption, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Theme.ink2)
    }

    /// 補足の文（三次の色）
    func noteStyle() -> some View {
        self.font(.footnote).foregroundStyle(Theme.ink2)
    }
}

// MARK: - 時間の選び（15／30／60分）

/// モックの分かれ目（生成りの溝に、選んだものだけ障子紙）。中身は Picker と同じ（minutes を書き換えるだけ）
struct MinuteSegment: View {
    let choices: [Int]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(choices, id: \.self) { m in
                let on = m == selection
                Button {
                    selection = m
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(m)").font(.system(.body, weight: .semibold)).monospacedDigit()
                        Text("分").font(.system(.caption, weight: .medium))
                    }
                    .foregroundStyle(on ? Theme.ink : Theme.ink2)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(on ? Theme.card : .clear)
                            .shadow(color: Color(hex: 0x3C2814).opacity(on ? 0.14 : 0), radius: 2, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(m)分")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.paper2))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

// MARK: - 理由の欄

/// 複数行の入力欄（障子紙＋細い縁）。⚠️ onSubmit は付けない（IME の確定の Enter で送らない）
struct ReasonField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(3...6)
            .font(.body)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.wood.opacity(0.14), lineWidth: 1)
                    )
            )
    }
}

// MARK: - シートの見出し（明朝＋閉じる）

struct SheetHeader: View {
    let title: String
    var close: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(Theme.mincho(24, relativeTo: .title2))
                .tracking(1.9)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 12)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.paper2))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("やめる")
            .padding(.trailing, -7)
        }
    }
}

// MARK: - 景色（ホーム上部）

/// 縁側から見た景色。左の柱と上の軒が額縁に入るように切り出し、下は生成りへ溶かす。
/// ロック中は彩度と明るさを落とし、夕暮れの色を乗算で重ねる（0.8秒で移る）
struct SceneryHero: View {
    var locked: Bool
    static let height: CGFloat = 392

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let side = w * 1.28   // モック: 幅 128%・左 -6%・上 -14pt
            ZStack(alignment: .top) {
                Color.clear
                    .overlay(alignment: .topLeading) {
                        Image("Scenery")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: side, height: side)
                            .saturation(locked ? 0.8 : 1)
                            .brightness(locked ? -0.08 : 0)
                            .offset(x: -w * 0.06, y: -14)
                    }
                    .clipped()

                // 夕暮れ（乗算）
                LinearGradient(stops: [
                    .init(color: Color(hex: 0x6E5468), location: 0),
                    .init(color: Color(hex: 0xB9876A), location: 0.45),
                    .init(color: Color(hex: 0xE2B48C), location: 0.70),
                    .init(color: Theme.paper.opacity(0), location: 0.92),
                ], startPoint: .top, endPoint: .bottom)
                .blendMode(.multiply)
                .opacity(locked ? 1 : 0)

                // 下を生成りに溶かす
                LinearGradient(stops: [
                    .init(color: Theme.paper.opacity(0), location: 0.58),
                    .init(color: Theme.paper.opacity(0.6), location: 0.78),
                    .init(color: Theme.paper.opacity(0.94), location: 0.91),
                    .init(color: Theme.paper, location: 1),
                ], startPoint: .top, endPoint: .bottom)

                // 上の薄い暗幕（ステータスバーの文字を読めるように）
                LinearGradient(colors: [Color(hex: 0x28180E).opacity(0.38), Color(hex: 0x28180E).opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
            }
            .frame(width: w, height: Self.height, alignment: .topLeading)
            .clipped()
            .compositingGroup()
        }
        .frame(height: Self.height)
        .animation(.easeInOut(duration: 0.8), value: locked)
        .accessibilityHidden(true)
    }
}
