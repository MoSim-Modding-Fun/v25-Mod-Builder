import SwiftUI

/// Colors ported 1:1 from the Electron app's styles.css (the Rufus-style light theme)
/// so both apps read as the same product. macOS has no Segoe UI, so text uses the
/// system font instead - everything else (palette, borders, button shapes) matches.
enum Theme {
    static let background = Color(hex: 0xF0F0F0)
    static let fieldsetBorder = Color(hex: 0xADADAD)
    static let fieldBorder = Color(hex: 0x7A7A7A)
    static let placeholder = Color(hex: 0x767676)
    static let dim = Color(hex: 0x333333)
    static let error = Color(hex: 0xCC0000)
    static let ok = Color(hex: 0x0A7D1F)
    static let accentBlue = Color(hex: 0x0078D7)
    static let linkBlue = Color(hex: 0x0063B1)
    static let startGreen = Color(hex: 0x2E7D32)
    static let startGreenHover = Color(hex: 0x357A38)
    static let startGreenActive = Color(hex: 0x245E28)
    static let consoleBg = Color(hex: 0x0D1117)
    static let consoleText = Color(hex: 0x9CB4D8)
    static let consoleTime = Color(hex: 0x5C6773)
    static let consoleBorder = Color(hex: 0x1C2128)
    static let consoleSuccess = Color(hex: 0x7EE787)
    static let consoleFailure = Color(hex: 0xFF7B72)
    static let dotInactive = Color(hex: 0xD6D6D6)
    static let dotInactiveBorder = Color(hex: 0xB7B7B7)
    static let badgeBorder = Color(hex: 0xCCCCCC)
    static let buttonBorder = Color(hex: 0x8F8F8F)
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Replicates the CSS `fieldset.group` "etched border with the legend notched into it"
/// look - a bordered box with a label sitting on top of the top border line.
struct RufusGroupBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Theme.fieldsetBorder, lineWidth: 1)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(EdgeInsets(top: 16, leading: 10, bottom: 10, trailing: 10))

            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.black)
                .padding(.horizontal, 4)
                .background(Theme.background)
                .padding(.leading, 10)
        }
    }
}

/// A readonly path display matching the CSS `.field` input - shows grayed placeholder
/// text when empty, truncates long paths in the middle.
struct RufusField: View {
    let text: String
    let placeholder: String

    var body: some View {
        Text(text.isEmpty ? placeholder : text)
            .font(.system(size: 12))
            .foregroundColor(text.isEmpty ? Theme.placeholder : .black)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white)
            .overlay(Rectangle().stroke(Theme.fieldBorder, lineWidth: 1))
            .help(text)
    }
}

/// The default gray-gradient Windows-95-descended button look (BACK, SELECT, "...").
struct RufusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                LinearGradient(colors: [Color(hex: 0xFEFEFE), Color(hex: 0xE5E5E5)], startPoint: .top, endPoint: .bottom)
            )
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.buttonBorder, lineWidth: 1))
            .foregroundColor(.black)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The solid green primary action (NEXT / START).
struct StartButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fill = !enabled ? Color(hex: 0xD8D8D8) : (configuration.isPressed ? Theme.startGreenActive : Theme.startGreen)
        return configuration.label
            .font(.system(size: 14, weight: .bold))
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(fill)
            .foregroundColor(enabled ? .white : Color(hex: 0x999999))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(enabled ? Theme.startGreen : Color(hex: 0xB5B5B5), lineWidth: 1))
    }
}

/// The dark/light toggle look for the per-platform console tabs.
struct ConsoleTabButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(active ? Theme.consoleBg : Color(hex: 0xE5E5E5))
            .foregroundColor(active ? .white : .black)
            .overlay(Rectangle().stroke(active ? Theme.consoleBorder : Theme.fieldsetBorder, lineWidth: 1))
    }
}
