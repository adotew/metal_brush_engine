import Metal

final class CanvasHistory {
    private let textures: [MTLTexture]
    private var undoStart = 0
    private var undoEnd = 0
    private var redoEnd = 0

    init(device: MTLDevice, canvasTexture: MTLTexture, maxLevels: Int = 20) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: canvasTexture.pixelFormat,
            width: canvasTexture.width,
            height: canvasTexture.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private

        textures = (0..<maxLevels).compactMap { _ in
            device.makeTexture(descriptor: descriptor)
        }
    }

    var canUndo: Bool {
        undoEnd > undoStart + 1
    }

    var canRedo: Bool {
        undoEnd < redoEnd
    }

    func saveSnapshot(from canvas: MTLTexture, using commandQueue: MTLCommandQueue) {
        guard !textures.isEmpty else { return }
        let index = undoEnd % textures.count
        let commandBuffer = commandQueue.makeCommandBuffer()!
        copy(from: canvas, to: textures[index], using: commandBuffer)
        commandBuffer.commit()
        pushSnapshotState()
    }

    func saveSnapshot(from canvas: MTLTexture, using commandBuffer: MTLCommandBuffer) {
        guard !textures.isEmpty else { return }
        let index = undoEnd % textures.count
        copy(from: canvas, to: textures[index], using: commandBuffer)
        pushSnapshotState()
    }

    func undo(to canvas: MTLTexture, using commandQueue: MTLCommandQueue) -> Bool {
        guard canUndo else { return false }
        undoEnd -= 1
        let index = (undoEnd - 1) % textures.count
        restore(from: textures[index], to: canvas, using: commandQueue)
        return true
    }

    func redo(to canvas: MTLTexture, using commandQueue: MTLCommandQueue) -> Bool {
        guard canRedo else { return false }
        let index = undoEnd % textures.count
        restore(from: textures[index], to: canvas, using: commandQueue)
        undoEnd += 1
        return true
    }

    private func pushSnapshotState() {
        redoEnd = undoEnd
        undoEnd += 1
        if undoEnd - undoStart > textures.count {
            undoStart += 1
        }
    }

    private func restore(from source: MTLTexture, to canvas: MTLTexture, using commandQueue: MTLCommandQueue) {
        let commandBuffer = commandQueue.makeCommandBuffer()!
        copy(from: source, to: canvas, using: commandBuffer)
        commandBuffer.commit()
    }

    private func copy(from source: MTLTexture, to destination: MTLTexture, using commandBuffer: MTLCommandBuffer) {
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
        blitEncoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
    }
}
