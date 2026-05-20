# Repository Guidelines

## Project Structure & Module Organization

This is a macOS SwiftUI and Metal drawing app. Source files live at the repository root and are listed in `project.yml`.

- `BrushEngineApp.swift`: app entry point.
- `ContentView.swift`: SwiftUI toolbar, controls, and view composition.
- `MetalBrushView.swift`: AppKit/Metal bridge and input handling.
- `BrushRenderer.swift`: rendering state, brush behavior, undo/redo, and canvas operations.
- `Shaders.metal`: Metal shaders.
- `Info.plist`: bundle metadata.
- `brush-stroke-isolated.png`: brush preset asset.
- `MetalBrushEngine.xcodeproj/`: generated Xcode project. Prefer updating `project.yml`, then regenerate.

There is no test target or assets folder yet. Add reusable assets under `Assets/` and include them in `project.yml`.

## Build, Test, and Development Commands

- `xcodegen generate`: regenerate `MetalBrushEngine.xcodeproj` from `project.yml`. Requires XcodeGen.
- `open MetalBrushEngine.xcodeproj`: open the app in Xcode.
- `xcodebuild -project MetalBrushEngine.xcodeproj -scheme MetalBrushEngine -configuration Debug build`: build from the command line.
- `xcodebuild -project MetalBrushEngine.xcodeproj -scheme MetalBrushEngine -configuration Debug clean`: remove build artifacts.

No automated tests are configured yet. If a test target is added, document its `xcodebuild test` command.

## Coding Style & Naming Conventions

Use Swift 5.9 and macOS 13 APIs as configured in `project.yml`. Follow standard Swift conventions: 4-space indentation, `PascalCase` for types, `camelCase` for properties/functions, and concise behavior-focused method names. Keep SwiftUI views focused on UI state and composition; keep Metal resource management and draw logic in renderer/view bridge types.

For Metal code, keep shader function names descriptive and aligned with the Swift-side pipeline setup.

## Testing Guidelines

When adding tests, create a `MetalBrushEngineTests` target under `Tests/MetalBrushEngineTests/`. Name test files after the type or behavior under test, such as `BrushRendererTests.swift`. Prefer deterministic tests for brush math, canvas bounds, undo/redo state, and coordinate mapping. Verify shader output manually in Xcode.

## Commit & Pull Request Guidelines

Recent history uses short imperative summaries, often with prefixes such as `feat:` and `fix:`. Continue that style, for example `feat: add brush opacity control` or `fix: clamp canvas input bounds`.

Pull requests should include a concise description, reason for the change, manual test notes, and screenshots or screen recordings for visible UI/rendering changes. Link related issues when applicable and call out `project.yml` or asset changes.

## Agent-Specific Instructions

Do not edit generated Xcode project files by hand unless the change cannot be represented in `project.yml`. Keep generated trace/build artifacts out of commits.
