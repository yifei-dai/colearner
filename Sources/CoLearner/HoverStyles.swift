import SwiftUI

/// Whether the pointer is over a view. An object, because this SDK's @State needs Xcode's macro plugin.
final class HoverFlag: ObservableObject {
    @Published var on = false
}

/// Small icon buttons in the top bar (+, ×, ‹ ›): a soft rounded highlight while the pointer is over them
/// and a darker one while pressed, like a browser's tab bar.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 22
    var cornerRadius: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, cornerRadius: cornerRadius)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let cornerRadius: CGFloat
    @StateObject private var hover = HoverFlag()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled && hover.on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(minWidth: size, minHeight: size)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(fill)))
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hover.on = $0 }
            .animation(.easeOut(duration: 0.12), value: hover.on)
    }

    private var fill: Double {
        guard isEnabled else { return 0 }
        return configuration.isPressed ? 0.2 : hover.on ? 0.11 : 0
    }
}

/// The same highlight for controls that aren't plain buttons (the Lectures and Appearance menus).
private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @StateObject private var hover = HoverFlag()

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(hover.on ? 0.11 : 0)))
            .onHover { hover.on = $0 }
            .animation(.easeOut(duration: 0.12), value: hover.on)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 5) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}
