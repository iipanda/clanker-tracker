import AppKit
import ClankerCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: AppModel
    private var statusItem: StatusItemController?
    private var window: NSWindow?
    private let notifier = Notifier.shared

    init(demo: Bool) {
        model = AppModel(demo: demo)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItem = StatusItemController(model: model) { [weak self] pane in self?.show(pane) }

        notifier.setUp()
        notifier.onOpen = { [weak self] in self?.show(.overview) }
        model.onUpdate = { [weak self] initial in self?.evaluateNotifications(initial: initial) }
        model.start()

        // Resets happen without new data, so check once a minute as well.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.evaluateNotifications(initial: false)
            }
        }
        if CommandLine.arguments.contains("--show-window") { show(.overview) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(.overview)
        return true
    }

    private func evaluateNotifications(initial: Bool) {
        guard !model.isDemo, model.hasLoaded else { return }
        notifier.evaluate(model.allForecasts, prefs: model.settings.notificationPrefs, isInitialLoad: initial, now: Date())
    }

    // MARK: Window

    @objc func closeWindowFromQuitShortcut() { window?.performClose(nil) }

    @objc func showOverview() { show(.overview) }
    @objc func showSettings() { show(.settings) }

    func show(_ pane: Pane) {
        model.pane = pane
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.contentViewController = NSHostingController(rootView: MainView(model: model))
            w.title = "Clanker Tracker"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 1000, height: 720))
            w.center()
            w.setFrameAutosaveName("MainWindow")
            window = w
        }
        // Show in the Dock and app switcher while the window is open.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "About Clanker Tracker", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Clanker Tracker", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        // ⌘Q closes the window and keeps tracking in the menu bar; quitting is ⌥⌘Q (or Quit in the
        // menu bar icon's menu).
        let close = NSMenuItem(title: "Close Window", action: #selector(closeWindowFromQuitShortcut), keyEquivalent: "q")
        close.target = self
        app.addItem(close)
        let quit = NSMenuItem(title: "Quit Clanker Tracker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command, .option]
        app.addItem(quit)
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let open = NSMenuItem(title: "Clanker Tracker", action: #selector(showOverview), keyEquivalent: "o")
        open.target = self
        windowMenu.addItem(open)
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}
