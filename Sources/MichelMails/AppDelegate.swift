import AppKit
import SwiftUI

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: PromptPanel?
    private var galleryWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let viewModel = SearchViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        viewModel.onGalleryReady = { [weak self] gallery in
            self?.showGallery(gallery)
        }
        configureStatusItem()
        showPrompt()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showPrompt()
        return true
    }

    @objc private func showPrompt() {
        if panel == nil {
            panel = makePanel()
        }

        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showGallery(_ gallery: MailImageGallery) {
        let window: NSWindow
        if let galleryWindow {
            window = galleryWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Email Images"
            window.minSize = NSSize(width: 690, height: 480)
            window.isReleasedWhenClosed = false
            if !window.setFrameUsingName("MichelMailsGalleryWindow") {
                window.center()
            }
            window.setFrameAutosaveName("MichelMailsGalleryWindow")
            galleryWindow = window
        }

        window.contentView = NSHostingView(rootView: MailImageGalleryView(gallery: gallery))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> PromptPanel {
        let defaultFrame = NSRect(x: 0, y: 0, width: 720, height: 132)
        let panel = PromptPanel(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = "Michel Mails"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.contentMinSize = defaultFrame.size
        panel.contentMaxSize = defaultFrame.size
        panel.standardWindowButton(.zoomButton)?.isHidden = false
        panel.standardWindowButton(.zoomButton)?.isEnabled = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = false
        panel.contentView = NSHostingView(rootView: SearchView(viewModel: viewModel))

        if !panel.setFrameUsingName("MichelMailsPromptWindow") {
            panel.center()
        }
        panel.setFrameAutosaveName("MichelMailsPromptWindow")
        return panel
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "sparkle.magnifyingglass",
            accessibilityDescription: "Michel Mails"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Show Michel Mails", action: #selector(showPrompt), keyEquivalent: "m")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        NSApp.terminate(nil)
    }
}
