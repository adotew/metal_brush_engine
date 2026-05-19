import SwiftUI

struct ContentView: View {
    @StateObject private var renderer = BrushRenderer()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 16) {
                Text("Metal Brush Engine")
                    .font(.headline)

                Spacer()

                // Color Picker
                ColorPicker("Color", selection: colorBinding)
                    .labelsHidden()
                    .frame(width: 60)

                Divider()
                    .frame(height: 20)

                // Brush Type Selector
                Picker("Brush", selection: $renderer.brushType) {
                    ForEach(BrushType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Divider()
                    .frame(height: 20)

                // Size Slider
                VStack(spacing: 2) {
                    Text("Size: \(Int(renderer.maxBrushSize))")
                        .font(.caption)
                        .monospacedDigit()
                    Slider(value: $renderer.maxBrushSize, in: 1...200)
                        .frame(width: 100)
                }

                Divider()
                    .frame(height: 20)

                // Hardness Slider
                VStack(spacing: 2) {
                    Text("Hard: \(Int(renderer.hardness * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                    Slider(value: $renderer.hardness, in: 0...1)
                        .frame(width: 80)
                }

                // Softness Slider
                VStack(spacing: 2) {
                    Text("Soft: \(Int(renderer.softness * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                    Slider(value: $renderer.softness, in: 0...1)
                        .frame(width: 80)
                }

                // Spacing Slider
                VStack(spacing: 2) {
                    Text("Space: \(Int(renderer.spacing * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                    Slider(value: $renderer.spacing, in: 0.02...0.5)
                        .frame(width: 80)
                }

                Divider()
                    .frame(height: 20)

                // Smudge Strength (only visible for smudge brush)
                if renderer.brushType == .smudge {
                    VStack(spacing: 2) {
                        Text("Smudge: \(Int(renderer.smudgeStrength * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                        Slider(value: $renderer.smudgeStrength, in: 0...1)
                            .frame(width: 80)
                    }
                }

                // Scatter Slider
                VStack(spacing: 2) {
                    Text("Scatter: \(Int(renderer.scatter * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                    Slider(value: $renderer.scatter, in: 0...1)
                        .frame(width: 60)
                }

                // Smoothing Slider
                VStack(spacing: 2) {
                    Text("Smooth: \(Int(renderer.smoothing * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                    Slider(value: $renderer.smoothing, in: 0...0.9)
                        .frame(width: 60)
                }

                Button("Clear") {
                    renderer.clearCanvas()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            MetalBrushView(renderer: renderer)
                .background(Color.black)
        }
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
