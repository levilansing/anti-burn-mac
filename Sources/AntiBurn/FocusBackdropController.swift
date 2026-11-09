import AppKit
import CoreGraphics
import QuartzCore

final class FocusBackdropController {
    /// Full-screen backdrop window that ALWAYS stays at steady `maxOpacity` right below the currently focused window
    private var backdropWindows: [CGDirectDisplayID: NSWindow] = [:]
    /// Bounded window-sized overlay used strictly during 150ms transitions to fade the outgoing window (`0 -> maxOpacity`)
    private var outgoingFadeWindows: [CGDirectDisplayID: NSWindow] = [:]

    private var currentFocusedWID: Int? = nil
    private var currentFocusedPID: pid_t = 0
    private var currentFocusedBounds: CGRect = .zero
    private var outgoingFocusedWID: Int? = nil
    private var outgoingFocusedBounds: CGRect = .zero
    private var outgoingWIDStillOnScreen: Bool = false

    /// Global fade progress (only changes when enabling/disabling Focus Dim as a feature)
    private(set) var globalProgress: Double = 0.0
    private var targetGlobalProgress: Double = 0.0

    /// Transition progress when switching from Window A to Window B (0.0 = starting transition, 1.0 = finished)
    private var windowSwitchProgress: Double = 1.0

    private var animTimer: Timer?
    private var lastFrameTime: TimeInterval = CACurrentMediaTime()

    private var isPreviewForced: Bool = false
    private var previewEndTime: TimeInterval = 0

    private var globalMouseDownMonitor: Any?
    private var globalKeyMonitor: Any?

    func start() {
        lastFrameTime = CACurrentMediaTime()
        animTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange),
            name: NSWorkspace.didHideApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange),
            name: NSWorkspace.didUnhideApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateBackdropOrdering()
            }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateBackdropOrdering()
            }
        }

        updateBackdropOrdering()
    }

    func stop() {
        animTimer?.invalidate()
        animTimer = nil
        if let m = globalMouseDownMonitor { NSEvent.removeMonitor(m); globalMouseDownMonitor = nil }
        if let k = globalKeyMonitor { NSEvent.removeMonitor(k); globalKeyMonitor = nil }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for (_, win) in backdropWindows { win.orderOut(nil) }
        for (_, win) in outgoingFadeWindows { win.orderOut(nil) }
        backdropWindows.removeAll()
        outgoingFadeWindows.removeAll()
        currentFocusedWID = nil
        currentFocusedPID = 0
        outgoingFocusedWID = nil
        globalProgress = 0.0
        targetGlobalProgress = 0.0
        windowSwitchProgress = 1.0
    }

    func triggerTestPreview(duration: TimeInterval = 5.0) {
        isPreviewForced = true
        previewEndTime = CACurrentMediaTime() + duration
        updateBackdropOrdering()
    }

    @objc private func activeAppDidChange(_ note: Notification) {
        updateBackdropOrdering()
    }

    func updateBackdropOrdering() {
        let now = CACurrentMediaTime()
        if isPreviewForced && now >= previewEndTime {
            isPreviewForced = false
        }

        let settings = AppSettings.shared
        let active = settings.isEnabled && (settings.focusBackdropDimmingEnabled || isPreviewForced)

        guard active else {
            targetGlobalProgress = 0.0
            currentFocusedWID = nil
            currentFocusedPID = 0
            outgoingFocusedWID = nil
            return
        }

        targetGlobalProgress = 1.0

        guard let (newWID, newPID, newBounds, oldStillExists) = findFocusedWindowInfo(singleWindowOnly: settings.focusSingleWindowOnly) else {
            // Every single window on screen was hidden or closed!
            // Clear currentFocusedWID and immediately bring `bWin` to the front of the desktop so it dims the whole screen
            // rather than staying buried behind hidden/ordered-out windows!
            if currentFocusedWID != nil {
                currentFocusedWID = nil
                currentFocusedPID = 0
                outgoingFocusedWID = nil
                windowSwitchProgress = 1.0
                renderBackdrops()
            }
            return
        }

        guard let oldWID = currentFocusedWID else {
            currentFocusedWID = newWID
            currentFocusedPID = newPID
            currentFocusedBounds = newBounds
            outgoingWIDStillOnScreen = false
            return
        }

        if oldWID == newWID {
            currentFocusedBounds = newBounds
            return
        }

        // Ignore transient child/autocomplete popups of the SAME application (e.g., Safari URL bar dropdown)
        if newPID == currentFocusedPID && oldStillExists {
            let oldArea = currentFocusedBounds.width * currentFocusedBounds.height
            let newArea = newBounds.width * newBounds.height
            if newArea < oldArea * 0.65 && currentFocusedBounds.insetBy(dx: -40, dy: -40).intersects(newBounds) {
                return
            }
        }

        if globalProgress > 0.5 {
            outgoingFocusedWID = oldWID
            outgoingFocusedBounds = currentFocusedBounds
            outgoingWIDStillOnScreen = oldStillExists
            currentFocusedWID = newWID
            currentFocusedPID = newPID
            currentFocusedBounds = newBounds
            windowSwitchProgress = 0.0
            renderBackdrops()
        } else {
            currentFocusedWID = newWID
            currentFocusedPID = newPID
            currentFocusedBounds = newBounds
            outgoingWIDStillOnScreen = oldStillExists
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(0.001, min(0.05, now - lastFrameTime))
        lastFrameTime = now

        updateBackdropOrdering()

        let duration = 0.150 // 150ms exact duration
        let step = dt / duration

        var needsRender = false

        if abs(targetGlobalProgress - globalProgress) > 0.001 {
            if targetGlobalProgress > globalProgress {
                globalProgress = min(targetGlobalProgress, globalProgress + step)
            } else {
                globalProgress = max(targetGlobalProgress, globalProgress - step)
            }
            needsRender = true
        }

        if windowSwitchProgress < 1.0 {
            windowSwitchProgress = min(1.0, windowSwitchProgress + step)
            needsRender = true
        }

        if needsRender || globalProgress > 0.001 {
            renderBackdrops()
        }
    }

    private func renderBackdrops() {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }

        let settings = AppSettings.shared
        let maxOpacity = max(0.01, min(0.85, settings.focusBackdropDimStrength))
        let screens = DisplayBrightnessController.shared.targetScreens()
        let activeIDs = Set(screens.map { $0.displayID })

        for (id, win) in backdropWindows where !activeIDs.contains(id) {
            win.orderOut(nil)
            backdropWindows.removeValue(forKey: id)
        }
        for (id, win) in outgoingFadeWindows where !activeIDs.contains(id) {
            win.orderOut(nil)
            outgoingFadeWindows.removeValue(forKey: id)
        }

        for screen in screens {
            let id = screen.displayID
            let menuBarHeight = max(24.0, screen.frame.maxY - screen.visibleFrame.maxY)
            let fullFrame = NSRect(
                x: screen.frame.minX,
                y: screen.frame.minY,
                width: screen.frame.width,
                height: max(100, screen.frame.height - menuBarHeight)
            )

            let bWin = ensureOverlayWindow(in: &backdropWindows, id: id, frame: fullFrame, rounded: false)
            let outWin = ensureOverlayWindow(in: &outgoingFadeWindows, id: id, frame: .zero, rounded: true)

            guard globalProgress > 0.002 else {
                bWin.alphaValue = 0.0
                outWin.alphaValue = 0.0
                continue
            }

            bWin.alphaValue = CGFloat(globalProgress * maxOpacity)

            guard let wid = currentFocusedWID else {
                bWin.orderFrontRegardless()
                outWin.alphaValue = 0.0
                continue
            }

            if windowSwitchProgress < 0.999, outgoingWIDStillOnScreen, let oldWID = outgoingFocusedWID {
                // Unified transition (used for BOTH overlapping and non-overlapping windows!):
                // 1. `bWin` sits right below `oldWID` so neither `wid` nor `oldWID` is covered by `bWin`,
                //    and the entire rest of the screen stays at constant `maxOpacity`.
                // 2. `outWin` sits over `oldWID` (`order(.below, relativeTo: wid)`) and smoothly fades from `0 -> maxOpacity` over 150ms.
                // 3. We NEVER cover the newly clicked window `wid` with an `inWin` overlay after it has already been promoted to the front
                //    by macOS WindowServer (which was causing the bright -> dim -> bright flash on non-overlapping windows!).
                let p = windowSwitchProgress
                bWin.order(.below, relativeTo: oldWID)

                let outAppKitRect = cgWindowRectToAppKit(outgoingFocusedBounds, primaryScreen: NSScreen.screens.first)
                if outWin.frame != outAppKitRect {
                    outWin.setFrame(outAppKitRect, display: false)
                }
                outWin.order(.below, relativeTo: wid)
                outWin.alphaValue = CGFloat(p * maxOpacity)
            } else {
                bWin.order(.below, relativeTo: wid)
                outWin.alphaValue = 0.0
            }
        }
    }

    private func cgWindowRectToAppKit(_ cgRect: CGRect, primaryScreen: NSScreen?) -> NSRect {
        let primaryHeight = primaryScreen?.frame.height ?? NSScreen.main?.frame.height ?? 1418.0
        return NSRect(
            x: cgRect.origin.x,
            y: primaryHeight - (cgRect.origin.y + cgRect.size.height),
            width: cgRect.size.width,
            height: cgRect.size.height
        )
    }

    private func ensureOverlayWindow(in dict: inout [CGDirectDisplayID: NSWindow], id: CGDirectDisplayID, frame: NSRect, rounded: Bool) -> NSWindow {
        if let existing = dict[id] {
            if frame != .zero && existing.frame != frame {
                existing.setFrame(frame, display: true)
            }
            return existing
        }
        let win = NSWindow(
            contentRect: frame == .zero ? NSRect(x: 0, y: 0, width: 100, height: 100) : frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .normal
        win.isOpaque = false
        win.backgroundColor = rounded ? .clear : .black
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.animationBehavior = .none
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        win.alphaValue = 0.0

        if rounded {
            let v = NSView(frame: win.contentView?.bounds ?? .zero)
            v.wantsLayer = true
            v.autoresizingMask = [.width, .height]
            v.layer?.backgroundColor = NSColor.black.cgColor
            v.layer?.cornerRadius = 10.0
            v.layer?.masksToBounds = true
            win.contentView = v
        }

        dict[id] = win
        return win
    }

    private func findFocusedWindowInfo(singleWindowOnly: Bool) -> (Int, pid_t, CGRect, Bool)? {
        let myPID = ProcessInfo.processInfo.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let myBackdropNums = Set(
            backdropWindows.values.map { $0.windowNumber } +
            outgoingFadeWindows.values.map { $0.windowNumber }
        )

        // Track hidden applications so we immediately ignore windows of an app being hidden via Cmd-H!
        // When Cmd-H is pressed, NSRunningApplication.isHidden becomes true before WindowServer finishes
        // removing its windows from CGWindowList or moving them to the back of the z-order!
        var hiddenPIDs = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.isHidden {
            hiddenPIDs.insert(app.processIdentifier)
        }

        func isValidStandardWindow(_ info: [String: Any]) -> Bool {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID,
                  !hiddenPIDs.contains(pid),
                  let wid = info[kCGWindowNumber as String] as? Int,
                  !myBackdropNums.contains(wid),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? Double,
                  let h = bounds["Height"] as? Double else {
                return false
            }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            return w >= 220 && h >= 160 && alpha > 0.15
        }

        guard let topStandardWin = windowList.first(where: { isValidStandardWindow($0) }),
              let topPID = topStandardWin[kCGWindowOwnerPID as String] as? pid_t else {
            return nil
        }

        let appWindows = windowList.filter { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == topPID && isValidStandardWindow(info)
        }

        guard let targetEntry = (singleWindowOnly ? appWindows.first : appWindows.last),
              let wid = targetEntry[kCGWindowNumber as String] as? Int,
              let boundsDict = targetEntry[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }

        let rect = CGRect(
            x: boundsDict["X"] as? Double ?? 0,
            y: boundsDict["Y"] as? Double ?? 0,
            width: boundsDict["Width"] as? Double ?? 0,
            height: boundsDict["Height"] as? Double ?? 0
        )

        let checkID = (currentFocusedWID != wid) ? currentFocusedWID : outgoingFocusedWID
        var oldStillExists = false
        if let checkID = checkID,
           let oldIdx = windowList.firstIndex(where: {
               ($0[kCGWindowNumber as String] as? Int) == checkID &&
               isValidStandardWindow($0)
           }),
           let newIdx = windowList.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == wid }) {
            // Only order `bWin` below `oldWID` if `oldWID` is still a valid, unhidden window AND
            // no other application's standard window sits ABOVE `oldWID` (except `wid` itself)!
            // When an app hides (Cmd-H), WindowServer pushes `oldWID` to the back of the z-order before removing it;
            // if we ordered `bWin` below `oldWID` while `oldWID` was at the back, `bWin` would drop behind ALL windows!
            let intermediateStandardWindows = windowList[newIdx..<oldIdx].filter { info in
                guard let wNum = info[kCGWindowNumber as String] as? Int else { return false }
                return wNum != wid && wNum != checkID && isValidStandardWindow(info)
            }
            oldStillExists = intermediateStandardWindows.isEmpty
        }

        return (wid, topPID, rect, oldStillExists)
    }
}
