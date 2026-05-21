import SwiftUI

struct ContentView: View {
    @StateObject private var renderer = BrushRenderer()
    @State private var showBrushLibrary = false
    @State private var showLayers = false

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

                Button(action: { renderer.isEraser.toggle() }) {
                    Label(renderer.isEraser ? "Use Brush" : "Use Eraser", systemImage: renderer.isEraser ? "paintbrush.pointed" : "eraser")
                }
                .keyboardShortcut("e", modifiers: [])

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

                Button(action: { showLayers.toggle() }) {
                    Label("Layers", systemImage: "square.3.layers.3d")
                }
                .popover(isPresented: $showLayers, arrowEdge: .bottom) {
                    LayersView(renderer: renderer)
                        .padding()
                        .frame(width: 280)
                }

                Button(action: { showBrushLibrary.toggle() }) {
                    Label("Brush Library", systemImage: "paintbrush.pointed")
                }
                .popover(isPresented: $showBrushLibrary, arrowEdge: .bottom) {
                    BrushLibraryView(renderer: renderer)
                        .padding()
                        .frame(width: 460, height: 520)
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

struct LayersView: View {
    @ObservedObject var renderer: BrushRenderer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Layers")
                    .font(.headline)

                Spacer()

                Button(action: { renderer.addLayer() }) {
                    Label("Add Layer", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .disabled(renderer.layerInfos.count >= 5)
            }

            VStack(spacing: 6) {
                ForEach(Array(renderer.layerInfos.enumerated()).reversed(), id: \.element.id) { index, layer in
                    LayerRow(renderer: renderer, index: index, layer: layer)
                }
            }
        }
    }
}

struct LayerRow: View {
    @ObservedObject var renderer: BrushRenderer
    let index: Int
    let layer: CanvasLayerInfo

    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { renderer.toggleLayerVisibility(at: index) }) {
                Label(layer.isVisible ? "Hide" : "Show", systemImage: layer.isVisible ? "eye" : "eye.slash")
            }
            .labelStyle(.iconOnly)
            .frame(width: 24)

            Button(action: { renderer.selectLayer(at: index) }) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(layer.isVisible ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04))
                        .frame(width: 34, height: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(layer.name)
                            .lineLimit(1)
                        Text("\(Int(layer.opacity * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if renderer.selectedLayerIndex == index {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { showOptions.toggle() }) {
                Label("Layer Options", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: 24)
            .popover(isPresented: $showOptions, arrowEdge: .trailing) {
                LayerOptionsView(renderer: renderer, index: index, layer: layer)
                    .padding()
                    .frame(width: 220)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(renderer.selectedLayerIndex == index ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct LayerOptionsView: View {
    @ObservedObject var renderer: BrushRenderer
    let index: Int
    let layer: CanvasLayerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(layer.name)
                .font(.headline)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 6) {
                Text("Opacity: \(Int(layer.opacity * 100))%")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(layer.opacity) },
                        set: { renderer.setLayerOpacity(Float($0), at: index) }
                    ),
                    in: 0...1
                )
            }

            Divider()

            Button(role: .destructive, action: { renderer.deleteLayer(at: index) }) {
                Label("Delete Layer", systemImage: "trash")
            }
            .disabled(!renderer.canDeleteLayer(at: index))
        }
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

struct BrushLibraryView: View {
    @ObservedObject var renderer: BrushRenderer

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Brushes")
                    .font(.headline)
                    .padding(.bottom, 4)

                ForEach(BrushCategory.allCases) { category in
                    Button(action: { renderer.selectedBrushCategory = category }) {
                        HStack {
                            Text(category.displayName)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(renderer.selectedBrushCategory == category ? Color.accentColor.opacity(0.16) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 112, alignment: .top)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(renderer.selectedBrushCategory.displayName)
                        .font(.headline)
                    Spacer()
                }

                BrushPresetList(renderer: renderer)

                Divider()

                BrushEditorView(renderer: renderer)
            }
        }
    }
}

struct BrushPresetList: View {
    @ObservedObject var renderer: BrushRenderer

    var body: some View {
        let presets = Array(renderer.presets.enumerated())
            .filter { $0.element.category == renderer.selectedBrushCategory }

        ScrollView {
            VStack(spacing: 6) {
                ForEach(presets, id: \.element.id) { index, preset in
                    BrushPresetRow(renderer: renderer, index: index, preset: preset)
                }
            }
        }
    }
}

struct BrushPresetRow: View {
    @ObservedObject var renderer: BrushRenderer
    let index: Int
    let preset: BrushPreset

    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { renderer.selectPreset(at: index) }) {
                HStack(spacing: 10) {
                    Image(nsImage: preset.thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .lineLimit(1)
                        Text(preset.settings.isEraser ? "Eraser" : (preset.settings.isSmudge ? "Smudge" : "Brush"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if renderer.selectedPresetIndex == index {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { showOptions.toggle() }) {
                Label("Brush Options", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: 24)
            .popover(isPresented: $showOptions, arrowEdge: .trailing) {
                BrushPresetOptionsView(renderer: renderer, index: index, preset: preset)
                    .padding()
                    .frame(width: 240)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(renderer.selectedPresetIndex == index ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct BrushPresetOptionsView: View {
    @ObservedObject var renderer: BrushRenderer
    let index: Int
    let preset: BrushPreset

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preset.name)
                .font(.headline)
                .lineLimit(1)

            TextField("Name", text: $name)
                .disabled(!preset.isUserEditable)
                .onAppear { name = preset.name }

            HStack {
                Button("Rename") {
                    renderer.renamePreset(at: index, to: name)
                }
                .disabled(!preset.isUserEditable || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == preset.name)

                Button("Duplicate") {
                    renderer.duplicatePreset(at: index)
                }
            }

            Button("Save Current Settings") {
                renderer.saveCurrentSettingsToSidecar()
            }
            .disabled(renderer.selectedPresetIndex != index)

            Divider()

            Button(role: .destructive, action: { renderer.deletePreset(at: index) }) {
                Label("Delete Brush", systemImage: "trash")
            }
            .disabled(!renderer.canDeletePreset(at: index))
        }
    }
}

struct BrushEditorView: View {
    @ObservedObject var renderer: BrushRenderer

    var body: some View {
        DisclosureGroup("Brush Settings") {
            VStack(alignment: .leading, spacing: 10) {
                BrushSlider(title: "Size", value: $renderer.maxBrushSize, range: 1...200, format: { "\(Int($0))" })
                BrushSlider(title: "Hardness", value: $renderer.hardness, range: 0...1, format: percentText)
                BrushSlider(title: "Softness", value: $renderer.softness, range: 0...1, format: percentText)
                BrushSlider(title: "Spacing", value: $renderer.spacing, range: 0.02...0.5, format: percentText)
                BrushSlider(title: "Scatter", value: $renderer.scatter, range: 0...1, format: percentText)
                BrushSlider(title: "Smoothing", value: $renderer.smoothing, range: 0...0.9, format: percentText)
                BrushSlider(title: "Flow", value: $renderer.flow, range: 0.01...1.0, format: percentText)
                BrushSlider(title: "Tilt Deform", value: $renderer.tiltInfluence, range: 0...1, format: percentText)
                BrushSlider(title: "Rotation Jitter", value: $renderer.rotationJitter, range: 0...1, format: percentText)

                Toggle("Eraser", isOn: $renderer.isEraser)

                Picker("Rotation Mode", selection: $renderer.rotationMode) {
                    ForEach(RotationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if renderer.isSmudge {
                    BrushSlider(title: "Smudge", value: $renderer.smudgeStrength, range: 0...1, format: percentText)
                }
            }
            .padding(.top, 8)
        }
    }

    private func percentText(_ value: Float) -> String {
        "\(Int(value * 100))%"
    }
}

struct BrushSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: (Float) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title): \(format(value))")
                .font(.caption)
            Slider(value: $value, in: range)
        }
    }
}
