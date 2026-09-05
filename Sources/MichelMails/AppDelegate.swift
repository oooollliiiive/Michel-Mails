import AppKit
import SwiftUI

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let promptWidth: CGFloat = 720
    private static let promptBaseHeight: CGFloat = 262
    private static let historyHeaderHeight: CGFloat = 26
    private static let historyRowHeight: CGFloat = 34
    private static let historySpacing: CGFloat = 12

    private var panel: PromptPanel?
    private var statusItem: NSStatusItem?
    private let indexController: MailIndexController
    private let viewModel: SearchViewModel

    override init() {
        let indexController = MailIndexController()
        self.indexController = indexController
        self.viewModel = SearchViewModel(indexController: indexController)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        viewModel.onContentVisibilityChanged = { [weak self] isVisible in
            self?.setContentExpanded(isVisible)
        }
        viewModel.onHistorySuggestionsChanged = { [weak self] count in
            self?.resizePromptPanel(forHistoryCount: count)
        }
        configureStatusItem()
        showPrompt()
        indexController.start()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showPrompt()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        indexController.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = []
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
        panel.contentView = NSHostingView(
            rootView: SearchView(viewModel: viewModel, indexController: indexController)
        )

        if !panel.setFrameUsingName("MichelMailsPromptWindow") {
            panel.center()
        }
        resizePromptPanel(panel, forHistoryCount: 0, animated: false)
        panel.setFrameAutosaveName("MichelMailsPromptWindow")
        return panel
    }

    private func resizePromptPanel(forHistoryCount count: Int) {
        guard let panel else { return }
        guard viewModel.displayedGallery == nil, viewModel.displayedResults == nil else { return }
        resizePromptPanel(panel, forHistoryCount: count, animated: true)
    }

    private func setContentExpanded(_ isExpanded: Bool, animated: Bool = true) {
        guard let panel else { return }
        if !isExpanded {
            panel.contentMinSize = NSSize(width: Self.promptWidth, height: Self.promptBaseHeight)
            panel.contentMaxSize = NSSize(
                width: Self.promptWidth,
                height: Self.promptBaseHeight
                    + Self.historySpacing
                    + Self.historyHeaderHeight
                    + (Self.historyRowHeight * 5)
            )
            let visibleHistoryCount = viewModel.historyIsVisible
                ? viewModel.historySuggestions.count
                : 0
            resizePromptPanel(panel, forHistoryCount: visibleHistoryCount, animated: animated)
            return
        }

        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let targetContentWidth = min(1_020, (visibleFrame?.width ?? 1_020) * 0.92)
        let targetContentHeight = min(940, (visibleFrame?.height ?? 940) * 0.96)
        panel.contentMinSize = NSSize(width: 720, height: min(820, targetContentHeight))
        panel.contentMaxSize = NSSize(width: 10_000, height: 10_000)

        let targetFrameSize = panel.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: NSSize(width: targetContentWidth, height: targetContentHeight)
            )
        ).size
        let currentFrame = panel.frame
        var targetFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetFrameSize.height,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )
        if let visibleFrame {
            targetFrame.origin.x = min(max(targetFrame.minX, visibleFrame.minX), visibleFrame.maxX - targetFrame.width)
            targetFrame.origin.y = max(targetFrame.minY, visibleFrame.minY)
        }
        panel.setFrame(targetFrame, display: true, animate: animated)
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
        viewModel.closeDisplayedContent()
        setContentExpanded(false, animated: false)
        panel?.saveFrame(usingName: "MichelMailsPromptWindow")
        NSApp.terminate(nil)
    }
}
