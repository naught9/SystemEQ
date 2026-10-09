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

        Window("Equalizer", id: WindowID.editor) {
            EditorView(model: model)
        }
        .defaultSize(width: 900, height: 700)

        Window("Visualizer", id: WindowID.visualizer) {
            VisualizerView(engine: model.engine)
        }
        .defaultSize(width: 900, height: 600)
    }
}

enum WindowID {
    static let editor = "editor"
    static let visualizer = "visualizer"
}
