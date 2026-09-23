import AppKit
import SwiftUI

/// `--snapshot <dir> [--demo]`: renders the popover and main window panes to PNGs, for checking the UI
/// without screen recording. Uses its own data folder only if CLANKER_TRACKER_DIR is set.
enum Snapshot {
    static func run(to dir: URL, model: AppModel) {
        model.start()
        Task {
            // Wait for the first full read (or give up after two minutes).
            for _ in 0..<240 where !(model.hasLoaded && model.backfill == nil) || model.isDemo && !model.hasLoaded {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(1))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                await render(PopoverView(model: model, open: { _ in }).background(.regularMaterial),
                             size: nil, appearance: appearance, to: dir.appending(path: "popover-\(suffix).png"))
                // Window chrome (sidebar, toolbar) can't be captured offscreen, so render the panes themselves.
                let scheme: ColorScheme = appearance == .aqua ? .light : .dark
                image(OverviewPane(model: model).frame(width: 820), scheme, to: dir.appending(path: "overview-\(suffix).png"))
                image(ToolPane(model: model, tool: .codex).frame(width: 820), scheme, to: dir.appending(path: "codex-\(suffix).png"))
                image(SpendView(model: model).frame(width: 820), scheme, to: dir.appending(path: "spend-\(suffix).png"))
            }
            print("Snapshots in \(dir.path)")
            exit(0)
        }
    }

    private static func image(_ view: some View, _ scheme: ColorScheme, to url: URL) {
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func render(_ view: some View, size: NSSize?, appearance: NSAppearance.Name, to url: URL) async {
        let hosting = NSHostingController(rootView: view)
        let fitting = size ?? hosting.view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fitting), styleMask: size == nil ? [.borderless] : [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = hosting
        window.setContentSize(fitting)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1200))

        guard let content = window.contentView?.superview ?? window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
