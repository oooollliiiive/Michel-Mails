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
    private static let downloadsSidebarWidth: CGFloat = 238
    private static let expandedMainWidth: CGFloat = 1_020
    private static let expandedContentHeight: CGFloat = 950
    private static let historyHeaderHeight: CGFloat = 26
    private static let historyRowHeight: CGFloat = 34
    private static let historySpacing: CGFloat = 12

    private var panel: PromptPanel?
    private var statusItem: NSStatusItem?
    private var isAdjustingPanelFrame = false
    private let indexController: MailIndexController
    private let downloadManager: AttachmentDownloadManager
    private let viewModel: SearchViewModel

    override init() {
        let indexController = MailIndexController()
        let downloadManager = AttachmentDownloadManager()
        self.indexController = indexController
        self.downloadManager = downloadManager
        self.viewModel = SearchViewModel(
            indexController: indexController,
            downloadManager: downloadManager
        )
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
        viewModel.onDownloadsVisibilityChanged = { [weak self] _ in
            self?.resizeForCurrentContent()
        }
        downloadManager.onPresentDownloads = { [weak self] in
            self?.viewModel.showDownloads()
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

    @objc private func showDownloads() {
        showPrompt()
        viewModel.showDownloads()
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
            rootView: SearchView(
                viewModel: viewModel,
                indexController: indexController,
                downloadManager: downloadManager
            )
        )

        restorePromptPosition(panel)
        resizePromptPanel(panel, forHistoryCount: 0, animated: false)
        return panel
    }

    private func resizeForCurrentContent() {
        if viewModel.displayedGallery != nil || viewModel.displayedResults != nil {
            setContentExpanded(true)
        } else {
            let visibleHistoryCount = viewModel.historyIsVisible
                ? viewModel.historySuggestions.count
                : 0
            resizePromptPanel(forHistoryCount: visibleHistoryCount)
        }
    }

    private func resizePromptPanel(forHistoryCount count: Int) {
        guard let panel else { return }
        guard viewModel.displayedGallery == nil, viewModel.displayedResults == nil else { return }
        resizePromptPanel(panel, forHistoryCount: count, animated: true)
    }

    private func setContentExpanded(_ isExpanded: Bool, animated: Bool = true) {
        guard let panel else { return }
        let sidebarWidth = viewModel.downloadsSidebarIsVisible
            ? Self.downloadsSidebarWidth
            : 0
        if !isExpanded {
            let compactWidth = Self.promptWidth + sidebarWidth
            panel.contentMinSize = NSSize(width: compactWidth, height: Self.promptBaseHeight)
            panel.contentMaxSize = NSSize(
                width: compactWidth,
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
        let availableWidth = max(
            Self.promptWidth + sidebarWidth,
            (visibleFrame?.width ?? 1_320) - 24
        )
        let mainWidth = min(Self.expandedMainWidth, availableWidth - sidebarWidth)
        let targetContentWidth = mainWidth + sidebarWidth
        let preferredHeight = min(1_020, (visibleFrame?.height ?? 1_020) - 12)
        let targetContentHeight = max(Self.expandedContentHeight, preferredHeight)
        panel.contentMinSize = NSSize(
            width: Self.promptWidth + sidebarWidth,
            height: Self.expandedContentHeight
        )
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
            if targetFrame.height <= visibleFrame.height {
                targetFrame.origin.y = min(
                    max(targetFrame.minY, visibleFrame.minY),
                    visibleFrame.maxY - targetFrame.height
                )
            } else {
                targetFrame.origin.y = visibleFrame.minY
            }
        }
        setPanelFrame(panel, frame: targetFrame, animated: animated)
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
            width: Self.promptWidth + (viewModel.downloadsSidebarIsVisible
                ? Self.downloadsSidebarWidth
                : 0),
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
        setPanelFrame(panel, frame: targetFrame, animated: animated)
    }

    private func setPanelFrame(_ panel: NSPanel, frame: NSRect, animated: Bool) {
        isAdjustingPanelFrame = true
        panel.setFrame(frame, display: true, animate: animated)
        isAdjustingPanelFrame = false
    }

    private func restorePromptPosition(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        var savedX: CGFloat?
        var savedTop: CGFloat?
        if defaults.object(forKey: "MichelMailsPromptX") != nil,
           defaults.object(forKey: "MichelMailsPromptTop") != nil {
            savedX = defaults.double(forKey: "MichelMailsPromptX")
            savedTop = defaults.double(forKey: "MichelMailsPromptTop")
        } else if let legacyFrame = defaults.string(
            forKey: "NSWindow Frame MichelMailsPromptWindow"
        ) {
            let numbers = legacyFrame
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .prefix(4)
                .compactMap { Double($0) }
            if numbers.count == 4 {
                savedX = numbers[0]
                savedTop = numbers[1] + numbers[3]
            }
        }
        guard let savedX, let savedTop else {
            panel.center()
            return
        }
        var frame = panel.frame
        frame.origin.x = savedX
        frame.origin.y = savedTop - frame.height
        if let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        }
        panel.setFrame(frame, display: false)
    }

    private func rememberPromptPosition() {
        guard let panel else { return }
        let defaults = UserDefaults.standard
        defaults.set(panel.frame.minX, forKey: "MichelMailsPromptX")
        defaults.set(panel.frame.maxY, forKey: "MichelMailsPromptTop")
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "sparkle.magnifyingglass",
            accessibilityDescription: "Michel Mails"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Show Michel Mails", action: #selector(showPrompt), keyEquivalent: "m")
        menu.addItem(withTitle: "Downloads", action: #selector(showDownloads), keyEquivalent: "d")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        rememberPromptPosition()
        viewModel.closeDisplayedContent()
        setContentExpanded(false, animated: false)
        NSApp.terminate(nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjustingPanelFrame,
              let window = notification.object as? NSWindow,
              window === panel else { return }
        rememberPromptPosition()
    }
}
