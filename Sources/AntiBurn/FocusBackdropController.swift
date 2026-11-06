import AppKit
import CoreGraphics
import QuartzCore

final class FocusBackdropController {
    /// Full-screen backdrop window that ALWAYS stays at steady `maxOpacity` right below the currently focused window
    private var backdropWindows: [CGDirectDisplayID: NSWindow] = [:]
    /// Bounded window-sized overlay used strictly during 100ms transitions to fade the incoming window (`maxOpacity -> 0`)
    private var incomingFadeWindows: [CGDirectDisplayID: NSWindow] = [:]
    /// Bounded window-sized overlay used strictly during 100ms transitions to fade the outgoing window (`0 -> maxOpacity`)
    private var outgoingFadeWindows: [CGDirectDisplayID: NSWindow] = [:]

    private var currentFocusedWID: Int? = nil
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
    private var pollCounter: Int = 0
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

        // Immediately check window z-order on mouse click or Cmd+`/Cmd+Tab key events (zero polling delay)
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
        for (_, win) in incomingFadeWindows { win.orderOut(nil) }
        for (_, win) in outgoingFadeWindows { win.orderOut(nil) }
        backdropWindows.removeAll()
        incomingFadeWindows.removeAll()
        outgoingFadeWindows.removeAll()
        currentFocusedWID = nil
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
            outgoingFocusedWID = nil
            return
        }

        if let (newWID, newBounds, oldStillExists) = findFocusedWindowInfo(singleWindowOnly: settings.focusSingleWindowOnly) {
            if let oldWID = currentFocusedWID, oldWID != newWID, globalProgress > 0.5 {
                outgoingFocusedWID = oldWID
                outgoingFocusedBounds = currentFocusedBounds
                outgoingWIDStillOnScreen = oldStillExists
                currentFocusedWID = newWID
                currentFocusedBounds = newBounds
                windowSwitchProgress = 0.0
                targetGlobalProgress = 1.0
                // Immediately render on the exact same RunLoop turn so `inWin` and `bWin` update on the very first frame!
                renderBackdrops()
            } else {
                currentFocusedWID = newWID
                currentFocusedBounds = newBounds
                outgoingWIDStillOnScreen = oldStillExists
                targetGlobalProgress = 1.0
            }
        } else {
            targetGlobalProgress = 1.0
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(0.001, min(0.05, now - lastFrameTime))
        lastFrameTime = now

        // Check focused window every frame so same-app window switches are detected within 16ms instead of 50ms
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
        let maxOpacity = max(0.05, min(0.85, settings.focusBackdropDimStrength))
        let screens = DisplayBrightnessController.shared.targetScreens()
        let activeIDs = Set(screens.map { $0.displayID })

        for (id, win) in backdropWindows where !activeIDs.contains(id) {
            win.orderOut(nil)
            backdropWindows.removeValue(forKey: id)
        }
        for (id, win) in incomingFadeWindows where !activeIDs.contains(id) {
            win.orderOut(nil)
            incomingFadeWindows.removeValue(forKey: id)
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
            let inWin = ensureOverlayWindow(in: &incomingFadeWindows, id: id, frame: .zero, rounded: true)
            let outWin = ensureOverlayWindow(in: &outgoingFadeWindows, id: id, frame: .zero, rounded: true)

            guard globalProgress > 0.002 else {
                bWin.alphaValue = 0.0
                inWin.alphaValue = 0.0
                outWin.alphaValue = 0.0
                continue
            }

            // 1. Main full-screen backdrop NEVER changes its alpha during window switches or app quits!
            //    It stays locked at `globalProgress * maxOpacity` 100% of the time, so the desktop wallpaper and background windows
            //    NEVER flicker light or dark under any circumstance!
            bWin.alphaValue = CGFloat(globalProgress * maxOpacity)

            guard let wid = currentFocusedWID else {
                bWin.orderFrontRegardless()
                inWin.alphaValue = 0.0
                outWin.alphaValue = 0.0
                continue
            }

            if windowSwitchProgress < 0.999 {
                let p = windowSwitchProgress

                if outgoingWIDStillOnScreen, let oldWID = outgoingFocusedWID {
                    // Normal switch between two open windows (`oldWID` -> `wid`):
                    // Keep `bWin` at full `maxOpacity` right below BOTH windows (below `oldWID`).
                    // Neither `wid` nor `oldWID` is covered by `bWin`, and the entire background behind both stays at constant `maxOpacity`!
                    bWin.order(.below, relativeTo: oldWID)

                    if currentFocusedBounds.intersects(outgoingFocusedBounds) {
                        // When the two windows overlap, avoid placing two overlapping rects over their intersection;
                        // simply fade `outWin` over `oldWID` from 0 -> maxOpacity while `wid` sits cleanly on top of `outWin`!
                        inWin.alphaValue = 0.0
                        let outAppKitRect = cgWindowRectToAppKit(outgoingFocusedBounds, primaryScreen: NSScreen.screens.first)
                        if outWin.frame != outAppKitRect {
                            outWin.setFrame(outAppKitRect, display: false)
                        }
                        outWin.alphaValue = CGFloat(p * maxOpacity)
                        outWin.order(.below, relativeTo: wid)
                    } else {
                        // Non-overlapping windows: fade `wid` in (`maxOpacity -> 0`) and `oldWID` out (`0 -> maxOpacity`) simultaneously!
                        let inAppKitRect = cgWindowRectToAppKit(currentFocusedBounds, primaryScreen: NSScreen.screens.first)
                        if inWin.frame != inAppKitRect {
                            inWin.setFrame(inAppKitRect, display: false)
                        }
                        inWin.order(.above, relativeTo: wid)
                        inWin.alphaValue = CGFloat((1.0 - p) * maxOpacity)

                        let outAppKitRect = cgWindowRectToAppKit(outgoingFocusedBounds, primaryScreen: NSScreen.screens.first)
                        if outWin.frame != outAppKitRect {
                            outWin.setFrame(outAppKitRect, display: false)
                        }
                        outWin.order(.below, relativeTo: wid)
                        outWin.alphaValue = CGFloat(p * maxOpacity)
                    }
                } else {
                    // Previous app was QUIT or its window was CLOSED (`oldWID` no longer exists on screen):
                    // `bWin` stays at constant `maxOpacity` right below `wid` (`newWID`).
                    bWin.order(.below, relativeTo: wid)
                    outWin.alphaValue = 0.0

                    // `inWin` sits strictly over `wid`'s exact window frame and fades from `maxOpacity -> 0` over 100ms
                    // so `wid` smoothly brightens from dimmed to 100% with ZERO overlap on the desktop outside `wid`!
                    let inAppKitRect = cgWindowRectToAppKit(currentFocusedBounds, primaryScreen: NSScreen.screens.first)
                    if inWin.frame != inAppKitRect {
                        inWin.setFrame(inAppKitRect, display: false)
                    }
                    inWin.order(.above, relativeTo: wid)
                    inWin.alphaValue = CGFloat((1.0 - p) * maxOpacity)
                }
            } else {
                // Steady state: `bWin` at full `maxOpacity` right below `wid`, transition overlays hidden at alpha 0
                bWin.order(.below, relativeTo: wid)
                inWin.alphaValue = 0.0
                outWin.alphaValue = 0.0
            }
        }
    }

    /// Pre-positions `inWin` over whichever inactive standard window the cursor is currently hovering over
    /// at alpha 0.0 so that if the user clicks it, `inWin` is already at the exact frame and z-order!
    private var prewarmedHoverWID: Int? = nil

    private func prewarmHoveredWindowIfNeeded(windowList: [[String: Any]], isValid: ([String: Any]) -> Bool) {
        guard windowSwitchProgress >= 0.999, let activeWID = currentFocusedWID else { return }
        let mouseAppKit = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1418.0
        let mouseCG = CGPoint(x: mouseAppKit.x, y: primaryHeight - mouseAppKit.y)

        // Find the topmost valid standard window under the cursor
        guard let hoveredEntry = windowList.first(where: { info in
            guard isValid(info),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double,
                  let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double,
                  let h = bounds["Height"] as? Double else {
                return false
            }
            return CGRect(x: x, y: y, width: w, height: h).contains(mouseCG)
        }),
        let hovWID = hoveredEntry[kCGWindowNumber as String] as? Int,
        hovWID != activeWID,
        let boundsDict = hoveredEntry[kCGWindowBounds as String] as? [String: Any] else {
            return
        }

        guard prewarmedHoverWID != hovWID else { return }
        prewarmedHoverWID = hovWID

        let cgRect = CGRect(
            x: boundsDict["X"] as? Double ?? 0,
            y: boundsDict["Y"] as? Double ?? 0,
            width: boundsDict["Width"] as? Double ?? 0,
            height: boundsDict["Height"] as? Double ?? 0
        )
        let appKitRect = cgWindowRectToAppKit(cgRect, primaryScreen: NSScreen.screens.first)
        for (_, inWin) in incomingFadeWindows {
            if inWin.frame != appKitRect {
                inWin.setFrame(appKitRect, display: false)
            }
            inWin.alphaValue = 0.0
            inWin.order(.above, relativeTo: hovWID)
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

    private func findFocusedWindowInfo(singleWindowOnly: Bool) -> (Int, CGRect, Bool)? {
        let myPID = ProcessInfo.processInfo.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let myBackdropNums = Set(
            backdropWindows.values.map { $0.windowNumber } +
            incomingFadeWindows.values.map { $0.windowNumber } +
            outgoingFadeWindows.values.map { $0.windowNumber }
        )

        func isValidStandardWindow(_ info: [String: Any]) -> Bool {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID,
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
            return w > 80 && h > 80 && alpha > 0.05
        }

        // Prefer the topmost visible standard window in the actual WindowServer z-order,
        // UNLESS NSWorkspace.didActivateApplicationNotification just told us a specific app with visible windows activated
        // and WindowServer hasn't finished promoting its window to index 0 yet!
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let topStandardWin = windowList.first(where: { isValidStandardWindow($0) })
        let topPID = topStandardWin?[kCGWindowOwnerPID as String] as? pid_t ?? 0

        let chosenPID: pid_t
        if frontPID != 0 && frontPID != myPID && frontPID != topPID {
            // Check if frontPID actually has a valid standard window on screen
            let frontHasWindow = windowList.contains {
                ($0[kCGWindowOwnerPID as String] as? pid_t) == frontPID && isValidStandardWindow($0)
            }
            chosenPID = frontHasWindow ? frontPID : topPID
        } else {
            chosenPID = topPID
        }

        guard chosenPID != 0 else { return nil }

        let appWindows = windowList.filter { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == chosenPID && isValidStandardWindow(info)
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
        if let checkID = checkID {
            oldStillExists = windowList.contains(where: { ($0[kCGWindowNumber as String] as? Int) == checkID && isValidStandardWindow($0) })
        }

        prewarmHoveredWindowIfNeeded(windowList: windowList, isValid: isValidStandardWindow)

        return (wid, rect, oldStillExists)
    }
}
