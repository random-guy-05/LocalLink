import SwiftUI

struct LocalWindowAction {
    var open: @MainActor (String) -> Void
    @MainActor func callAsFunction(id: String) { open(id) }
}

private struct LocalWindowActionKey: EnvironmentKey {
    static let defaultValue = LocalWindowAction { _ in }
}

extension EnvironmentValues {
    var localWindowAction: LocalWindowAction {
        get { self[LocalWindowActionKey.self] }
        set { self[LocalWindowActionKey.self] = newValue }
    }
}

@available(macOS 13.0, *)
struct ModernWindowContent<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder var content: () -> Content
    var body: some View { content().environment(\.localWindowAction, LocalWindowAction { openWindow(id: $0) }) }
}
