import AppKit
import SwiftUI

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PromptPanel?
    private var statusItem: NSStatusItem?
    private let viewModel = SearchViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        showPrompt()
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

    private func makePanel() -> PromptPanel {
        let defaultFrame = NSRect(x: 0, y: 0, width: 720, height: 132)
        let panel = PromptPanel(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .fullSizeContentView],
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
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
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
        menu.addItem(withTitle: "Afficher Michel Mails", action: #selector(showPrompt), keyEquivalent: "m")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }
}
