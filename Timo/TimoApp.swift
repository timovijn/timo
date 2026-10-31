import SwiftUI
import UIKit

@main struct TimoApp: App {
    @StateObject private var store = PlanStore()
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    init() { DestructiveSubmenu.install() }
    var body: some Scene {
        WindowGroup {
            DayView().environmentObject(store)
                .background(WindowAppearance(appearance: appearance).frame(width: 0, height: 0))
                .alert("Your plan", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                    Button("OK") { store.errorMessage = nil }
                } message: { Text(store.errorMessage ?? "") }
        }
    }
}

/// Stored as a stable value so the choice survives app launches.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A quiet entry point beneath each day's and persona's items.
struct SettingsLink: View {
    @State private var showingSettings = false
    var body: some View {
        Button { showingSettings = true } label: {
            VStack(spacing: 5) {
                Text("timo")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundStyle(.tertiary)
                Label("Settings", systemImage: "gearshape")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 64, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(AppAppearance.allCases) { option in
                        Button {
                            appearance = option
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.symbol)
                                    .frame(width: 22)
                                    .foregroundStyle(.secondary)
                                Text(option.title).foregroundStyle(.primary)
                                Spacer()
                                if appearance == option {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(appearance == option ? .isSelected : [])
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your device’s Light and Dark appearance.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

/// Apply appearance once to the window, so sheets inherit the same choice. Resetting
/// the window to unspecified restores live system traits even while a sheet is open.
private struct WindowAppearance: UIViewRepresentable {
    let appearance: AppAppearance

    func makeUIView(context: Context) -> AppearanceView {
        AppearanceView(style: appearance.interfaceStyle)
    }

    func updateUIView(_ view: AppearanceView, context: Context) {
        view.style = appearance.interfaceStyle
    }

    final class AppearanceView: UIView {
        var style: UIUserInterfaceStyle {
            didSet { applyAppearance() }
        }

        init(style: UIUserInterfaceStyle) {
            self.style = style
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyAppearance()
        }

        private func applyAppearance() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
}
