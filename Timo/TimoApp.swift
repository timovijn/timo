import SwiftUI

@main struct TimoApp: App {
    @StateObject private var store = PlanStore()
    var body: some Scene {
        WindowGroup {
            DayView().environmentObject(store)
                .alert("Your plan", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                    Button("OK") { store.errorMessage = nil }
                } message: { Text(store.errorMessage ?? "") }
        }
    }
}
