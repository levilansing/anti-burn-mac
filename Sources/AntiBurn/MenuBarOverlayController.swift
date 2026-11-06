import AppKit
import QuartzCore

/// Private SkyLight API bridge for `SLSSetMenuBarInsetAndAlpha`
final class SkyLightMenuBarBridge {
    static let shared = SkyLightMenuBarBridge()

    private typealias MainConnFunc = @convention(c) () -> Int32
    private typealias SetInsetAlphaFunc = @convention(c) (Int32, Double, Double, Float) -> Int32

    private var cid: Int32 = 0
    private var setInsetAlphaFn: SetInsetAlphaFunc?
    private var lastAppliedAlpha: Float = 1.0

    private init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) {
            if let cidSym = dlsym(handle, "SLSMainConnectionID") {
                let fn = unsafeBitCast(cidSym, to: MainConnFunc.self)
                cid = fn()
            }
            if let setSym = dlsym(handle, "SLSSetMenuBarInsetAndAlpha") {
                setInsetAlphaFn = unsafeBitCast(setSym, to: SetInsetAlphaFunc.self)
            }
        }
    }

    func setMenuBarAlpha(_ alpha: Float) {
        guard let fn = setInsetAlphaFn, cid != 0 else { return }
        let clamped = max(0.05, min(1.0, alpha))
        if abs(clamped - lastAppliedAlpha) > 0.002 || clamped == 1.0 {
            _ = fn(cid, 0.0, 1.0, clamped)
            lastAppliedAlpha = clamped
        }
    }

    func restoreFullAlpha() {
        guard let fn = setInsetAlphaFn, cid != 0 else { return }
        _ = fn(cid, 0.0, 1.0, 1.0)
        lastAppliedAlpha = 1.0
    }
}

/// Custom view that renders the menu bar dimming strip + separate right-hand clock region
final class MenuBarDimView: NSView {
    private let mainStripLayer = CALayer()
    private let clockStripLayer = CALayer()
    private let guideBorderLayer = CAShapeLayer()

    /// Current visibility of the menu bar (0.0 = fully dimmed, 0.5 = 50% intent visibility, 1.0 = 100% visible / no overlay)
    var currentVisibility: Double = 0.0 {
        didSet {
            updateAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        guard let root = self.layer else { return }
        root.backgroundColor = NSColor.clear.cgColor

        mainStripLayer.anchorPoint = .zero
        clockStripLayer.anchorPoint = .zero

        guideBorderLayer.fillColor = NSColor.systemCyan.withAlphaComponent(0.18).cgColor
        guideBorderLayer.strokeColor = NSColor.systemCyan.cgColor
        guideBorderLayer.lineWidth = 1.5
        guideBorderLayer.lineDashPattern = [4, 3]
        guideBorderLayer.isHidden = true

        root.addSublayer(mainStripLayer)
        root.addSublayer(clockStripLayer)
        root.addSublayer(guideBorderLayer)

        updateAppearance()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutSublayers()
        CATransaction.commit()
    }

    func layoutSublayers() {
        let b = bounds
        let settings = AppSettings.shared

        let useClockSplit = settings.clockCustomDimEnabled &&
                            settings.menuBarBlendStyle != .skyLightNativeAlpha &&
                            settings.clockWidthPoints > 0

        if useClockSplit {
            let clockW = CGFloat(min(Double(b.width), max(20.0, settings.clockWidthPoints)))
            let rightOff = CGFloat(max(0.0, settings.clockRightOffsetPoints))
            let clockX = max(0, b.width - clockW - rightOff)

            mainStripLayer.frame = CGRect(x: 0, y: 0, width: clockX, height: b.height)
            clockStripLayer.isHidden = false
            clockStripLayer.frame = CGRect(x: clockX, y: 0, width: clockW + rightOff, height: b.height)

            let guideRect = CGRect(x: clockX, y: 0.5, width: clockW, height: max(1, b.height - 1))
            guideBorderLayer.path = CGPath(roundedRect: guideRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            guideBorderLayer.isHidden = !settings.showClockRegionGuide
        } else {
            mainStripLayer.frame = b
            clockStripLayer.isHidden = true
            guideBorderLayer.isHidden = true
        }
    }

    func updateAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let settings = AppSettings.shared
        layoutSublayers()

        let dimMultiplier = max(0.0, min(1.0, 1.0 - currentVisibility))
        let focusProgress = AntiBurnCoordinator.shared.focusBackdropController.globalProgress
        let focusMenuBarDim: Double = (settings.focusDimCoversMenuBar && focusProgress > 0.001)
            ? (settings.focusBackdropDimStrength * focusProgress * dimMultiplier)
            : 0.0

        if !settings.menuBarDimmingEnabled {
            // Only Focus Dim is covering the menu bar (if enabled)
            SkyLightMenuBarBridge.shared.restoreFullAlpha()
            mainStripLayer.compositingFilter = nil
            clockStripLayer.compositingFilter = nil
            let alpha = CGFloat(max(0.0, min(0.95, focusMenuBarDim)))
            mainStripLayer.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: alpha).cgColor
            clockStripLayer.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: alpha).cgColor
            CATransaction.commit()
            return
        }

        let mainDim = settings.menuBarDimStrength * dimMultiplier
        let clockDim = (settings.clockCustomDimEnabled ? settings.clockDimStrength : settings.menuBarDimStrength) * dimMultiplier

        switch settings.menuBarBlendStyle {
        case .classicAlpha:
            SkyLightMenuBarBridge.shared.restoreFullAlpha()
            mainStripLayer.compositingFilter = nil
            clockStripLayer.compositingFilter = nil
            let effectiveMain = max(mainDim, focusMenuBarDim)
            let effectiveClock = max(clockDim, focusMenuBarDim)
            mainStripLayer.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: CGFloat(max(0.0, min(0.95, effectiveMain)))).cgColor
            clockStripLayer.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: CGFloat(max(0.0, min(0.95, effectiveClock)))).cgColor

        case .skyLightNativeAlpha:
            // 1. Native SkyLight alpha fades the menu bar glyphs/bar directly against the wallpaper
            let nativeAlpha = Float(1.0 - max(0.0, min(0.92, mainDim)))
            SkyLightMenuBarBridge.shared.setMenuBarAlpha(nativeAlpha)

            // 2. If "Focus Dim Covers Menu Bar" is active, apply the exact Focus Dim opacity over the menu bar strip
            // so the menu bar background seamlessly matches the dimmed desktop below it, AND fades to 0% as the mouse approaches!
            let focusAlpha = CGFloat(max(0.0, min(0.95, focusMenuBarDim)))
            mainStripLayer.compositingFilter = nil
            clockStripLayer.compositingFilter = nil
            mainStripLayer.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: focusAlpha).cgColor
            clockStripLayer.backgroundColor = NSColor.clear.cgColor
        }

        CATransaction.commit()
    }
}

enum MenuBarIntentState: String {
    case dimmed = "Dimmed (Protected)"
    case approaching = "Approaching (50% Intent)"
    case hovered = "Active (100% Hovered)"
    case previewDim = "Test Preview (Forced Dim)"
}

final class MenuBarOverlayController {
    private var windowsByDisplay: [CGDirectDisplayID: NSWindow] = [:]
    private var viewsByDisplay: [CGDirectDisplayID: MenuBarDimView] = [:]

    private var tickTimer: Timer?
    private var lastMousePosition: NSPoint = NSEvent.mouseLocation
    private var lastMouseSampleTime: TimeInterval = CACurrentMediaTime()
    private var smoothedVelocityY: Double = 0.0
    private var lastSignificantMotionTime: TimeInterval = CACurrentMediaTime()

    /// Current animated visibility (0.0 = dimmed, 0.5 = approaching, 1.0 = hovered)
    private(set) var currentVisibility: Double = 0.0
    private(set) var targetVisibility: Double = 0.0
    private(set) var intentState: MenuBarIntentState = .dimmed

    private var previewForceDimUntil: TimeInterval = 0

    func start() {
        rebuildWindows()
        lastMousePosition = NSEvent.mouseLocation
        lastMouseSampleTime = CACurrentMediaTime()
        lastSignificantMotionTime = CACurrentMediaTime()

        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        SkyLightMenuBarBridge.shared.restoreFullAlpha()
        for (_, win) in windowsByDisplay {
            win.orderOut(nil)
        }
        windowsByDisplay.removeAll()
        viewsByDisplay.removeAll()
    }

    func triggerTestPreview(duration: TimeInterval = 5.0) {
        previewForceDimUntil = CACurrentMediaTime() + duration
    }

    func refreshSettings() {
        rebuildWindows()
        for (_, view) in viewsByDisplay {
            view.updateAppearance()
        }
    }

    func rebuildWindows() {
        let settings = AppSettings.shared
        let shouldShowMenuBarWindow = settings.isEnabled &&
            (settings.menuBarDimmingEnabled || (settings.focusBackdropDimmingEnabled && settings.focusDimCoversMenuBar))
        guard shouldShowMenuBarWindow else {
            SkyLightMenuBarBridge.shared.restoreFullAlpha()
            for (_, win) in windowsByDisplay {
                win.orderOut(nil)
            }
            return
        }

        let targetScreens = DisplayBrightnessController.shared.targetScreens()
        let activeIDs = Set(targetScreens.map { $0.displayID })

        for (id, win) in windowsByDisplay where !activeIDs.contains(id) {
            win.orderOut(nil)
            windowsByDisplay.removeValue(forKey: id)
            viewsByDisplay.removeValue(forKey: id)
        }

        for screen in targetScreens {
            let id = screen.displayID
            let menuBarHeight = computeMenuBarHeight(for: screen)
            guard menuBarHeight > 0 else { continue }

            let frame = NSRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - menuBarHeight,
                width: screen.frame.width,
                height: menuBarHeight
            )

            if let existingWin = windowsByDisplay[id], let existingView = viewsByDisplay[id] {
                if existingWin.frame != frame {
                    existingWin.setFrame(frame, display: true)
                }
                existingView.currentVisibility = currentVisibility
                existingView.updateAppearance()
                existingWin.orderFrontRegardless()
            } else {
                let win = NSWindow(
                    contentRect: frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                win.isOpaque = false
                win.backgroundColor = .clear
                win.hasShadow = false
                win.ignoresMouseEvents = true
                // Disable macOS window open/close zoom animation!
                win.animationBehavior = .none
                win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

                let dimView = MenuBarDimView(frame: NSRect(origin: .zero, size: frame.size))
                dimView.currentVisibility = currentVisibility
                win.contentView = dimView
                win.orderFrontRegardless()

                windowsByDisplay[id] = win
                viewsByDisplay[id] = dimView
            }
        }
    }

    private func computeMenuBarHeight(for screen: NSScreen) -> CGFloat {
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        if topInset >= 20 && topInset <= 60 {
            return topInset
        }
        return max(24.0, NSStatusBar.system.thickness)
    }

    private func tick() {
        let settings = AppSettings.shared
        let active = settings.isEnabled &&
            (settings.menuBarDimmingEnabled || (settings.focusBackdropDimmingEnabled && settings.focusDimCoversMenuBar))
        guard active else {
            return
        }

        let now = CACurrentMediaTime()
        let dt = max(0.001, min(0.1, now - lastMouseSampleTime))
        lastMouseSampleTime = now

        let mouse = NSEvent.mouseLocation
        let dx = Double(mouse.x - lastMousePosition.x)
        let dy = Double(mouse.y - lastMousePosition.y)
        let speed = hypot(dx, dy) / dt

        let instVelY = dy / dt
        smoothedVelocityY = smoothedVelocityY * 0.72 + instVelY * 0.28

        if speed > 15.0 {
            lastSignificantMotionTime = now
        }
        lastMousePosition = mouse

        if now < previewForceDimUntil {
            targetVisibility = 0.0
            intentState = .previewDim
        } else if settings.menuBarDimmingEnabled {
            evaluateUserIntent(mouse: mouse, now: now, settings: settings)
        } else {
            // Menu bar dimming is disabled, so Focus Dim stays steady over the menu bar unless hovered
            targetVisibility = 0.0
            intentState = .dimmed
        }

        let diff = targetVisibility - currentVisibility
        if abs(diff) > 0.001 {
            let tau = (targetVisibility > currentVisibility) ? 0.075 : 0.150
            let alpha = 1.0 - exp(-dt / tau)
            currentVisibility += diff * alpha
            if abs(targetVisibility - currentVisibility) < 0.002 {
                currentVisibility = targetVisibility
            }
        }

        // Always update appearance so 100ms Focus Dim transitions on the menu bar animate smoothly at 60Hz
        for (_, view) in viewsByDisplay {
            view.currentVisibility = currentVisibility
        }
    }

    private func evaluateUserIntent(mouse: NSPoint, now: TimeInterval, settings: AppSettings) {
        let targetScreens = DisplayBrightnessController.shared.targetScreens()
        guard let screen = targetScreens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? targetScreens.first else {
            targetVisibility = 0.0
            intentState = .dimmed
            return
        }

        let menuBarHeight = Double(computeMenuBarHeight(for: screen))
        let distFromTop = Double(screen.frame.maxY - mouse.y)
        let distBelowMenuBar = distFromTop - menuBarHeight
        let proxZone = max(20.0, settings.menuBarProximityZone)

        // 1. Directly hovering over the menu bar (with 2pt buffer) -> 100% visibility immediately
        if distBelowMenuBar <= 2.0 && distFromTop >= -10.0 {
            targetVisibility = 1.0
            intentState = .hovered
            return
        }

        // 2. Outside the proximity zone (default > 100px below menu bar) -> 0% visibility (fully dimmed)
        if distBelowMenuBar > proxZone {
            targetVisibility = 0.0
            intentState = .dimmed
            return
        }

        // 3. Inside the proximity zone:
        let timeStationary = now - lastSignificantMotionTime

        if smoothedVelocityY < -45.0 {
            targetVisibility = 0.0
            intentState = .dimmed
            return
        }

        if timeStationary > settings.menuBarStationaryTimeout {
            targetVisibility = 0.0
            intentState = .dimmed
            return
        }

        let proximityProgress = max(0.0, min(1.0, 1.0 - (distBelowMenuBar / proxZone)))
        let maxIntentVis = settings.menuBarIntentVisibility

        if smoothedVelocityY > 20.0 {
            let intentFactor = 0.40 + 0.60 * proximityProgress
            targetVisibility = maxIntentVis * intentFactor
            intentState = .approaching
        } else if intentState == .approaching || intentState == .hovered {
            targetVisibility = maxIntentVis * (0.35 + 0.65 * proximityProgress)
            intentState = .approaching
        } else {
            if distBelowMenuBar < 35.0 && timeStationary < 0.5 {
                targetVisibility = maxIntentVis * 0.5 * proximityProgress
                intentState = .approaching
            } else {
                targetVisibility = 0.0
                intentState = .dimmed
            }
        }
    }
}
