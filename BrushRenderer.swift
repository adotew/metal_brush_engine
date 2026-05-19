import MetalKit
import SwiftUI

enum BrushType: Int, CaseIterable, Identifiable {
    case softRound = 0
    case hardRound = 1
    case flat = 2
    case textured = 3
    case smudge = 4

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .softRound: return "Soft"
        case .hardRound: return "Hard"
        case .flat: return "Flat"
        case .textured: return "Texture"
        case .smudge: return "Smudge"
        }
    }
}

struct BrushPoint {
    var position: SIMD2<Float>
    var pressure: Float
    var size: Float
    var tiltX: Float
    var tiltY: Float
    var azimuth: Float
    var velocity: Float
    var timestamp: Float
    var rotation: Float
}

struct DabInstance {
    var center: SIMD2<Float>
    var size: Float
    var rotation: Float
    var pressure: Float
    var hardness: Float
    var softness: Float
    var smudgeStrength: Float
    var brushType: Int32
    var color: SIMD3<Float>
    var _pad: Float = 0
}

class BrushRenderer: NSObject, ObservableObject {
    // MARK: - Metal Resources
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var brushPipelineState: MTLRenderPipelineState!
    var displayPipelineState: MTLRenderPipelineState!
    var quadVertexBuffer: MTLBuffer!
    var instanceBuffer: MTLBuffer!
    var canvasTexture: MTLTexture!
    var canvasBackupTexture: MTLTexture!
    var brushTextures: [MTLTexture] = []
    var samplerState: MTLSamplerState!
    var displaySamplerState: MTLSamplerState!

    // MARK: - Canvas
    let canvasSize = CGSize(width: 2000, height: 2000)

    // MARK: - Stroke State
    var newDabs: [DabInstance] = []
    var lastPlacedPoint: BrushPoint?
    var lastSmoothedPoint: BrushPoint?
    var hasPlacedDabs: Bool = false
    let maxDabs = 10000

    // MARK: - Published Brush Parameters
    @Published var brushColor: SIMD3<Float> = SIMD3<Float>(0.365, 0.251, 0.216)
    @Published var brushType: BrushType = .softRound
    @Published var maxBrushSize: Float = 30.0
    @Published var minBrushSize: Float = 2.0
    @Published var hardness: Float = 0.5
    @Published var softness: Float = 0.0
    @Published var smudgeStrength: Float = 0.7
    @Published var spacing: Float = 0.15
    @Published var scatter: Float = 0.0
    @Published var rotationJitter: Float = 0.0
    @Published var smoothing: Float = 0.3

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
        setupBrushPipeline()
        setupDisplayPipeline()
        setupQuadBuffer()
        setupInstanceBuffer()
        generateBrushTextures()
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
        clearCanvas()
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

    // MARK: - Brush Texture Generation
    func generateBrushTextures(size: Int = 256) {
        brushTextures = [
            generateSoftRoundTexture(size: size),
            generateHardRoundTexture(size: size),
            generateFlatTexture(size: size),
            generateTexturedTexture(size: size)
        ]
    }

    func generateSoftRoundTexture(size: Int) -> MTLTexture {
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

        return createTexture(from: pixels, size: size)
    }

    func generateHardRoundTexture(size: Int) -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let center = Float(size - 1) / 2.0
        let radius = center
        let innerRadius = radius * 0.6

        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) - center
                let dy = Float(y) - center
                let dist = sqrt(dx*dx + dy*dy)

                var alpha: Float
                if dist <= innerRadius {
                    alpha = 1.0
                } else if dist >= radius {
                    alpha = 0.0
                } else {
                    let t = (dist - innerRadius) / (radius - innerRadius)
                    alpha = 0.5 * (1.0 + cos(t * Float.pi))
                }

                let idx = (y * size + x) * 4
                pixels[idx + 0] = 255
                pixels[idx + 1] = 255
                pixels[idx + 2] = 255
                pixels[idx + 3] = UInt8(min(alpha * 255.0, 255.0))
            }
        }

        return createTexture(from: pixels, size: size)
    }

    func generateFlatTexture(size: Int) -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let center = Float(size - 1) / 2.0
        let radiusX = center * 0.9
        let radiusY = center * 0.35

        for y in 0..<size {
            for x in 0..<size {
                let dx = (Float(x) - center) / radiusX
                let dy = (Float(y) - center) / radiusY
                let dist = sqrt(dx*dx + dy*dy)
                let t = min(dist, 1.0)
                var alpha = exp(-t * t * 3.0)

                // Add bristle lines
                let lineFreq: Float = 20.0
                let linePattern = abs(sin((Float(x) / Float(size)) * Float.pi * lineFreq))
                if dist < 0.9 {
                    alpha *= 0.85 + 0.15 * linePattern
                }

                let idx = (y * size + x) * 4
                pixels[idx + 0] = 255
                pixels[idx + 1] = 255
                pixels[idx + 2] = 255
                pixels[idx + 3] = UInt8(min(alpha * 255.0, 255.0))
            }
        }

        return createTexture(from: pixels, size: size)
    }

    func generateTexturedTexture(size: Int) -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let center = Float(size - 1) / 2.0
        let radius = center

        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) - center
                let dy = Float(y) - center
                let dist = sqrt(dx*dx + dy*dy)
                let t = min(dist / radius, 1.0)
                var alpha = exp(-t * t * 2.5)

                // Noise modulation
                let noise = hash(x, y)
                alpha *= 0.7 + 0.6 * noise

                let idx = (y * size + x) * 4
                pixels[idx + 0] = 255
                pixels[idx + 1] = 255
                pixels[idx + 2] = 255
                pixels[idx + 3] = UInt8(min(max(alpha * 255.0, 0.0), 255.0))
            }
        }

        return createTexture(from: pixels, size: size)
    }

    func createTexture(from pixels: [UInt8], size: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = .shaderRead

        let texture = device.makeTexture(descriptor: descriptor)!
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: size * 4
        )
        return texture
    }

    func hash(_ x: Int, _ y: Int) -> Float {
        var h = x &* 374761393 &+ y &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        return Float(h & 0x7fffffff) / Float(0x7fffffff)
    }

    // MARK: - Canvas Operations
    func clearCanvas() {
        guard let canvasTexture = canvasTexture else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = canvasTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)

        let renderEncoder = commandBuffer?.makeRenderCommandEncoder(descriptor: passDescriptor)
        renderEncoder?.endEncoding()
        commandBuffer?.commit()

        newDabs.removeAll()
        lastPlacedPoint = nil
        lastSmoothedPoint = nil
        hasPlacedDabs = false
    }

    // MARK: - Stroke Lifecycle
    func startStroke(with point: BrushPoint) {
        lastSmoothedPoint = point
        lastPlacedPoint = point
        hasPlacedDabs = false
        currentTime = point.timestamp

        // Place initial dab
        addDab(at: point)
    }

    func continueStroke(with point: BrushPoint) {
        guard let lastSmoothed = lastSmoothedPoint else { return }

        // Smooth the input
        let smoothingFactor = smoothing
        let smoothedPosition = SIMD2<Float>(
            lastSmoothed.position.x * (1.0 - smoothingFactor) + point.position.x * smoothingFactor,
            lastSmoothed.position.y * (1.0 - smoothingFactor) + point.position.y * smoothingFactor
        )

        let timeDelta = point.timestamp - lastSmoothed.timestamp
        let velocity = timeDelta > 0 ? hypot(point.position.x - lastSmoothed.position.x, point.position.y - lastSmoothed.position.y) / timeDelta : 0.0

        let dx = smoothedPosition.x - lastSmoothed.position.x
        let dy = smoothedPosition.y - lastSmoothed.position.y
        let rotation = atan2(dy, dx)

        let smoothedPoint = BrushPoint(
            position: smoothedPosition,
            pressure: lastSmoothed.pressure * (1.0 - smoothingFactor) + point.pressure * smoothingFactor,
            size: point.size,
            tiltX: point.tiltX,
            tiltY: point.tiltY,
            azimuth: point.azimuth,
            velocity: velocity,
            timestamp: point.timestamp,
            rotation: rotation
        )

        // Interpolate dabs between last placed and smoothed
        interpolateDabs(from: lastPlacedPoint!, to: smoothedPoint)

        lastSmoothedPoint = smoothedPoint
    }

    func endStroke() {
        if !hasPlacedDabs, let last = lastPlacedPoint {
            addDab(at: last)
        }
        lastPlacedPoint = nil
        lastSmoothedPoint = nil
        hasPlacedDabs = false
    }

    // MARK: - Dab Placement
    func interpolateDabs(from start: BrushPoint, to end: BrushPoint) {
        let distance = hypot(end.position.x - start.position.x, end.position.y - start.position.y)
        let avgSize = (start.size + end.size) / 2.0
        let stepSize = max(1.0, avgSize * spacing)

        guard distance > 0.1 else { return }

        let numSteps = max(1, Int(floor(distance / stepSize)))

        for i in 1...numSteps {
            let t = Float(i) / Float(numSteps)
            let pos = SIMD2<Float>(
                start.position.x + (end.position.x - start.position.x) * t,
                start.position.y + (end.position.y - start.position.y) * t
            )
            let pressure = start.pressure + (end.pressure - start.pressure) * t
            let size = start.size + (end.size - start.size) * t
            let rotation = start.rotation + (end.rotation - start.rotation) * t

            let point = BrushPoint(
                position: pos,
                pressure: pressure,
                size: size,
                tiltX: start.tiltX + (end.tiltX - start.tiltX) * t,
                tiltY: start.tiltY + (end.tiltY - start.tiltY) * t,
                azimuth: start.azimuth + (end.azimuth - start.azimuth) * t,
                velocity: start.velocity + (end.velocity - start.velocity) * t,
                timestamp: start.timestamp + (end.timestamp - start.timestamp) * t,
                rotation: rotation
            )

            addDab(at: point)
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

        // Apply rotation jitter
        var rotation = point.rotation
        if rotationJitter > 0 {
            rotation += Float.random(in: -1...1) * rotationJitter * Float.pi
        }

        // For flat and textured brushes, add some organic variation based on velocity
        var size = point.size
        if brushType == .flat || brushType == .textured {
            size *= 1.0 - min(point.velocity * 0.001, 0.3)
        }

        // Determine smudge strength
        var smudge: Float = 0.0
        if brushType == .smudge {
            smudge = smudgeStrength
        }

        let dab = DabInstance(
            center: position,
            size: size,
            rotation: rotation,
            pressure: point.pressure,
            hardness: hardness,
            softness: softness,
            smudgeStrength: smudge,
            brushType: Int32(brushType.rawValue),
            color: brushColor
        )

        newDabs.append(dab)
        lastPlacedPoint = point
        hasPlacedDabs = true
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
            for (i, texture) in brushTextures.enumerated() {
                renderEncoder.setFragmentTexture(texture, index: i)
            }
            renderEncoder.setFragmentTexture(canvasBackupTexture, index: 4)
            renderEncoder.setFragmentSamplerState(samplerState, index: 0)

            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
            renderEncoder.endEncoding()

            newDabs.removeAll()
        }

        // Display canvas to view
        let displayPass = MTLRenderPassDescriptor()
        displayPass.colorAttachments[0].texture = drawable.texture
        displayPass.colorAttachments[0].loadAction = .clear
        displayPass.colorAttachments[0].storeAction = .store
        displayPass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)

        let displayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: displayPass)!
        displayEncoder.setRenderPipelineState(displayPipelineState)
        displayEncoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        displayEncoder.setFragmentTexture(canvasTexture, index: 0)
        displayEncoder.setFragmentSamplerState(displaySamplerState, index: 0)
        displayEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        displayEncoder.endEncoding()

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
        let scaleX = Float(canvasSize.width) / Float(max(view.bounds.width, 1))
        let scaleY = Float(canvasSize.height) / Float(max(view.bounds.height, 1))
        let canvasX = Float(point.x) * scaleX
        let canvasY = Float(point.y) * scaleY
        return SIMD2<Float>(canvasX, canvasY)
    }
}
