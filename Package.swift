// swift-tools-version: 6.2
import PackageDescription

// MermaidKit — native Mermaid diagram parsing, layout, and rendering.
// MermaidLayout is platform-free geometry (parse → layout → scene IR + a
// geometric layout linter). MermaidRender draws with CoreGraphics/CoreText on
// Apple platforms, and — WHEN OPTED IN — with Silica (Cairo/FontConfig) on
// Linux. No JavaScript, no WebView.
//
// ── Why the Silica backend is behind a trait (`LinuxRaster`, default OFF) ──
// Silica pins its Cairo/FontConfig stack to `branch: master` (an unstable,
// non-versioned dependency), and SwiftPM forbids a package consumed via a
// stable version tag (`from: "0.x.0"`) from transitively depending on a
// branch/revision: the downstream resolve fails outright with
//   "mermaidkit depends on an unstable-version package 'silica' …".
// That made every tagged MermaidKit release UNCONSUMABLE by a normal
// `from:`-pinned host (this is what stranded Quoin on 0.10.0).
//
// Even when the Silica products were merely platform-conditioned
// (`.when(platforms: [.linux])`), SwiftPM still RESOLVED (fetched) Silica and
// its entire transitive graph — Cairo, FontConfig, plus the PureSwift/Android,
// Kotlin, JavaScriptKit, swift-java and swift-syntax trees — on ALL platforms,
// including macOS/iOS consumers that never link a single Silica symbol.
//
// Package traits (SwiftPM 6.1+) fix BOTH: the Silica dependency and the
// SilicaCairo/Cairo product links are guarded by the `LinuxRaster` trait, which
// is NOT in the default set. A consumer that doesn't opt in gets a graph with
// ZERO Silica/Cairo/branch dependencies — so a stable `from:` resolve is clean
// on every platform, and Apple hosts never drag in the Linux raster stack.
// Linux users who WANT the native raster backend enable the trait, e.g.
//   .package(url: "…/MermaidKit", from: "0.12.0", traits: ["LinuxRaster"])
// or build/test with `--traits LinuxRaster`.
let package = Package(
    name: "MermaidKit",
    // ── 本地 fork 改动（Panway/MermaidKit，branch: ios16-support）─────────
    // 上游声明 .iOS(.v17) / .macOS(.v14)，这里降到 iOS 16 / macOS 13 /
    // macCatalyst 16，配合宿主项目 MarkdownEditorHy4 的部署目标。
    //
    // 【为什么降到 iOS 16 是安全的】
    // 除下面这一行外，源码只动了 6 个文件（见 Sources/MermaidRender/），
    // 全部是**平台判断**的修正，没有任何降级 API 替换 —— 因为全库源码实测
    // 零 iOS 17 独占 API：无 @available(iOS 17)、无 @Observable / @Bindable、
    // 无 ContentUnavailableView / LabeledContent / Grid / ScrollPosition、
    // 无 symbolEffect / TextRenderer / scrollBounceBehavior；SwiftUI 只有
    // MermaidView.swift 一处，最"新"的用法是 iOS 15 的 .foregroundStyle(.secondary)。
    //
    // 【为什么必须动源码（另加 macCatalyst）】
    // Mac Catalyst 下 `canImport(AppKit)` 仍然为 **true**（`canImport(UIKit)` 也为 true），
    // 于是上游那套裸 `#if canImport(AppKit)` 会全部走进 AppKit 分支，而
    // NSColor / NSFont / NSAppearance / NSGraphicsContext / NSFont.Weight
    // 在 Catalyst 下**一律 unavailable** —— 实测报约 140 个错误、横跨 26 个文件。
    // 判据必须写成 `#if canImport(AppKit) && !canImport(UIKit)`（Catalyst 下为 false）。
    // 根因在 Platform.swift 的三个 typealias，改它一处即消掉绝大部分派生错误。
    //
    // 【精简记录】最初改了 33 个文件，其中 26 个（25 个 DiagramRenderer+*.swift
    // 的 import 分支 + MermaidRenderer+SVG.swift）实测编译上非必需（还原后仍 BUILD
    // SUCCEEDED），已还原成上游，只留必需的 7 个：
    //   Package.swift / Platform.swift（根因）/ DiagramTheme.swift /
    //   DiagramRenderer.swift / DiagramRenderer+PDF.swift /
    //   MermaidRenderer.swift / MermaidView.swift
    // 将来上游跟进时，rebase 这 7 个文件即可。
    platforms: [.macOS(.v13), .iOS(.v16), .macCatalyst(.v16), .visionOS(.v1)],
    products: [
        .library(name: "MermaidLayout", targets: ["MermaidLayout"]),
        .library(name: "MermaidRender", targets: ["MermaidRender"]),
        // The C ABI over the render pipeline — the surface Android's JNI layer
        // calls (Phase 1a of docs/notes/android.md). Depends ONLY on the
        // platform-free MermaidLayout (no CoreGraphics/CoreText, no Silica), so
        // it builds and tests on macOS + Linux today and cross-compiles for the
        // NDK later. Keeps the no-trait graph Silica-free.
        .library(name: "MermaidKitC", targets: ["MermaidKitC"]),
        // A dynamic (shared-library) twin of the same target — the Windows DLL the
        // .NET bridge P/Invokes. `swift build --product MermaidKitCShared` emits
        // `MermaidKitCShared.dll` exporting the `mmk_*` C ABI (with the Swift
        // runtime as dependent DLLs). The static `MermaidKitC` product above is
        // unchanged for macOS/Linux consumers. See windows/.
        .library(name: "MermaidKitCShared", type: .dynamic, targets: ["MermaidKitC"]),
    ],
    traits: [
        .trait(
            name: "LinuxRaster",
            description: "Link the Silica/Cairo raster rendering backend (Linux only). "
                + "Off by default so no-trait consumers keep a Silica-free dependency graph."
        ),
    ],
    dependencies: [
        // Guarded by `LinuxRaster`: when the trait is disabled (the default)
        // these are pruned from resolution entirely — no branch dependency
        // reaches a downstream `from:` consumer, and no Cairo/PureSwift graph is
        // fetched on Apple platforms. `Package.resolved` pins exact commits for
        // reproducibility when the trait IS enabled.
        .package(url: "https://github.com/PureSwift/Silica.git", branch: "master"),
        .package(url: "https://github.com/PureSwift/Cairo.git", branch: "master"),
    ],
    targets: [
        .target(name: "MermaidLayout", path: "Sources/MermaidLayout"),
        .target(
            name: "MermaidRender",
            dependencies: [
                "MermaidLayout",
                // Both the platform AND the trait must hold: Apple platforms use
                // CoreGraphics/CoreText and never link these even with the trait
                // on; the trait gate is what keeps Silica out of the resolved
                // graph for every no-trait consumer.
                .product(name: "SilicaCairo", package: "Silica",
                         condition: .when(platforms: [.linux], traits: ["LinuxRaster"])),
                .product(name: "Cairo", package: "Cairo",
                         condition: .when(platforms: [.linux], traits: ["LinuxRaster"])),
            ],
            path: "Sources/MermaidRender"),
        // Demo CLI for the experimental terminal renderer (capability ladder:
        // kitty-graphics → half-block raster → colored box → plain box). The two
        // raster tiers (kitty + half-block) need MermaidRender's PNG/RGBA backend
        // — available on Apple platforms and on Linux when the LinuxRaster
        // (Silica/Cairo) trait is enabled; the box tiers are pure text. The
        // target builds everywhere (its raster use is `#if`-guarded) and is NOT a
        // package product, so no `from:`/LinuxRaster consumer resolves or builds it.
        .executableTarget(
            name: "mermaidkit-term",
            dependencies: ["MermaidLayout", "MermaidRender"],
            path: "Sources/mermaidkit-term"),
        // The C ABI (`@_cdecl`, `mmk_` prefix) that Android's JNI layer calls:
        // parse → RenderScene.from(diagram, theme:, measure:) → deterministic
        // JSON, plus narration for accessibility. Pure Swift on MermaidLayout,
        // so it builds Silica-free on macOS + Linux. `include/mermaidkit.h` is
        // the hand-written C contract for JNI consumers (informational to
        // SwiftPM, which builds the Swift `@_cdecl` symbols regardless).
        .target(
            name: "MermaidKitC",
            dependencies: ["MermaidLayout"],
            path: "Sources/MermaidKitC",
            exclude: ["include/mermaidkit.h"]),
        .testTarget(name: "MermaidLayoutTests", dependencies: ["MermaidLayout"], path: "Tests/MermaidLayoutTests"),
        .testTarget(name: "MermaidRenderTests", dependencies: ["MermaidRender", "MermaidLayout"], path: "Tests/MermaidRenderTests"),
        .testTarget(name: "MermaidKitCTests", dependencies: ["MermaidKitC", "MermaidLayout"], path: "Tests/MermaidKitCTests"),
    ]
)
