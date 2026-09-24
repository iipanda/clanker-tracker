import AppKit
import ClankerCore
import SwiftUI

/// The menu bar item: a ring that fills with the tightest limit, plus its percentage.
/// Monochrome (template) until a limit is projected to run out; then amber, or red with a countdown when hit.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel

    private let open: (Pane) -> Void

    init(model: AppModel, open: @escaping (Pane) -> Void) {
        self.model = model
        self.open = open
        super.init()

        let hosting = NSHostingController(rootView: PopoverView(model: model, open: { [weak self] pane in
            self?.popover.performClose(nil)
            open(pane)
        }))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        observe()
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        // Right-click (or Control-click) opens a small menu instead of the summary.
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popover.performClose(nil)
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Clanker Tracker", action: #selector(openWindow), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Clanker Tracker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.now = Date()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func openWindow() { open(.overview) }
    @objc private func openSettings() { open(.settings) }

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        guard let button = item.button else { return }
        let t = model.tightest
        let state = LimitState(t)
        let pct = t?.used ?? 0

        button.image = MenuBarRenderer.ring(pct: pct, color: state == .calm ? nil : nsColor(state))

        let title: NSAttributedString
        switch model.settings.menuBarMode {
        case .icon:
            title = NSAttributedString(string: "")
        case .tightest:
            let text = t == nil ? "–" : state == .hit ? Fmt.countdown(to: t!.end, from: model.now) : Fmt.pct(pct)
            title = styled(" " + text, state)
        case .both:
            let parts = NSMutableAttributedString()
            for (i, tool) in Tool.allCases.enumerated() {
                let f = model.tightest(tool)
                if i > 0 { parts.append(styled(" · ", .calm, secondary: true)) }
                parts.append(styled((i == 0 ? " " : "") + (f.map { Fmt.pct($0.used) } ?? "–"), LimitState(f)))
            }
            title = parts
        }
        button.attributedTitle = title

        let label = t.map { "\($0.tool.displayName) \($0.window.sentenceLabel) limit \(Fmt.pct($0.used)) used" + ($0.alertRunout != nil ? ", runs out soon" : "") }
        button.setAccessibilityLabel("Clanker Tracker" + (label.map { ": \($0)" } ?? ""))
    }

    private func styled(_ s: String, _ state: LimitState, secondary: Bool = false) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)]
        if state != .calm { attrs[.foregroundColor] = nsColor(state) }
        if secondary { attrs[.foregroundColor] = NSColor.secondaryLabelColor }
        return NSAttributedString(string: s, attributes: attrs)
    }

    private func nsColor(_ state: LimitState) -> NSColor {
        state == .hit ? .systemRed : .systemOrange
    }

    func popoverDidClose(_ notification: Notification) {}
}

enum MenuBarRenderer {
    /// A 15pt ring gauge. Template (follows the menu bar) when `color` is nil.
    static func ring(pct: Double, color: NSColor?) -> NSImage {
        let size = NSSize(width: 15, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let stroke = color ?? .black
            let lineWidth: CGFloat = 2.2
            let r = rect.insetBy(dx: lineWidth / 2 + 0.6, dy: lineWidth / 2 + 0.6)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = lineWidth
            stroke.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let fraction = max(0, min(1, pct / 100))
            guard fraction > 0 else { return true }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: r.width / 2, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            stroke.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}
