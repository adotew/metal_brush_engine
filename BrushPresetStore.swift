import AppKit
import Metal

final class BrushPresetStore {
    private let device: MTLDevice
    private let fileManager: FileManager
    private let brushesDirectoryOverride: URL?
    private let builtInBrushNames: Set<String> = ["Default", "Soft Round", "Studio Pen", "Wet Paint", "Smudge", "Soft Eraser"]

    init(device: MTLDevice, fileManager: FileManager = .default, brushesDirectoryOverride: URL? = nil) {
        self.device = device
        self.fileManager = fileManager
        self.brushesDirectoryOverride = brushesDirectoryOverride
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
            let name = pngURL.deletingPathExtension().lastPathComponent
            let sidecar = loadSidecar(from: sidecarURL(for: pngURL), fallbackName: name)

            return BrushPreset(
                name: name,
                category: sidecar.category,
                isUserEditable: sidecar.isUserCreated || !builtInBrushNames.contains(name),
                texture: texture,
                thumbnail: thumbnail,
                settings: sidecar.settings
            )
        }
    }

    func saveSettings(_ settings: BrushSettings, for preset: BrushPreset) {
        let pngURL = brushesDirectoryURL().appendingPathComponent("\(preset.name).png")
        saveSidecar(
            BrushPresetSidecar(settings: settings, category: preset.category, isUserCreated: preset.isUserEditable),
            to: sidecarURL(for: pngURL)
        )
    }

    func duplicate(_ preset: BrushPreset) -> BrushPreset? {
        let directory = brushesDirectoryURL()
        let sourcePNG = directory.appendingPathComponent("\(preset.name).png")
        let newName = uniqueName(base: "\(preset.name) Copy", in: directory)
        let destinationPNG = directory.appendingPathComponent("\(newName).png")

        do {
            try fileManager.copyItem(at: sourcePNG, to: destinationPNG)
            saveSidecar(
                BrushPresetSidecar(settings: preset.settings, category: preset.category, isUserCreated: true),
                to: sidecarURL(for: destinationPNG)
            )
            return loadPresets().first { $0.name == newName }
        } catch {
            return nil
        }
    }

    func rename(_ preset: BrushPreset, to proposedName: String) -> Bool {
        guard preset.isUserEditable else { return false }
        guard let newName = sanitizedName(proposedName), newName != preset.name else { return false }

        let directory = brushesDirectoryURL()
        let destinationPNG = directory.appendingPathComponent("\(newName).png")
        guard !fileManager.fileExists(atPath: destinationPNG.path) else { return false }

        let sourcePNG = directory.appendingPathComponent("\(preset.name).png")
        let sourceJSON = sidecarURL(for: sourcePNG)
        let destinationJSON = sidecarURL(for: destinationPNG)

        do {
            try fileManager.moveItem(at: sourcePNG, to: destinationPNG)
            if fileManager.fileExists(atPath: sourceJSON.path) {
                try fileManager.moveItem(at: sourceJSON, to: destinationJSON)
            }
            return true
        } catch {
            return false
        }
    }

    func delete(_ preset: BrushPreset) -> Bool {
        guard preset.isUserEditable else { return false }
        let pngURL = brushesDirectoryURL().appendingPathComponent("\(preset.name).png")
        let jsonURL = sidecarURL(for: pngURL)

        do {
            if fileManager.fileExists(atPath: pngURL.path) {
                try fileManager.removeItem(at: pngURL)
            }
            if fileManager.fileExists(atPath: jsonURL.path) {
                try fileManager.removeItem(at: jsonURL)
            }
            return true
        } catch {
            return false
        }
    }

    private func brushesDirectoryURL() -> URL {
        if let brushesDirectoryOverride {
            return brushesDirectoryOverride
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MetalBrushEngine", isDirectory: true)
        return appDir.appendingPathComponent("Brushes", isDirectory: true)
    }

    private func sidecarURL(for pngURL: URL) -> URL {
        pngURL.deletingPathExtension().appendingPathExtension("json")
    }

    private func loadSidecar(from url: URL, fallbackName: String) -> BrushPresetSidecar {
        guard let data = try? Data(contentsOf: url) else {
            return BrushPresetSidecar(settings: defaultSettings(for: fallbackName), category: defaultCategory(for: fallbackName), isUserCreated: false)
        }

        if let sidecar = try? JSONDecoder().decode(BrushPresetSidecar.self, from: data) {
            return sidecar
        }

        if let settings = try? JSONDecoder().decode(BrushSettings.self, from: data) {
            return BrushPresetSidecar(settings: settings, category: defaultCategory(for: fallbackName), isUserCreated: !builtInBrushNames.contains(fallbackName))
        }

        return BrushPresetSidecar(settings: defaultSettings(for: fallbackName), category: defaultCategory(for: fallbackName), isUserCreated: false)
    }

    private func saveSidecar(_ sidecar: BrushPresetSidecar, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sidecar) {
            try? data.write(to: url)
        }
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
            ("Default", generateSoftRoundPixels(size: 256, hardness: 0.3), 256, BrushSettings()),
            ("Soft Round", generateSoftRoundPixels(size: 256, hardness: 0.2), 256, BrushSettings(spacing: 0.12, flow: 0.75, hardness: 0.35, softness: 0.25, rotationMode: .fixed)),
            ("Studio Pen", generateSoftRoundPixels(size: 256, hardness: 0.75), 256, BrushSettings(spacing: 0.06, flow: 1.0, hardness: 0.82, softness: 0.0, rotationMode: .followStroke)),
            ("Wet Paint", generateSoftRoundPixels(size: 256, hardness: 0.45), 256, BrushSettings(spacing: 0.08, flow: 0.55, scatter: 0.06, hardness: 0.42, softness: 0.2, rotationJitter: 0.2)),
            ("Smudge", generateSoftRoundPixels(size: 256, hardness: 0.35), 256, BrushSettings(spacing: 0.04, flow: 0.45, hardness: 0.32, softness: 0.35, smudgeStrength: 0.82, isSmudge: true, rotationMode: .fixed)),
            ("Soft Eraser", generateSoftRoundPixels(size: 256, hardness: 0.25), 256, BrushSettings(spacing: 0.1, flow: 0.9, hardness: 0.28, softness: 0.2, isEraser: true, rotationMode: .fixed))
        ]

        for item in defaults {
            let pngURL = directory.appendingPathComponent("\(item.name).png")
            let jsonURL = directory.appendingPathComponent("\(item.name).json")
            if !fileManager.fileExists(atPath: pngURL.path) {
                savePNG(pixels: item.pixels, size: item.size, to: pngURL)
            }
            if !fileManager.fileExists(atPath: jsonURL.path) {
                saveSidecar(
                    BrushPresetSidecar(settings: item.settings, category: defaultCategory(for: item.name), isUserCreated: false),
                    to: jsonURL
                )
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

    private func generateSoftRoundPixels(size: Int, hardness: Float = 0.3) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let center = Float(size - 1) / 2.0
        let radius = center

        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) - center
                let dy = Float(y) - center
                let dist = sqrt(dx * dx + dy * dy)
                let t = min(dist / radius, 1.0)
                let alpha: Float
                if t < hardness {
                    alpha = 1
                } else {
                    let falloff = (t - hardness) / max(0.01, 1 - hardness)
                    alpha = exp(-falloff * falloff * 3.0)
                }

                let idx = (y * size + x) * 4
                pixels[idx + 0] = 255
                pixels[idx + 1] = 255
                pixels[idx + 2] = 255
                pixels[idx + 3] = UInt8(min(alpha * 255.0, 255.0))
            }
        }
        return pixels
    }

    private func sanitizedName(_ value: String) -> String? {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func uniqueName(base: String, in directory: URL) -> String {
        let cleanedBase = sanitizedName(base) ?? "Brush"
        var candidate = cleanedBase
        var suffix = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent("\(candidate).png").path) {
            candidate = "\(cleanedBase) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func defaultSettings(for name: String) -> BrushSettings {
        switch name {
        case "Studio Pen":
            return BrushSettings(spacing: 0.06, flow: 1.0, hardness: 0.82)
        case "Wet Paint":
            return BrushSettings(spacing: 0.08, flow: 0.55, scatter: 0.06, hardness: 0.42, softness: 0.2, rotationJitter: 0.2)
        case "Smudge":
            return BrushSettings(spacing: 0.04, flow: 0.45, hardness: 0.32, softness: 0.35, smudgeStrength: 0.82, isSmudge: true, rotationMode: .fixed)
        case "Soft Eraser":
            return BrushSettings(spacing: 0.1, flow: 0.9, hardness: 0.28, softness: 0.2, isEraser: true, rotationMode: .fixed)
        default:
            return BrushSettings()
        }
    }

    private func defaultCategory(for name: String) -> BrushCategory {
        switch name {
        case "Studio Pen":
            return .inking
        case "Wet Paint":
            return .painting
        case "Smudge":
            return .smudge
        default:
            return .sketching
        }
    }
}

private struct BrushPresetSidecar: Codable {
    var settings: BrushSettings
    var category: BrushCategory
    var isUserCreated: Bool
}
