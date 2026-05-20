import AppKit
import Metal

final class BrushPresetStore {
    private let device: MTLDevice
    private let fileManager: FileManager

    init(device: MTLDevice, fileManager: FileManager = .default) {
        self.device = device
        self.fileManager = fileManager
    }

    func loadPresets() -> [BrushPreset] {
        let brushesDir = brushesDirectoryURL()
        try? fileManager.createDirectory(at: brushesDir, withIntermediateDirectories: true)

        let contents = (try? fileManager.contentsOfDirectory(at: brushesDir, includingPropertiesForKeys: nil)) ?? []
        let pngFiles = contents.filter { $0.pathExtension.lowercased() == "png" }

        if pngFiles.isEmpty {
            ensureDefaultBrushesExist(in: brushesDir)
        }

        let allPngs = (try? fileManager.contentsOfDirectory(at: brushesDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        return allPngs.compactMap { pngURL in
            guard let texture = loadTexture(from: pngURL),
                  let thumbnail = NSImage(contentsOf: pngURL) else { return nil }

            return BrushPreset(
                name: pngURL.deletingPathExtension().lastPathComponent,
                texture: texture,
                thumbnail: thumbnail,
                settings: loadSettings(from: sidecarURL(for: pngURL))
            )
        }
    }

    func saveSettings(_ settings: BrushSettings, for preset: BrushPreset) {
        let pngURL = brushesDirectoryURL().appendingPathComponent("\(preset.name).png")
        let jsonURL = sidecarURL(for: pngURL)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: jsonURL)
        }
    }

    private func brushesDirectoryURL() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MetalBrushEngine", isDirectory: true)
        return appDir.appendingPathComponent("Brushes", isDirectory: true)
    }

    private func sidecarURL(for pngURL: URL) -> URL {
        pngURL.deletingPathExtension().appendingPathExtension("json")
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
                let dist = sqrt(dx * dx + dy * dy)
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
}
