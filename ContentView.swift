import SwiftUI

struct ContentView: View {
    @StateObject private var renderer = BrushRenderer()
    @State private var showBrushSettings = false

    var body: some View {
        MetalBrushView(renderer: renderer)
            .background(Color.black)
            .toolbar {
                ToolbarItemGroup {
                    ColorPicker("Color", selection: colorBinding)
                        .labelsHidden()

                    Button(action: { renderer.undo() }) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!renderer.canUndo)
                    .keyboardShortcut("z", modifiers: .command)

                    Button(action: { renderer.redo() }) {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!renderer.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])

                    Button(action: { renderer.clearCanvas() }) {
                        Label("Clear", systemImage: "trash")
                    }

                    Button(action: { showBrushSettings.toggle() }) {
                        Label("Brush Settings", systemImage: "pencil")
                    }
                    .popover(isPresented: $showBrushSettings, arrowEdge: .bottom) {
                        BrushSettingsView(renderer: renderer)
                            .padding()
                            .frame(width: 300)
                    }
                }
            }
            .navigationTitle("")
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: Double(renderer.brushColor.x),
                    green: Double(renderer.brushColor.y),
                    blue: Double(renderer.brushColor.z)
                )
            },
            set: { newColor in
                if let cgColor = newColor.cgColor,
                   let nsColor = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) {
                    renderer.brushColor = SIMD3<Float>(
                        Float(nsColor.redComponent),
                        Float(nsColor.greenComponent),
                        Float(nsColor.blueComponent)
                    )
                }
            }
        )
    }
}

struct BrushSettingsView: View {
    @ObservedObject var renderer: BrushRenderer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Brush Settings")
                .font(.headline)

            Picker("Brush", selection: $renderer.brushType) {
                ForEach(BrushType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Size: \(Int(renderer.maxBrushSize))")
                    .font(.caption)
                Slider(value: $renderer.maxBrushSize, in: 1...200)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Hardness: \(Int(renderer.hardness * 100))%")
                    .font(.caption)
                Slider(value: $renderer.hardness, in: 0...1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Softness: \(Int(renderer.softness * 100))%")
                    .font(.caption)
                Slider(value: $renderer.softness, in: 0...1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Spacing: \(Int(renderer.spacing * 100))%")
                    .font(.caption)
                Slider(value: $renderer.spacing, in: 0.02...0.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Scatter: \(Int(renderer.scatter * 100))%")
                    .font(.caption)
                Slider(value: $renderer.scatter, in: 0...1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Smoothing: \(Int(renderer.smoothing * 100))%")
                    .font(.caption)
                Slider(value: $renderer.smoothing, in: 0...0.9)
            }

            if renderer.brushType == .smudge {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smudge: \(Int(renderer.smudgeStrength * 100))%")
                        .font(.caption)
                    Slider(value: $renderer.smudgeStrength, in: 0...1)
                }
            }
        }
    }
}
