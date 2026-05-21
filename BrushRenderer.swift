import MetalKit
import SwiftUI

struct CursorUniforms {
    var center: SIMD2<Float>
    var radius: SIMD2<Float>
    var show: Float
    var padding: Float = 0
}

class BrushRenderer: NSObject, ObservableObject {
    // MARK: - Metal Resources
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var brushPipelineState: MTLRenderPipelineState!
    var displayPipelineState: MTLRenderPipelineState!
    var cursorPipelineState: MTLRenderPipelineState!
    var quadVertexBuffer: MTLBuffer!
    var instanceBuffer: MTLBuffer!
    var canvasTexture: MTLTexture!
    var canvasBackupTexture: MTLTexture!
    var samplerState: MTLSamplerState!
    var displaySamplerState: MTLSamplerState!

    // MARK: - Canvas
    let canvasSize = CGSize(width: 6000, height: 4000)
    private lazy var viewport = CanvasViewport(canvasSize: canvasSize)

    // MARK: - Brush Presets
    @Published var presets: [BrushPreset] = []
    @Published var selectedPresetIndex: Int = 0
    private var presetStore: BrushPresetStore!

    var activePreset: BrushPreset? {
        guard selectedPresetIndex >= 0 && selectedPresetIndex < presets.count else { return nil }
        return presets[selectedPresetIndex]
    }

    // MARK: - Rendering State
    private var brushEngine = BrushEngine()
    private var canvasHistory: CanvasHistory?
    private var newDabs: [DabInstance] = []
    private let maxDabs = 10000
    private var needsSnapshotSave = false

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
        setupDisplayPipeline()
        setupCursorPipeline()
        setupQuadBuffer()
        setupInstanceBuffer()
        setupSamplers()
        loadBrushPresets()
        updateBrushEngineState()
    }

    func createCanvasTextures() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        canvasTexture = device.makeTexture(descriptor: descriptor)
        canvasBackupTexture = device.makeTexture(descriptor: descriptor)
        canvasHistory = CanvasHistory(device: device, canvasTexture: canvasTexture, maxLevels: 20)
        clearCanvas(skipSnapshot: true)
        canvasHistory?.saveSnapshot(from: canvasTexture, using: commandQueue)
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

    func setupDisplayPipeline() {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "displayVertex")
        let fragmentFunction = library?.makeFunction(name: "displayFragment")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = makeQuadVertexDescriptor()
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

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
        apply(settings: presets[index].settings)
        objectWillChange.send()
    }

    func saveCurrentSettingsToSidecar() {
        guard let preset = activePreset else { return }
        presetStore.saveSettings(currentBrushSettings(), for: preset)
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

    // MARK: - Snapshot / Undo / Redo
    func undo() {
        guard !brushEngine.isStrokeActive else { return }
        if canvasHistory?.undo(to: canvasTexture, using: commandQueue) == true {
            objectWillChange.send()
        }
    }

    func redo() {
        guard !brushEngine.isStrokeActive else { return }
        if canvasHistory?.redo(to: canvasTexture, using: commandQueue) == true {
            objectWillChange.send()
        }
    }

    var canUndo: Bool {
        (canvasHistory?.canUndo ?? false) && !brushEngine.isStrokeActive
    }

    var canRedo: Bool {
        (canvasHistory?.canRedo ?? false) && !brushEngine.isStrokeActive
    }

    // MARK: - Canvas Operations
    func clearCanvas(skipSnapshot: Bool = false) {
        guard let canvasTexture = canvasTexture else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = canvasTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)

        let renderEncoder = commandBuffer?.makeRenderCommandEncoder(descriptor: passDescriptor)
        renderEncoder?.endEncoding()
        commandBuffer?.commit()

        newDabs.removeAll()
        brushEngine.resetStroke()

        if !skipSnapshot {
            canvasHistory?.saveSnapshot(from: canvasTexture, using: commandQueue)
        }
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
        guard let canvasTexture = canvasTexture else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!

        let needsSmudge = newDabs.contains { $0.smudgeStrength > 0 }
        if needsSmudge && !newDabs.isEmpty {
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
            blitEncoder.copy(
                from: canvasTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: canvasTexture.width, height: canvasTexture.height, depth: 1),
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
            canvasPass.colorAttachments[0].texture = canvasTexture
            canvasPass.colorAttachments[0].loadAction = .load
            canvasPass.colorAttachments[0].storeAction = .store

            let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: canvasPass)!
            renderEncoder.setRenderPipelineState(brushPipelineState)
            renderEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)

            var viewportSize = SIMD2<Float>(Float(canvasTexture.width), Float(canvasTexture.height))
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
            canvasHistory?.saveSnapshot(from: canvasTexture, using: commandBuffer)
            needsSnapshotSave = false
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
        displayEncoder.setFragmentTexture(canvasTexture, index: 0)
        displayEncoder.setFragmentSamplerState(displaySamplerState, index: 0)
        displayEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        displayEncoder.endEncoding()

        renderCursorIfNeeded(in: view, drawable: drawable, commandBuffer: commandBuffer)

        commandBuffer.present(drawable)
        commandBuffer.commit()
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
        cursorEncoder.setFragmentTexture(canvasTexture, index: 0)
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
}
