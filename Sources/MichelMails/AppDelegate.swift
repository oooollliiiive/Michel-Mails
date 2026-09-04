import AppKit
import SwiftUI

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let promptWidth: CGFloat = 720
    private static let promptBaseHeight: CGFloat = 132
    private static let historyHeaderHeight: CGFloat = 26
    private static let historyRowHeight: CGFloat = 34
    private static let historySpacing: CGFloat = 12

    private var panel: PromptPanel?
    private var resultsWindow: NSWindow?
    private var galleryWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let viewModel = SearchViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        viewModel.onGalleryReady = { [weak self] gallery in
            self?.showGallery(gallery)
        }
        viewModel.onResultsReady = { [weak self] results in
            self?.showResults(results)
        }
        viewModel.onHistorySuggestionsChanged = { [weak self] count in
            self?.resizePromptPanel(forHistoryCount: count)
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

        window.contentView = NSHostingView(
            rootView: MailImageGalleryView(
                gallery: gallery,
                onOpenEmail: { [weak self] message in
                    self?.viewModel.openMessage(message)
                }
            )
        )
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showResults(_ results: MailSearchResults) {
        let window: NSWindow
        if let resultsWindow {
            window = resultsWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Email Results"
            window.minSize = NSSize(width: 680, height: 420)
            window.isReleasedWhenClosed = false
            if !window.setFrameUsingName("MichelMailsResultsWindow") {
                window.center()
            }
            window.setFrameAutosaveName("MichelMailsResultsWindow")
            resultsWindow = window
        }

        window.contentView = NSHostingView(
            rootView: MailSearchResultsView(
                results: results,
                onOpenEmail: { [weak self] message in
                    self?.viewModel.openMessage(message)
                }
            )
        )
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> PromptPanel {
        let defaultFrame = NSRect(
            x: 0,
            y: 0,
            width: Self.promptWidth,
            height: Self.promptBaseHeight
        )
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
        panel.contentMaxSize = NSSize(
            width: Self.promptWidth,
            height: Self.promptBaseHeight
                + Self.historySpacing
                + Self.historyHeaderHeight
                + (Self.historyRowHeight * 5)
        )
        panel.standardWindowButton(.zoomButton)?.isHidden = false
        panel.standardWindowButton(.zoomButton)?.isEnabled = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = false
        panel.contentView = NSHostingView(rootView: SearchView(viewModel: viewModel))

        if !panel.setFrameUsingName("MichelMailsPromptWindow") {
            panel.center()
        }
        resizePromptPanel(panel, forHistoryCount: 0, animated: false)
        panel.setFrameAutosaveName("MichelMailsPromptWindow")
        return panel
    }

    private func resizePromptPanel(forHistoryCount count: Int) {
        guard let panel else { return }
        resizePromptPanel(panel, forHistoryCount: count, animated: true)
    }

    private func resizePromptPanel(
        _ panel: NSPanel,
        forHistoryCount count: Int,
        animated: Bool
    ) {
        let visibleCount = min(max(count, 0), 5)
        let historyHeight = visibleCount == 0
            ? 0
            : Self.historySpacing
                + Self.historyHeaderHeight
                + (Self.historyRowHeight * CGFloat(visibleCount))
        let targetContentSize = NSSize(
            width: Self.promptWidth,
            height: Self.promptBaseHeight + historyHeight
        )
        let targetFrameSize = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContentSize)
        ).size
        let currentFrame = panel.frame
        var targetFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetFrameSize.height,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )

        if let visibleFrame = panel.screen?.visibleFrame {
            targetFrame.origin.y = max(targetFrame.minY, visibleFrame.minY)
        }
        panel.setFrame(targetFrame, display: true, animate: animated)
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
