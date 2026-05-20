import MetalKit
import SwiftUI

struct BrushPoint {
    var position: SIMD2<Float>
    var pressure: Float
    var size: Float
    var tiltX: Float
    var tiltY: Float
    var azimuth: Float
    var timestamp: Float
    var rotation: Float
}

enum RotationMode: Int, Codable, CaseIterable, Identifiable {
    case followStroke = 0
    case fixed = 1
    case random = 2

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .followStroke: return "Follow Stroke"
        case .fixed: return "Fixed"
        case .random: return "Random"
        }
    }
}

struct BrushSettings: Codable {
    var spacing: Float = 0.15
    var flow: Float = 1.0
    var scatter: Float = 0.0
    var hardness: Float = 0.5
    var softness: Float = 0.0
    var rotationJitter: Float = 0.0
    var tiltInfluence: Float = 0.5
    var smudgeStrength: Float = 0.7
    var isSmudge: Bool = false
    var rotationMode: RotationMode = .followStroke
}

struct BrushPreset: Identifiable {
    let id = UUID()
    let name: String
    let texture: MTLTexture
    let thumbnail: NSImage
    var settings: BrushSettings
}

struct DabInstance {
    var center: SIMD2<Float>
    var size: Float
    var rotation: Float
    var pressure: Float
    var hardness: Float
    var softness: Float
    var smudgeStrength: Float
    var color: SIMD4<Float>
    var tiltScale: SIMD2<Float>
    var flow: Float
    var _pad: Float = 0
}

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

    // MARK: - Brush Presets
    @Published var presets: [BrushPreset] = []
    @Published var selectedPresetIndex: Int = 0

    var activePreset: BrushPreset? {
        guard selectedPresetIndex >= 0 && selectedPresetIndex < presets.count else { return nil }
        return presets[selectedPresetIndex]
    }

    // MARK: - Stroke State
    var newDabs: [DabInstance] = []
    var lastPlacedPoint: BrushPoint?
    var lastSmoothedPoint: BrushPoint?
    var hasPlacedDabs: Bool = false
    var lastStrokeRotation: Float = 0
    let maxDabs = 10000

    // MARK: - Published Brush Parameters
    @Published var brushColor: SIMD3<Float> = SIMD3<Float>(0.365, 0.251, 0.216)
    @Published var maxBrushSize: Float = 30.0
    @Published var minBrushSize: Float = 2.0
    @Published var hardness: Float = 0.5
    @Published var softness: Float = 0.0
    @Published var spacing: Float = 0.15
    @Published var scatter: Float = 0.0
    @Published var rotationJitter: Float = 0.0
    @Published var rotationMode: RotationMode = .followStroke
    @Published var smoothing: Float = 0.3
    @Published var flow: Float = 1.0
    @Published var tiltInfluence: Float = 0.5
    @Published var smudgeStrength: Float = 0.7
    @Published var isSmudge: Bool = false

    // MARK: - Cursor (not @Published — no SwiftUI view reads these)
    var cursorPosition: SIMD2<Float> = .zero
    var showCursor: Bool = false

    // MARK: - Undo / Redo (ring buffer)
    var undoTextures: [MTLTexture] = []
    var undoStart = 0
    var undoEnd = 0
    var redoEnd = 0
    let maxUndoLevels = 20
    var needsSnapshotSave = false

    // MARK: - Internal
    var currentTime: Float = 0

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

        createCanvasTextures()
        setupUndoTextures()
        setupBrushPipeline()
        setupDisplayPipeline()
        setupCursorPipeline()
        setupQuadBuffer()
        setupInstanceBuffer()
        loadBrushPresets()
        setupSamplers()
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
        clearCanvas(skipSnapshot: true)
        saveSnapshot() // Save initial empty canvas as state 0
    }

    func setupUndoTextures() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private

        for _ in 0..<maxUndoLevels {
            if let tex = device.makeTexture(descriptor: descriptor) {
                undoTextures.append(tex)
            }
        }
    }

    func setupBrushPipeline() {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "brushVertex")
        let fragmentFunction = library?.makeFunction(name: "brushFragment")

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

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
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

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride * 2
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
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

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride * 2
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
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

    // MARK: - Brush Preset Loading

    private func brushesDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MetalBrushEngine", isDirectory: true)
        return appDir.appendingPathComponent("Brushes", isDirectory: true)
    }

    private func sidecarURL(for pngURL: URL) -> URL {
        pngURL.deletingPathExtension().appendingPathExtension("json")
    }

    func loadBrushPresets() {
        let brushesDir = brushesDirectoryURL()
        try? FileManager.default.createDirectory(at: brushesDir, withIntermediateDirectories: true)

        let contents = (try? FileManager.default.contentsOfDirectory(at: brushesDir, includingPropertiesForKeys: nil)) ?? []
        let pngFiles = contents.filter { $0.pathExtension.lowercased() == "png" }

        if pngFiles.isEmpty {
            ensureDefaultBrushesExist(in: brushesDir)
        }

        let allPngs = (try? FileManager.default.contentsOfDirectory(at: brushesDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        var loadedPresets: [BrushPreset] = []
        for pngURL in allPngs {
            guard let texture = loadTexture(from: pngURL),
                  let thumbnail = NSImage(contentsOf: pngURL) else { continue }
            let settings = loadSettings(from: sidecarURL(for: pngURL))
            let name = pngURL.deletingPathExtension().lastPathComponent
            let preset = BrushPreset(
                name: name,
                texture: texture,
                thumbnail: thumbnail,
                settings: settings
            )
            loadedPresets.append(preset)
        }

        presets = loadedPresets
        if !presets.isEmpty {
            selectPreset(at: 0)
        }
    }

    func selectPreset(at index: Int) {
        guard index >= 0 && index < presets.count else { return }
        selectedPresetIndex = index
        let settings = presets[index].settings
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
        objectWillChange.send()
    }

    func saveCurrentSettingsToSidecar() {
        guard selectedPresetIndex >= 0 && selectedPresetIndex < presets.count else { return }
        let brushesDir = brushesDirectoryURL()
        let pngURL = brushesDir.appendingPathComponent("\(presets[selectedPresetIndex].name).png")
        let jsonURL = sidecarURL(for: pngURL)
        let settings = BrushSettings(
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
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: jsonURL)
        }
    }

    private func loadSettings(from url: URL) -> BrushSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(BrushSettings.self, from: data) else {
            return BrushSettings()
        }
        return settings
    }

    private func loadTexture(from url: URL) -> MTLTexture? {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var brushPixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<width * height {
            let r = pixels[i * 4 + 0]
            let g = pixels[i * 4 + 1]
            let b = pixels[i * 4 + 2]
            let a = pixels[i * 4 + 3]
            let gray = UInt8((Int(r) + Int(g) + Int(b)) / 3)
            let finalAlpha = a < 255 ? UInt8((Int(gray) * Int(a)) / 255) : gray
            brushPixels[i * 4 + 0] = 255
            brushPixels[i * 4 + 1] = 255
            brushPixels[i * 4 + 2] = 255
            brushPixels[i * 4 + 3] = finalAlpha
        }

        return createTexture(from: brushPixels, width: width, height: height)
    }

    private func createTexture(from pixels: [UInt8], width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )
        return texture
    }

    // MARK: - Default Brush Generation

    private func ensureDefaultBrushesExist(in directory: URL) {
        let defaults: [(name: String, pixels: [UInt8], size: Int, settings: BrushSettings)] = [
            ("Default", generateSoftRoundPixels(size: 256), 256, BrushSettings())
        ]

        for item in defaults {
            let pngURL = directory.appendingPathComponent("\(item.name).png")
            let jsonURL = directory.appendingPathComponent("\(item.name).json")
            savePNG(pixels: item.pixels, size: item.size, to: pngURL)
            if let data = try? JSONEncoder().encode(item.settings) {
                try? data.write(to: jsonURL)
            }
        }
    }

    private func savePNG(pixels: [UInt8], size: Int, to url: URL) {
        var mutablePixels = pixels
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: CFDataCreate(nil, &mutablePixels, pixels.count)!) else { return }
        guard let cgImage = CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        try? pngData.write(to: url)
    }

    private func generateSoftRoundPixels(size: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let center = Float(size - 1) / 2.0
        let radius = center

        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) - center
                let dy = Float(y) - center
                let dist = sqrt(dx*dx + dy*dy)
                let t = min(dist / radius, 1.0)
                let alpha = exp(-t * t * 3.0)

                let idx = (y * size + x) * 4
                pixels[idx + 0] = 255
                pixels[idx + 1] = 255
                pixels[idx + 2] = 255
                pixels[idx + 3] = UInt8(min(alpha * 255.0, 255.0))
            }
        }
        return pixels
    }

    // MARK: - Snapshot / Undo / Redo (ring buffer)

    private func blitCanvas(to destination: MTLTexture) {
        guard let canvas = canvasTexture else { return }
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
        blitEncoder.copy(
            from: canvas,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: canvas.width, height: canvas.height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
    }

    private func restore(from source: MTLTexture) {
        guard let canvas = canvasTexture else { return }
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
        blitEncoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: canvas,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
    }

    private func pushSnapshotState() {
        redoEnd = undoEnd
        undoEnd += 1
        if undoEnd - undoStart > undoTextures.count {
            undoStart += 1
        }
    }

    func saveSnapshot() {
        guard !undoTextures.isEmpty else { return }
        let index = undoEnd % undoTextures.count
        blitCanvas(to: undoTextures[index])
        pushSnapshotState()
    }

    func saveSnapshot(to commandBuffer: MTLCommandBuffer) {
        guard !undoTextures.isEmpty else { return }
        let index = undoEnd % undoTextures.count
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
        blitEncoder.copy(
            from: canvasTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: canvasTexture.width, height: canvasTexture.height, depth: 1),
            to: undoTextures[index],
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        pushSnapshotState()
    }

    func undo() {
        guard lastPlacedPoint == nil else { return }
        guard undoEnd > undoStart + 1 else { return }
        undoEnd -= 1
        let index = (undoEnd - 1) % undoTextures.count
        restore(from: undoTextures[index])
        objectWillChange.send()
    }

    func redo() {
        guard lastPlacedPoint == nil else { return }
        guard undoEnd < redoEnd else { return }
        let index = undoEnd % undoTextures.count
        restore(from: undoTextures[index])
        undoEnd += 1
        objectWillChange.send()
    }

    var canUndo: Bool { undoEnd > undoStart + 1 && lastPlacedPoint == nil }
    var canRedo: Bool { undoEnd < redoEnd && lastPlacedPoint == nil }

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
        lastPlacedPoint = nil
        lastSmoothedPoint = nil
        hasPlacedDabs = false
        lastStrokeRotation = 0

        if !skipSnapshot {
            saveSnapshot() // Save the now-empty canvas
        }
    }

    // MARK: - Stroke Lifecycle
    func startStroke(with point: BrushPoint) {
        lastSmoothedPoint = point
        lastPlacedPoint = point
        hasPlacedDabs = false
        currentTime = point.timestamp
        lastStrokeRotation = point.rotation

        // Place initial dab
        addDab(at: point)
    }

    func continueStroke(with point: BrushPoint) {
        guard let lastSmoothed = lastSmoothedPoint else { return }
        guard let lastPlaced = lastPlacedPoint else { return }

        // Interpret smoothing as stabilization: 0 is raw input, 0.9 is heavily stabilized.
        let stabilization = min(max(smoothing, 0), 0.95)
        let inputWeight = 1.0 - stabilization
        let smoothedPosition = SIMD2<Float>(
            lastSmoothed.position.x * stabilization + point.position.x * inputWeight,
            lastSmoothed.position.y * stabilization + point.position.y * inputWeight
        )

        let dx = smoothedPosition.x - lastSmoothed.position.x
        let dy = smoothedPosition.y - lastSmoothed.position.y
        let movementDistance = hypot(dx, dy)
        let rotation = movementDistance > 0.001 ? atan2(dy, dx) : lastStrokeRotation
        lastStrokeRotation = rotation

        let smoothedPoint = BrushPoint(
            position: smoothedPosition,
            pressure: lastSmoothed.pressure * stabilization + point.pressure * inputWeight,
            size: lastSmoothed.size * stabilization + point.size * inputWeight,
            tiltX: lastSmoothed.tiltX * stabilization + point.tiltX * inputWeight,
            tiltY: lastSmoothed.tiltY * stabilization + point.tiltY * inputWeight,
            azimuth: lastSmoothed.azimuth * stabilization + point.azimuth * inputWeight,
            timestamp: point.timestamp,
            rotation: rotation
        )

        // Interpolate dabs from the last actual dab so leftover distance carries across events.
        interpolateDabs(from: lastPlaced, to: smoothedPoint)

        lastSmoothedPoint = smoothedPoint
    }

    func endStroke() {
        if !hasPlacedDabs, let last = lastPlacedPoint {
            addDab(at: last)
        }
        lastPlacedPoint = nil
        lastSmoothedPoint = nil
        hasPlacedDabs = false
        lastStrokeRotation = 0
        needsSnapshotSave = true
    }

    // MARK: - Dab Placement
    func interpolateDabs(from start: BrushPoint, to end: BrushPoint) {
        var current = start
        var remaining = distance(from: current.position, to: end.position)

        while remaining > 0.1 && newDabs.count < maxDabs {
            let avgSize = (current.size + end.size) / 2.0
            let stepSize = max(1.0, avgSize * spacing)
            guard remaining >= stepSize else { break }

            let t = stepSize / remaining
            let rotation = atan2(end.position.y - current.position.y, end.position.x - current.position.x)
            let point = interpolatedPoint(from: current, to: end, t: t, rotation: rotation)
            addDab(at: point)

            current = point
            remaining = distance(from: current.position, to: end.position)
        }
    }

    func addDab(at point: BrushPoint) {
        guard newDabs.count < maxDabs else { return }

        // Apply scatter
        var position = point.position
        if scatter > 0 {
            let jitterX = Float.random(in: -1...1) * scatter * point.size * 0.5
            let jitterY = Float.random(in: -1...1) * scatter * point.size * 0.5
            position.x += jitterX
            position.y += jitterY
        }
        position.x = min(max(position.x, 0), Float(canvasSize.width))
        position.y = min(max(position.y, 0), Float(canvasSize.height))

        // Determine base rotation based on mode
        var rotation: Float
        switch rotationMode {
        case .fixed:
            rotation = 0
        case .random:
            rotation = Float.random(in: 0...(2 * Float.pi))
        case .followStroke:
            rotation = point.rotation
        }

        // Apply rotation jitter
        if rotationJitter > 0 {
            rotation += Float.random(in: -1...1) * rotationJitter * Float.pi
        }

        let size = point.size
        let pressure = point.pressure

        // Tilt elliptical deformation
        var tiltScale = SIMD2<Float>(1.0, 1.0)
        if tiltInfluence > 0 {
            let tiltAmount = sqrt(point.tiltX * point.tiltX + point.tiltY * point.tiltY)
            if tiltAmount > 0.01 {
                let squash = max(0.2, 1.0 - tiltAmount * tiltInfluence)
                let stretch = 1.0 + tiltAmount * tiltInfluence * 0.5
                let tiltAngle = atan2(point.tiltY, point.tiltX)
                rotation = tiltAngle + .pi / 2
                tiltScale = SIMD2<Float>(stretch, squash)
            }
        }

        // Determine smudge strength
        var smudge: Float = 0.0
        if isSmudge {
            smudge = smudgeStrength
        }

        let dab = DabInstance(
            center: position,
            size: size,
            rotation: rotation,
            pressure: pressure,
            hardness: hardness,
            softness: softness,
            smudgeStrength: smudge,
            color: SIMD4<Float>(brushColor, 1.0),
            tiltScale: tiltScale,
            flow: flow
        )

        newDabs.append(dab)
        lastPlacedPoint = point
        hasPlacedDabs = true
    }

    private func distance(from start: SIMD2<Float>, to end: SIMD2<Float>) -> Float {
        hypot(end.x - start.x, end.y - start.y)
    }

    private func interpolatedPoint(from start: BrushPoint, to end: BrushPoint, t: Float, rotation: Float) -> BrushPoint {
        BrushPoint(
            position: SIMD2<Float>(
                start.position.x + (end.position.x - start.position.x) * t,
                start.position.y + (end.position.y - start.position.y) * t
            ),
            pressure: start.pressure + (end.pressure - start.pressure) * t,
            size: start.size + (end.size - start.size) * t,
            tiltX: start.tiltX + (end.tiltX - start.tiltX) * t,
            tiltY: start.tiltY + (end.tiltY - start.tiltY) * t,
            azimuth: start.azimuth + (end.azimuth - start.azimuth) * t,
            timestamp: start.timestamp + (end.timestamp - start.timestamp) * t,
            rotation: rotation
        )
    }

    // MARK: - Rendering
    func render(to view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        guard let canvasTexture = canvasTexture else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!

        // If smudging, backup canvas first
        var needsSmudge = false
        for dab in newDabs {
            if dab.smudgeStrength > 0 {
                needsSmudge = true
                break
            }
        }
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

        // Render brush dabs to canvas
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

        // Save post-stroke state (after dabs are rendered to canvas)
        if needsSnapshotSave {
            saveSnapshot(to: commandBuffer)
            needsSnapshotSave = false
        }

        // Display canvas to view (letterboxed to preserve aspect ratio)
        let viewW = Float(view.bounds.width)
        let viewH = Float(view.bounds.height)
        let canvasAspect = Float(canvasSize.width) / Float(canvasSize.height)
        let viewAspect = viewW / max(viewH, 1)

        var displayScaleX: Float = 1.0
        var displayScaleY: Float = 1.0
        if viewAspect > canvasAspect {
            displayScaleX = canvasAspect / viewAspect
        } else {
            displayScaleY = viewAspect / canvasAspect
        }

        let displayPass = MTLRenderPassDescriptor()
        displayPass.colorAttachments[0].texture = drawable.texture
        displayPass.colorAttachments[0].loadAction = .clear
        displayPass.colorAttachments[0].storeAction = .store
        displayPass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)

        let displayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: displayPass)!
        displayEncoder.setRenderPipelineState(displayPipelineState)
        displayEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        var displayScale = SIMD2<Float>(displayScaleX, displayScaleY)
        displayEncoder.setVertexBytes(&displayScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        displayEncoder.setFragmentTexture(canvasTexture, index: 0)
        displayEncoder.setFragmentSamplerState(displaySamplerState, index: 0)
        displayEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        displayEncoder.endEncoding()

        // Cursor overlay pass (small quad, only where cursor is visible over the canvas)
        let visibleCanvas = visibleCanvasFrame(for: view.bounds.size)
        let cursorVisible = showCursor
            && cursorPosition.x >= Float(visibleCanvas.minX)
            && cursorPosition.x <= Float(visibleCanvas.maxX)
            && cursorPosition.y >= Float(visibleCanvas.minY)
            && cursorPosition.y <= Float(visibleCanvas.maxY)
        if cursorVisible {
            let cursorPass = MTLRenderPassDescriptor()
            cursorPass.colorAttachments[0].texture = drawable.texture
            cursorPass.colorAttachments[0].loadAction = .load
            cursorPass.colorAttachments[0].storeAction = .store

            let cursorEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: cursorPass)!
            cursorEncoder.setRenderPipelineState(cursorPipelineState)
            cursorEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

            // Pass center and radius in NDC [-1,1] space
            let ndcCenterX = (cursorPosition.x / max(viewW, 1)) * 2 - 1
            let ndcCenterY = (cursorPosition.y / max(viewH, 1)) * 2 - 1
            let canvasToViewScale = Float(visibleCanvas.width) / Float(canvasSize.width)
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

        commandBuffer.present(drawable)
        commandBuffer.commit()
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
        let visibleCanvas = visibleCanvasFrame(for: view.bounds.size)
        let relX = (point.x - visibleCanvas.minX) / max(visibleCanvas.width, 1)
        let relY = (point.y - visibleCanvas.minY) / max(visibleCanvas.height, 1)
        let canvasX = Float(relX) * Float(canvasSize.width)
        let canvasY = Float(relY) * Float(canvasSize.height)

        return SIMD2<Float>(canvasX, canvasY)
    }

    func clampedCanvasPoint(_ point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(
            min(max(point.x, 0), Float(canvasSize.width)),
            min(max(point.y, 0), Float(canvasSize.height))
        )
    }

    func isPointOverCanvas(_ point: CGPoint, in view: MTKView) -> Bool {
        let visibleCanvas = visibleCanvasFrame(for: view.bounds.size)
        return point.x >= visibleCanvas.minX
            && point.x <= visibleCanvas.maxX
            && point.y >= visibleCanvas.minY
            && point.y <= visibleCanvas.maxY
    }

    private func visibleCanvasFrame(for viewSize: CGSize) -> CGRect {
        let viewW = max(viewSize.width, 1)
        let viewH = max(viewSize.height, 1)
        let canvasAspect = canvasSize.width / canvasSize.height
        let viewAspect = viewW / viewH

        if viewAspect > canvasAspect {
            let visibleCanvasW = viewH * canvasAspect
            let barW = (viewW - visibleCanvasW) / 2
            return CGRect(x: barW, y: 0, width: visibleCanvasW, height: viewH)
        } else {
            let visibleCanvasH = viewW / canvasAspect
            let barH = (viewH - visibleCanvasH) / 2
            return CGRect(x: 0, y: barH, width: viewW, height: visibleCanvasH)
        }
    }
}
