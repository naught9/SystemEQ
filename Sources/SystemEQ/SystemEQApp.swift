import SwiftUI

@main
struct SystemEQApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.isEnabled ? "slider.vertical.3" : "slider.horizontal.below.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}
