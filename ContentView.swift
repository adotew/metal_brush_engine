import SwiftUI

struct ContentView: View {
    @StateObject private var renderer = BrushRenderer()
    @State private var showBrushSettings = false

    var body: some View {
        ZStack {
            MetalBrushView(renderer: renderer)
                .background(Color.black)

            ProcreateSizeSlider(renderer: renderer)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
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

struct ProcreateSizeSlider: View {
    @ObservedObject var renderer: BrushRenderer

    @State private var isDragging = false
    @State private var dragStartSize: Float = 0
    @State private var dragStartY: CGFloat = 0

    private let sliderWidth: CGFloat = 40
    private let trackHeight: CGFloat = 320
    private let sensitivity: Float = 0.4

    var body: some View {
        let normalizedSize = CGFloat((renderer.maxBrushSize - 1) / 199)
        let fillHeight = normalizedSize * (trackHeight - 16)

        ZStack {
            // Liquid glass capsule
            RoundedRectangle(cornerRadius: sliderWidth / 2)
                .fill(.ultraThinMaterial)
                .frame(width: sliderWidth, height: trackHeight)

            // Size fill
            VStack(spacing: 0) {
                Spacer()
                RoundedRectangle(cornerRadius: (sliderWidth - 12) / 2)
                    .fill(Color.white.opacity(0.8))
                    .frame(width: sliderWidth - 12, height: max(fillHeight, 6))
            }
            .frame(width: sliderWidth - 12, height: trackHeight - 12)
            .clipShape(RoundedRectangle(cornerRadius: (sliderWidth - 12) / 2))

            // Size label
            Text("\(Int(renderer.maxBrushSize))")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                .offset(y: -trackHeight / 2 - 18)
                .opacity(isDragging ? 1.0 : 0.7)
        }
        .frame(width: 60, height: trackHeight + 40)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartSize = renderer.maxBrushSize
                        dragStartY = value.startLocation.y
                    }

                    let dragDelta = dragStartY - value.location.y
                    let newSize = dragStartSize + Float(dragDelta) * sensitivity
                    renderer.maxBrushSize = min(max(newSize, 1), 200)
                }
                .onEnded { _ in
                    isDragging = false
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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(renderer.presets.enumerated()), id: \.element.id) { index, preset in
                        Button(action: { renderer.selectPreset(at: index) }) {
                            Image(nsImage: preset.thumbnail)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(renderer.selectedPresetIndex == index ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 56)

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

            VStack(alignment: .leading, spacing: 4) {
                Text("Flow: \(Int(renderer.flow * 100))%")
                    .font(.caption)
                Slider(value: $renderer.flow, in: 0.01...1.0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tilt Deform: \(Int(renderer.tiltInfluence * 100))%")
                    .font(.caption)
                Slider(value: $renderer.tiltInfluence, in: 0...1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Rotation Jitter: \(Int(renderer.rotationJitter * 100))%")
                    .font(.caption)
                Slider(value: $renderer.rotationJitter, in: 0...1)
            }

            Picker("Rotation Mode", selection: $renderer.rotationMode) {
                ForEach(RotationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if renderer.isSmudge {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smudge: \(Int(renderer.smudgeStrength * 100))%")
                        .font(.caption)
                    Slider(value: $renderer.smudgeStrength, in: 0...1)
                }
            }

            Divider()

            Button("Save Brush Settings") {
                renderer.saveCurrentSettingsToSidecar()
            }
        }
    }
}
