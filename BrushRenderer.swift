import MetalKit
import SwiftUI

struct CursorUniforms {
    var center: SIMD2<Float>
    var radius: SIMD2<Float>
    var show: Float
    var padding: Float = 0
}

struct CanvasLayerInfo: Identifiable {
    let id: UUID
    var name: String
    var isVisible: Bool
    var opacity: Float
}

private final class CanvasLayer {
    let id = UUID()
    var name: String
    let texture: MTLTexture
    let history: CanvasHistory
    var isVisible = true
    var opacity: Float = 1

    init(name: String, texture: MTLTexture, history: CanvasHistory) {
        self.name = name
        self.texture = texture
        self.history = history
    }

    var info: CanvasLayerInfo {
        CanvasLayerInfo(id: id, name: name, isVisible: isVisible, opacity: opacity)
    }
}

class BrushRenderer: NSObject, ObservableObject {
    // MARK: - Metal Resources
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var brushPipelineState: MTLRenderPipelineState!
    var eraserPipelineState: MTLRenderPipelineState!
    var displayPipelineState: MTLRenderPipelineState!
    var cursorPipelineState: MTLRenderPipelineState!
    var quadVertexBuffer: MTLBuffer!
    var instanceBuffer: MTLBuffer!
    var canvasBackupTexture: MTLTexture!
    var samplerState: MTLSamplerState!
    var displaySamplerState: MTLSamplerState!

    // MARK: - Canvas
    let canvasSize = CGSize(width: 6000, height: 4000)
    private lazy var viewport = CanvasViewport(canvasSize: canvasSize)

    // MARK: - Brush Presets
    @Published var presets: [BrushPreset] = []
    @Published var selectedPresetIndex: Int = 0
    @Published var selectedBrushCategory: BrushCategory = .sketching
    private var presetStore: BrushPresetStore!

    var activePreset: BrushPreset? {
        guard selectedPresetIndex >= 0 && selectedPresetIndex < presets.count else { return nil }
        return presets[selectedPresetIndex]
    }

    // MARK: - Rendering State
    private var brushEngine = BrushEngine()
    private var layers: [CanvasLayer] = []
    private var newDabs: [DabInstance] = []
    private let maxDabs = 10000
    private var needsSnapshotSave = false
    private let maxLayers = 5
    private let documentStore = CanvasDocumentStore()

    @Published private(set) var layerInfos: [CanvasLayerInfo] = []
    @Published var selectedLayerIndex: Int = 0

    private var activeLayer: CanvasLayer? {
        guard selectedLayerIndex >= 0 && selectedLayerIndex < layers.count else { return nil }
        return layers[selectedLayerIndex]
    }

    // MARK: - Published Brush Parameters
    @Published var brushColor: SIMD3<Float> = SIMD3<Float>(0.365, 0.251, 0.216) {
        didSet { updateBrushEngineState() }
    }
    @Published var maxBrushSize: Float = 30.0
    @Published var minBrushSize: Float = 2.0
    @Published var hardness: Float = 0.5 {
        didSet { updateBrushEngineState() }
    }
    @Published var softness: Float = 0.0 {
        didSet { updateBrushEngineState() }
    }
    @Published var spacing: Float = 0.15 {
        didSet { updateBrushEngineState() }
    }
    @Published var scatter: Float = 0.0 {
        didSet { updateBrushEngineState() }
    }
    @Published var rotationJitter: Float = 0.0 {
        didSet { updateBrushEngineState() }
    }
    @Published var rotationMode: RotationMode = .followStroke {
        didSet { updateBrushEngineState() }
    }
    @Published var smoothing: Float = 0.3 {
        didSet { updateBrushEngineState() }
    }
    @Published var flow: Float = 1.0 {
        didSet { updateBrushEngineState() }
    }
    @Published var tiltInfluence: Float = 0.5 {
        didSet { updateBrushEngineState() }
    }
    @Published var smudgeStrength: Float = 0.7 {
        didSet { updateBrushEngineState() }
    }
    @Published var isSmudge: Bool = false {
        didSet { updateBrushEngineState() }
    }
    @Published var isEraser: Bool = false {
        didSet { updateBrushEngineState() }
    }

    // MARK: - Cursor
    var cursorPosition: SIMD2<Float> = .zero
    var showCursor: Bool = false

    override init() {
        super.init()
        setupMetal()
    }

    // MARK: - Setup
    func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        self.presetStore = BrushPresetStore(device: device)

        createCanvasTextures()
        setupBrushPipeline()
        setupEraserPipeline()
        setupDisplayPipeline()
        setupCursorPipeline()
        setupQuadBuffer()
        setupInstanceBuffer()
        setupSamplers()
        loadBrushPresets()
        updateBrushEngineState()
    }

    func createCanvasTextures() {
        canvasBackupTexture = makeCanvasTexture()
        layers = []

        guard let baseTexture = makeCanvasTexture() else { return }
        let baseLayer = CanvasLayer(
            name: "Background",
            texture: baseTexture,
            history: CanvasHistory(device: device, canvasTexture: baseTexture, maxLevels: 20)
        )
        layers.append(baseLayer)
        selectedLayerIndex = 0
        clear(texture: baseTexture, color: MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0), using: commandQueue)
        baseLayer.history.saveSnapshot(from: baseTexture, using: commandQueue)
        refreshLayerInfos()
    }

    private func makeCanvasTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func makeStagingTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    func setupBrushPipeline() {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "brushVertex")
        let fragmentFunction = library?.makeFunction(name: "brushFragment")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = makeQuadVertexDescriptor()
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            brushPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create brush pipeline: \(error)")
        }
    }

    func setupEraserPipeline() {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "brushVertex")
        let fragmentFunction = library?.makeFunction(name: "brushFragment")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = makeQuadVertexDescriptor()
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .zero
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            eraserPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create eraser pipeline: \(error)")
        }
    }

    func setupDisplayPipeline() {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "displayVertex")
        let fragmentFunction = library?.makeFunction(name: "displayFragment")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = makeQuadVertexDescriptor()
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            displayPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create display pipeline: \(error)")
        }
    }

    func setupCursorPipeline() {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "cursorVertex")
        let fragmentFunction = library?.makeFunction(name: "cursorFragment")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = makeQuadVertexDescriptor()
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            cursorPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create cursor pipeline: \(error)")
        }
    }

    private func makeQuadVertexDescriptor() -> MTLVertexDescriptor {
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride * 2
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        vertexDescriptor.layouts[0].stepRate = 1
        return vertexDescriptor
    }

    func setupQuadBuffer() {
        let vertices: [SIMD2<Float>] = [
            SIMD2<Float>(-1, -1), SIMD2<Float>( 1,  1), SIMD2<Float>(-1,  1),
            SIMD2<Float>(-1, -1), SIMD2<Float>( 1, -1), SIMD2<Float>( 1,  1)
        ]
        let texCoords: [SIMD2<Float>] = [
            SIMD2<Float>(0, 1), SIMD2<Float>(1, 0), SIMD2<Float>(0, 0),
            SIMD2<Float>(0, 1), SIMD2<Float>(1, 1), SIMD2<Float>(1, 0)
        ]

        var data: [Float] = []
        for i in 0..<6 {
            data.append(vertices[i].x)
            data.append(vertices[i].y)
            data.append(texCoords[i].x)
            data.append(texCoords[i].y)
        }

        quadVertexBuffer = device.makeBuffer(bytes: data, length: data.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    func setupInstanceBuffer() {
        let bufferSize = maxDabs * MemoryLayout<DabInstance>.stride
        instanceBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
    }

    func setupSamplers() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: descriptor)
        displaySamplerState = device.makeSamplerState(descriptor: descriptor)
    }

    // MARK: - Presets
    func loadBrushPresets() {
        presets = presetStore.loadPresets()
        if !presets.isEmpty {
            selectPreset(at: 0)
        }
    }

    func selectPreset(at index: Int) {
        guard index >= 0 && index < presets.count else { return }
        selectedPresetIndex = index
        selectedBrushCategory = presets[index].category
        apply(settings: presets[index].settings)
        objectWillChange.send()
    }

    func saveCurrentSettingsToSidecar() {
        guard let preset = activePreset else { return }
        let settings = currentBrushSettings()
        presetStore.saveSettings(settings, for: preset)
        presets[selectedPresetIndex].settings = settings
        objectWillChange.send()
    }

    func duplicatePreset(at index: Int) {
        guard index >= 0 && index < presets.count else { return }
        guard let duplicated = presetStore.duplicate(presets[index]) else { return }
        reloadBrushPresets(selecting: duplicated.name)
    }

    func renamePreset(at index: Int, to name: String) {
        guard index >= 0 && index < presets.count else { return }
        if presetStore.rename(presets[index], to: name) {
            reloadBrushPresets(selecting: name)
        }
    }

    func canDeletePreset(at index: Int) -> Bool {
        index >= 0 && index < presets.count && presets[index].isUserEditable && presets.count > 1
    }

    func deletePreset(at index: Int) {
        guard canDeletePreset(at: index) else { return }
        let fallbackIndex = max(0, index - 1)
        let fallbackName = presets.indices.contains(fallbackIndex) ? presets[fallbackIndex].name : nil
        if presetStore.delete(presets[index]) {
            reloadBrushPresets(selecting: fallbackName)
        }
    }

    private func apply(settings: BrushSettings) {
        spacing = settings.spacing
        flow = settings.flow
        scatter = settings.scatter
        hardness = settings.hardness
        softness = settings.softness
        rotationJitter = settings.rotationJitter
        rotationMode = settings.rotationMode
        tiltInfluence = settings.tiltInfluence
        smudgeStrength = settings.smudgeStrength
        isSmudge = settings.isSmudge
        isEraser = settings.isEraser
        updateBrushEngineState()
    }

    private func currentBrushSettings() -> BrushSettings {
        BrushSettings(
            spacing: spacing,
            flow: flow,
            scatter: scatter,
            hardness: hardness,
            softness: softness,
            rotationJitter: rotationJitter,
            tiltInfluence: tiltInfluence,
            smudgeStrength: smudgeStrength,
            isSmudge: isSmudge,
            isEraser: isEraser,
            rotationMode: rotationMode
        )
    }

    private func updateBrushEngineState() {
        let state = BrushEngineState(
            settings: currentBrushSettings(),
            brushColor: brushColor,
            smoothing: smoothing,
            canvasSize: SIMD2<Float>(Float(canvasSize.width), Float(canvasSize.height))
        )
        brushEngine.updateState(state)
    }

    private func reloadBrushPresets(selecting name: String?) {
        presets = presetStore.loadPresets()
        if let name, let index = presets.firstIndex(where: { $0.name == name }) {
            selectPreset(at: index)
        } else if !presets.isEmpty {
            selectPreset(at: min(selectedPresetIndex, presets.count - 1))
        }
        objectWillChange.send()
    }

    // MARK: - Snapshot / Undo / Redo
    func undo() {
        guard !brushEngine.isStrokeActive else { return }
        guard let activeLayer else { return }
        if activeLayer.history.undo(to: activeLayer.texture, using: commandQueue) {
            objectWillChange.send()
        }
    }

    func redo() {
        guard !brushEngine.isStrokeActive else { return }
        guard let activeLayer else { return }
        if activeLayer.history.redo(to: activeLayer.texture, using: commandQueue) {
            objectWillChange.send()
        }
    }

    var canUndo: Bool {
        (activeLayer?.history.canUndo ?? false) && !brushEngine.isStrokeActive
    }

    var canRedo: Bool {
        (activeLayer?.history.canRedo ?? false) && !brushEngine.isStrokeActive
    }

    // MARK: - Canvas Operations
    func clearCanvas(skipSnapshot: Bool = false) {
        guard let activeLayer else { return }
        let color = selectedLayerIndex == 0
            ? MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
            : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        clear(texture: activeLayer.texture, color: color, using: commandQueue)

        newDabs.removeAll()
        brushEngine.resetStroke()

        if !skipSnapshot {
            activeLayer.history.saveSnapshot(from: activeLayer.texture, using: commandQueue)
        }
    }

    private func clear(texture: MTLTexture, color: MTLClearColor, using commandQueue: MTLCommandQueue) {
        let commandBuffer = commandQueue.makeCommandBuffer()
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = color

        let renderEncoder = commandBuffer?.makeRenderCommandEncoder(descriptor: passDescriptor)
        renderEncoder?.endEncoding()
        commandBuffer?.commit()
    }

    // MARK: - Document IO
    func saveDocument(to url: URL) throws {
        let layerDocuments = layers.enumerated().map { index, layer in
            CanvasDocumentLayer(
                name: layer.name,
                isVisible: layer.isVisible,
                opacity: layer.opacity,
                filename: String(format: "layer-%03d.png", index)
            )
        }
        let manifest = CanvasDocumentManifest(
            canvasWidth: Int(canvasSize.width),
            canvasHeight: Int(canvasSize.height),
            selectedLayerIndex: selectedLayerIndex,
            layers: layerDocuments
        )
        let layerImages = try zip(layerDocuments, layers).map { documentLayer, layer in
            let pixels = try readPixels(from: layer.texture)
            let data = try documentStore.pngData(
                fromBGRA: pixels,
                width: layer.texture.width,
                height: layer.texture.height
            )
            return (filename: documentLayer.filename, data: data)
        }

        try documentStore.saveDocument(manifest: manifest, layerImages: layerImages, to: url)
    }

    func loadDocument(from url: URL) throws {
        let document = try documentStore.loadDocument(from: url)
        guard document.manifest.canvasWidth == Int(canvasSize.width),
              document.manifest.canvasHeight == Int(canvasSize.height),
              !document.manifest.layers.isEmpty else {
            throw CanvasDocumentError.unsupportedCanvasSize
        }

        var loadedLayers: [CanvasLayer] = []
        for (documentLayer, bitmap) in document.layerImages {
            let pixels = try documentStore.bgraPixels(
                from: bitmap,
                expectedWidth: Int(canvasSize.width),
                expectedHeight: Int(canvasSize.height)
            )
            guard let texture = makeCanvasTexture() else {
                throw CanvasDocumentError.invalidDocument
            }
            uploadPixels(pixels, to: texture)

            let layer = CanvasLayer(
                name: documentLayer.name,
                texture: texture,
                history: CanvasHistory(device: device, canvasTexture: texture, maxLevels: 20)
            )
            layer.isVisible = documentLayer.isVisible
            layer.opacity = min(max(documentLayer.opacity, 0), 1)
            layer.history.saveSnapshot(from: texture, using: commandQueue)
            loadedLayers.append(layer)
        }

        layers = loadedLayers
        selectedLayerIndex = min(max(document.manifest.selectedLayerIndex, 0), layers.count - 1)
        newDabs.removeAll()
        brushEngine.resetStroke()
        refreshLayerInfos()
        objectWillChange.send()
    }

    func exportFlattenedPNG(to url: URL) throws {
        guard let texture = makeFlattenedCanvasTexture() else {
            throw CanvasDocumentError.pngEncodingFailed
        }
        let pixels = try readPixels(from: texture)
        let data = try documentStore.pngData(fromBGRA: pixels, width: texture.width, height: texture.height)
        try data.write(to: url)
    }

    private func makeFlattenedCanvasTexture() -> MTLTexture? {
        guard let texture = makeCanvasTexture() else { return nil }
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)!
        renderEncoder.setRenderPipelineState(displayPipelineState)
        renderEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        var displayUniforms = DisplayUniforms(scale: SIMD2<Float>(1, 1), translation: SIMD2<Float>(0, 0))
        renderEncoder.setVertexBytes(&displayUniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 1)
        renderEncoder.setFragmentSamplerState(displaySamplerState, index: 0)

        for layer in layers where layer.isVisible && layer.opacity > 0 {
            var opacity = layer.opacity
            renderEncoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
            renderEncoder.setFragmentTexture(layer.texture, index: 0)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        renderEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    private func readPixels(from texture: MTLTexture) throws -> [UInt8] {
        guard let stagingTexture = makeStagingTexture(width: texture.width, height: texture.height) else {
            throw CanvasDocumentError.pngEncodingFailed
        }
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: stagingTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        stagingTexture.getBytes(
            &pixels,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return pixels
    }

    private func uploadPixels(_ pixels: [UInt8], to texture: MTLTexture) {
        guard let stagingTexture = makeStagingTexture(width: texture.width, height: texture.height) else { return }
        let bytesPerRow = texture.width * 4
        stagingTexture.replace(
            region: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
        blitEncoder.copy(
            from: stagingTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Stroke Lifecycle
    func startStroke(with point: BrushPoint) {
        appendGeneratedDabs(brushEngine.startStroke(with: point))
    }

    func continueStroke(with point: BrushPoint) {
        appendGeneratedDabs(brushEngine.continueStroke(with: point))
    }

    func endStroke() {
        appendGeneratedDabs(brushEngine.endStroke())
        needsSnapshotSave = true
    }

    private func appendGeneratedDabs(_ dabs: [DabInstance]) {
        guard !dabs.isEmpty, newDabs.count < maxDabs else { return }
        let availableCount = maxDabs - newDabs.count
        newDabs.append(contentsOf: dabs.prefix(availableCount))
    }

    // MARK: - Rendering
    func render(to view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        guard let activeLayer else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!
        prepareDabsForRendering(onBackgroundLayer: selectedLayerIndex == 0)

        let needsSmudge = newDabs.contains { $0.smudgeStrength > 0 }
        if needsSmudge && !newDabs.isEmpty {
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
            blitEncoder.copy(
                from: activeLayer.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: activeLayer.texture.width, height: activeLayer.texture.height, depth: 1),
                to: canvasBackupTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
        }

        if !newDabs.isEmpty {
            uploadInstances()
            let instanceCount = min(newDabs.count, maxDabs)

            let canvasPass = MTLRenderPassDescriptor()
            canvasPass.colorAttachments[0].texture = activeLayer.texture
            canvasPass.colorAttachments[0].loadAction = .load
            canvasPass.colorAttachments[0].storeAction = .store

            let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: canvasPass)!
            let isEraserStroke = newDabs.allSatisfy { $0.isEraser > 0 }
            renderEncoder.setRenderPipelineState(isEraserStroke ? eraserPipelineState : brushPipelineState)
            renderEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)

            var viewportSize = SIMD2<Float>(Float(activeLayer.texture.width), Float(activeLayer.texture.height))
            renderEncoder.setVertexBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)

            renderEncoder.setFragmentBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            if let texture = activePreset?.texture {
                renderEncoder.setFragmentTexture(texture, index: 0)
            }
            renderEncoder.setFragmentTexture(canvasBackupTexture, index: 1)
            renderEncoder.setFragmentSamplerState(samplerState, index: 0)

            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
            renderEncoder.endEncoding()

            newDabs.removeAll()
        }

        if needsSnapshotSave {
            activeLayer.history.saveSnapshot(from: activeLayer.texture, using: commandBuffer)
            needsSnapshotSave = false
            objectWillChange.send()
        }

        let displayPass = MTLRenderPassDescriptor()
        displayPass.colorAttachments[0].texture = drawable.texture
        displayPass.colorAttachments[0].loadAction = .clear
        displayPass.colorAttachments[0].storeAction = .store
        displayPass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)

        let displayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: displayPass)!
        displayEncoder.setRenderPipelineState(displayPipelineState)
        displayEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        var displayUniforms = viewport.displayUniforms(viewSize: view.bounds.size)
        displayEncoder.setVertexBytes(&displayUniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 1)
        displayEncoder.setFragmentSamplerState(displaySamplerState, index: 0)
        for layer in layers where layer.isVisible && layer.opacity > 0 {
            var opacity = layer.opacity
            displayEncoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
            displayEncoder.setFragmentTexture(layer.texture, index: 0)
            displayEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        displayEncoder.endEncoding()

        renderCursorIfNeeded(in: view, drawable: drawable, commandBuffer: commandBuffer)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func prepareDabsForRendering(onBackgroundLayer: Bool) {
        guard !newDabs.isEmpty else { return }
        for index in newDabs.indices where newDabs[index].isEraser > 0 {
            newDabs[index].smudgeStrength = 0
            if onBackgroundLayer {
                newDabs[index].color = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
                newDabs[index].isEraser = 0
            }
        }
    }

    private func renderCursorIfNeeded(in view: MTKView, drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        let viewW = Float(view.bounds.width)
        let viewH = Float(view.bounds.height)
        let cursorPoint = CGPoint(x: CGFloat(cursorPosition.x), y: CGFloat(cursorPosition.y))
        guard showCursor && viewport.containsCanvasPoint(cursorPoint, viewSize: view.bounds.size) else { return }

        let cursorPass = MTLRenderPassDescriptor()
        cursorPass.colorAttachments[0].texture = drawable.texture
        cursorPass.colorAttachments[0].loadAction = .load
        cursorPass.colorAttachments[0].storeAction = .store

        let cursorEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: cursorPass)!
        cursorEncoder.setRenderPipelineState(cursorPipelineState)
        cursorEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

        let ndcCenterX = (cursorPosition.x / max(viewW, 1)) * 2 - 1
        let ndcCenterY = (cursorPosition.y / max(viewH, 1)) * 2 - 1
        let canvasToViewScale = Float(viewport.fittedScale(viewSize: view.bounds.size) * viewport.zoom)
        let cursorRadiusPixels = maxBrushSize * canvasToViewScale
        let ndcRadiusX = cursorRadiusPixels / max(viewW, 1) * 2
        let ndcRadiusY = cursorRadiusPixels / max(viewH, 1) * 2

        var cursorUniforms = CursorUniforms(
            center: SIMD2<Float>(ndcCenterX, ndcCenterY),
            radius: SIMD2<Float>(ndcRadiusX, ndcRadiusY),
            show: 1.0
        )
        cursorEncoder.setVertexBytes(&cursorUniforms, length: MemoryLayout<CursorUniforms>.stride, index: 1)
        cursorEncoder.setFragmentBytes(&cursorUniforms, length: MemoryLayout<CursorUniforms>.stride, index: 1)
        if let texture = activeLayer?.texture {
            cursorEncoder.setFragmentTexture(texture, index: 0)
        }
        cursorEncoder.setFragmentSamplerState(displaySamplerState, index: 0)
        cursorEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        cursorEncoder.endEncoding()
    }

    func uploadInstances() {
        guard let buffer = instanceBuffer else { return }
        let count = min(newDabs.count, maxDabs)
        let byteCount = count * MemoryLayout<DabInstance>.stride

        newDabs.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else { return }
            memcpy(buffer.contents(), source, byteCount)
        }
    }

    // MARK: - Coordinate Conversion
    func normalizePoint(_ point: CGPoint, in view: MTKView) -> SIMD2<Float> {
        viewport.canvasPoint(from: point, viewSize: view.bounds.size)
    }

    func clampedCanvasPoint(_ point: SIMD2<Float>) -> SIMD2<Float> {
        viewport.clampedCanvasPoint(point)
    }

    func isPointOverCanvas(_ point: CGPoint, in view: MTKView) -> Bool {
        viewport.containsCanvasPoint(point, viewSize: view.bounds.size)
    }

    // MARK: - Viewport Controls
    func panViewport(by delta: CGSize) {
        viewport.panBy(delta)
        objectWillChange.send()
    }

    func zoomViewport(by factor: CGFloat, around point: CGPoint, in view: MTKView) {
        viewport.zoomBy(factor, around: point, viewSize: view.bounds.size)
        objectWillChange.send()
    }

    func fitViewportToView() {
        viewport.fitToView()
        objectWillChange.send()
    }

    // MARK: - Layers
    func addLayer() {
        guard layers.count < maxLayers, let texture = makeCanvasTexture() else { return }
        let layer = CanvasLayer(
            name: "Layer \(layers.count + 1)",
            texture: texture,
            history: CanvasHistory(device: device, canvasTexture: texture, maxLevels: 20)
        )
        clear(texture: texture, color: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0), using: commandQueue)
        layer.history.saveSnapshot(from: texture, using: commandQueue)
        layers.append(layer)
        selectedLayerIndex = layers.count - 1
        refreshLayerInfos()
        objectWillChange.send()
    }

    func selectLayer(at index: Int) {
        guard index >= 0 && index < layers.count else { return }
        selectedLayerIndex = index
        objectWillChange.send()
    }

    func toggleLayerVisibility(at index: Int) {
        guard index >= 0 && index < layers.count else { return }
        layers[index].isVisible.toggle()
        refreshLayerInfos()
        objectWillChange.send()
    }

    func setLayerOpacity(_ opacity: Float, at index: Int) {
        guard index >= 0 && index < layers.count else { return }
        layers[index].opacity = min(max(opacity, 0), 1)
        refreshLayerInfos()
        objectWillChange.send()
    }

    func canDeleteLayer(at index: Int) -> Bool {
        index >= 0 && index < layers.count && layers.count > 1 && !brushEngine.isStrokeActive
    }

    func deleteLayer(at index: Int) {
        guard canDeleteLayer(at: index) else { return }
        layers.remove(at: index)
        if selectedLayerIndex >= layers.count {
            selectedLayerIndex = layers.count - 1
        } else if selectedLayerIndex > index {
            selectedLayerIndex -= 1
        }
        newDabs.removeAll()
        brushEngine.resetStroke()
        refreshLayerInfos()
        objectWillChange.send()
    }

    private func refreshLayerInfos() {
        layerInfos = layers.map(\.info)
    }
}
