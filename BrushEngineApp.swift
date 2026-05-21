import SwiftUI

@main
struct BrushEngineApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 400, minHeight: 300)
        }
        .windowResizability(.contentSize)
        .commands {
            DocumentCommands()
        }
    }
}

private struct DocumentCommands: Commands {
    @FocusedValue(\.openMetalBrushDocument) private var openDocument
    @FocusedValue(\.saveMetalBrushDocument) private var saveDocument
    @FocusedValue(\.saveMetalBrushDocumentAs) private var saveDocumentAs
    @FocusedValue(\.exportMetalBrushPNG) private var exportPNG

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open...") {
                openDocument?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openDocument == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                saveDocument?()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveDocument == nil)

            Button("Save As...") {
                saveDocumentAs?()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(saveDocumentAs == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Export PNG...") {
                exportPNG?()
            }
            .disabled(exportPNG == nil)
        }
    }
}

private struct OpenMetalBrushDocumentKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SaveMetalBrushDocumentKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SaveMetalBrushDocumentAsKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ExportMetalBrushPNGKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var openMetalBrushDocument: (() -> Void)? {
        get { self[OpenMetalBrushDocumentKey.self] }
        set { self[OpenMetalBrushDocumentKey.self] = newValue }
    }

    var saveMetalBrushDocument: (() -> Void)? {
        get { self[SaveMetalBrushDocumentKey.self] }
        set { self[SaveMetalBrushDocumentKey.self] = newValue }
    }

    var saveMetalBrushDocumentAs: (() -> Void)? {
        get { self[SaveMetalBrushDocumentAsKey.self] }
        set { self[SaveMetalBrushDocumentAsKey.self] = newValue }
    }

    var exportMetalBrushPNG: (() -> Void)? {
        get { self[ExportMetalBrushPNGKey.self] }
        set { self[ExportMetalBrushPNGKey.self] = newValue }
    }
}
