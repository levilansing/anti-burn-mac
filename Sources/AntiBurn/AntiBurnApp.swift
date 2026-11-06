import AppKit
import SwiftUI

final class ControlPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelWindow: ControlPanelWindow!
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu bar accessory app (no Dock icon)
        NSApp.setActivationPolicy(.accessory)

        setupStatusBarItem()
        setupControlPanel()

        // Ensure Launch at Login reflects current setting on startup
        LaunchAtLoginManager.shared.setEnabled(AppSettings.shared.launchAtLogin)

        // Start OLED protection engines
        AntiBurnCoordinator.shared.start()

        // Ensure we always restore hardware brightness if terminated via SIGINT/SIGTERM
        signal(SIGINT) { _ in
            DisplayBrightnessController.shared.restoreAllBaselines()
            exit(0)
        }
        signal(SIGTERM) { _ in
            DisplayBrightnessController.shared.restoreAllBaselines()
            exit(0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppSettings.shared.showClockRegionGuide = false
        AntiBurnCoordinator.shared.stop()
    }

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "AntiBurn OLED Guard") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "OLED"
            }
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        }
    }

    private func setupControlPanel() {
        let hostingController = NSHostingController(rootView: MenuPopoverView())
        let size = hostingController.view.fittingSize
        let panelWidth: CGFloat = max(380, size.width)
        let panelHeight: CGFloat = max(445, size.height)

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true

        hostingController.view.frame = visualEffect.bounds
        hostingController.view.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hostingController.view)

        let panel = ControlPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // PopUpMenu level sits above the menu bar & our overlay, never clipped by the top edge
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = visualEffect
        self.panelWindow = panel

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.panelWindow.isVisible else { return }
            // Ignore clicks directly on the status item button so handleStatusItemClick toggles it cleanly without double-firing
            if let button = self.statusItem.button,
               let buttonWin = button.window {
                let mouseScreen = NSEvent.mouseLocation
                let btnRectScreen = buttonWin.convertToScreen(button.convert(button.bounds, to: nil))
                if btnRectScreen.insetBy(dx: -4, dy: -4).contains(mouseScreen) {
                    return
                }
            }
            self.closePanel()
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape key
                self?.closePanel()
                return nil
            }
            return event
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePanel(sender)
            return
        }

        if event.type == .rightMouseUp {
            showQuickContextMenu(sender)
        } else {
            togglePanel(sender)
        }
    }

    private func togglePanel(_ sender: NSView) {
        if panelWindow.isVisible {
            closePanel()
        } else {
            openPanel(below: sender)
        }
    }

    private func openPanel(below sender: NSView) {
        guard let buttonWindow = sender.window else { return }
        let buttonFrameInWindow = sender.convert(sender.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonFrameInWindow)
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first!

        // Recompute exact fitting height so nothing is clipped
        if let hostingView = panelWindow.contentView?.subviews.first {
            let fit = hostingView.fittingSize
            if fit.height > 100 {
                panelWindow.setContentSize(NSSize(width: 380, height: fit.height))
            }
        }

        let panelSize = panelWindow.frame.size
        let menuBarHeight = max(28.0, screen.frame.maxY - screen.visibleFrame.maxY)
        let topSafeY = min(buttonScreenRect.minY - 6.0, screen.frame.maxY - menuBarHeight - 6.0)

        var originX = round(buttonScreenRect.midX - (panelSize.width / 2.0))
        // Keep within horizontal screen bounds with an 8pt margin
        originX = max(screen.frame.minX + 8.0, min(originX, screen.frame.maxX - panelSize.width - 8.0))
        let originY = round(topSafeY - panelSize.height)

        panelWindow.setFrameOrigin(NSPoint(x: originX, y: originY))
        panelWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePanel() {
        AppSettings.shared.showClockRegionGuide = false
        panelWindow.orderOut(nil)
    }

    private func showQuickContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()

        let toggleFocusItem = NSMenuItem(
            title: AppSettings.shared.focusBackdropDimmingEnabled ? "Disable Focus Backdrop Dim" : "Enable Focus Backdrop Dim",
            action: #selector(quickToggleFocus),
            keyEquivalent: ""
        )
        toggleFocusItem.target = self
        menu.addItem(toggleFocusItem)

        let openSettingsItem = NSMenuItem(title: "Open Controls & Sliders...", action: #selector(quickOpenPopover), keyEquivalent: ",")
        openSettingsItem.target = self
        menu.addItem(openSettingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quickQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quickTestMenuBar() {
        AntiBurnCoordinator.shared.testMenuBarDimming()
    }

    @objc private func quickTestIdleDim() {
        AntiBurnCoordinator.shared.testIdleScreenDimming()
    }

    @objc private func quickTestFocusDim() {
        AntiBurnCoordinator.shared.testFocusBackdropDimming()
    }

    @objc private func quickToggleFocus() {
        AppSettings.shared.focusBackdropDimmingEnabled.toggle()
    }

    @objc private func quickOpenPopover() {
        if let button = statusItem.button {
            openPanel(below: button)
        }
    }

    @objc private func quickQuit() {
        AntiBurnCoordinator.shared.stop()
        NSApplication.shared.terminate(nil)
    }
}

@main
struct AntiBurnApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
