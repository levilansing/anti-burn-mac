import AppKit
import QuartzCore

enum IdleDimMethod: String {
    case hardwareHDRBrightness = "Native HDR / Hardware Brightness"
    case softwareOverlay = "Full-Screen Dimming Overlay"
}

final class IdleDimmerController {
    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]

    /// Current animated dim progress (0.0 = normal, 1.0 = fully dimmed to configured %)
    private(set) var currentDimProgress: Double = 0.0
    private(set) var targetDimProgress: Double = 0.0
    private(set) var isIdleDimmed: Bool = false
    private(set) var isTestPreviewActive: Bool = false

    private var previewEndTime: TimeInterval = 0
    private var previewInitialIdleSeconds: Double = 0
    private var animTimer: Timer?
    private var lastFrameTime: TimeInterval = CACurrentMediaTime()

    func start() {
        lastFrameTime = CACurrentMediaTime()
        animTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    func stop() {
        animTimer?.invalidate()
        animTimer = nil
        DisplayBrightnessController.shared.restoreAllBaselines()
        for (_, win) in overlayWindows {
            win.orderOut(nil)
        }
        overlayWindows.removeAll()
        currentDimProgress = 0.0
        targetDimProgress = 0.0
        isIdleDimmed = false
        isTestPreviewActive = false
    }

    /// Triggers an immediate 5-second test of the full-screen idle dimmer
    func triggerTestPreview(duration: TimeInterval = 5.0) {
        isTestPreviewActive = true
        previewEndTime = CACurrentMediaTime() + duration
        previewInitialIdleSeconds = ActivityDetector.shared.systemIdleSeconds()
        targetDimProgress = 1.0
        isIdleDimmed = true
    }

    func cancelTestPreview() {
        isTestPreviewActive = false
        targetDimProgress = 0.0
        isIdleDimmed = false
    }

    /// Called periodically by the coordinator with the latest activity status
    func evaluateIdleState(activity: ActivityStatus) {
        let settings = AppSettings.shared
        guard settings.isEnabled && settings.idleDimmingEnabled else {
            if targetDimProgress > 0 {
                targetDimProgress = 0.0
                isIdleDimmed = false
                isTestPreviewActive = false
            }
            return
        }

        let now = CACurrentMediaTime()

        if isTestPreviewActive {
            // End preview if timer expired OR if user clicked/typed after the first 0.8s grace period
            let elapsed = durationSincePreviewStarted(now: now)
            if now >= previewEndTime || (elapsed > 0.8 && activity.idleSeconds < 0.15) {
                isTestPreviewActive = false
            } else {
                targetDimProgress = 1.0
                isIdleDimmed = true
                return
            }
        }

        // Check if media playback or active call should block idle dimming
        if activity.shouldBlockIdleDimming {
            targetDimProgress = 0.0
            isIdleDimmed = false
            return
        }

        if activity.idleSeconds >= settings.idleTimeoutSeconds {
            targetDimProgress = 1.0
            isIdleDimmed = true
        } else {
            targetDimProgress = 0.0
            isIdleDimmed = false
        }
    }

    private func durationSincePreviewStarted(now: TimeInterval) -> TimeInterval {
        return max(0, 5.0 - (previewEndTime - now))
    }

    func activeDimMethod(for screen: NSScreen) -> IdleDimMethod {
        let settings = AppSettings.shared
        let id = screen.displayID
        if settings.preferHardwareBrightnessInHDR &&
           screen.isHDRActive &&
           DisplayBrightnessController.shared.canControlHardwareBrightness(for: id) {
            return .hardwareHDRBrightness
        }
        return .softwareOverlay
    }

    private func tickAnimation() {
        let now = CACurrentMediaTime()
        let dt = max(0.001, min(0.1, now - lastFrameTime))
        lastFrameTime = now

        if isTestPreviewActive && now >= previewEndTime {
            isTestPreviewActive = false
            targetDimProgress = 0.0
            isIdleDimmed = false
        }

        let diff = targetDimProgress - currentDimProgress
        guard abs(diff) > 0.0005 else {
            if targetDimProgress == 0.0 && currentDimProgress != 0.0 {
                currentDimProgress = 0.0
                applyDimProgressToScreens(0.0)
            }
            return
        }

        // Fast wake-up (~110ms time constant), smooth gentle fade-to-dim (~350ms time constant)
        let tau = (targetDimProgress < currentDimProgress) ? 0.09 : 0.28
        let alpha = 1.0 - exp(-dt / tau)
        currentDimProgress += diff * alpha

        if abs(targetDimProgress - currentDimProgress) < 0.002 {
            currentDimProgress = targetDimProgress
        }

        applyDimProgressToScreens(currentDimProgress)
    }

    private func applyDimProgressToScreens(_ progress: Double) {
        let settings = AppSettings.shared
        let dimFraction = max(0.05, min(0.90, settings.idleDimAmount))
        let screens = DisplayBrightnessController.shared.targetScreens()
        let activeIDs = Set(screens.map { $0.displayID })

        // Clean up disconnected screens
        for (id, win) in overlayWindows where !activeIDs.contains(id) {
            win.orderOut(nil)
            overlayWindows.removeValue(forKey: id)
        }

        if progress <= 0.001 {
            DisplayBrightnessController.shared.restoreAllBaselines()
            for (_, win) in overlayWindows {
                win.alphaValue = 0.0
                win.orderOut(nil)
            }
            return
        }

        for screen in screens {
            let id = screen.displayID
            let method = activeDimMethod(for: screen)

            switch method {
            case .hardwareHDRBrightness:
                // Hide software overlay if it was shown previously
                if let win = overlayWindows[id] {
                    win.alphaValue = 0.0
                    win.orderOut(nil)
                }
                let ok = DisplayBrightnessController.shared.applyDimProgress(
                    progress: progress,
                    dimFraction: dimFraction,
                    for: id
                )
                if !ok {
                    // Fallback to software overlay if hardware brightness call failed
                    applySoftwareOverlay(for: screen, alpha: CGFloat(progress * dimFraction))
                }

            case .softwareOverlay:
                // Ensure hardware baseline is restored if user toggled preference mid-dim
                _ = DisplayBrightnessController.shared.applyDimProgress(progress: 0.0, dimFraction: dimFraction, for: id)
                applySoftwareOverlay(for: screen, alpha: CGFloat(progress * dimFraction))
            }
        }
    }

    private func applySoftwareOverlay(for screen: NSScreen, alpha: CGFloat) {
        let id = screen.displayID
        let win: NSWindow
        if let existing = overlayWindows[id] {
            win = existing
            if win.frame != screen.frame {
                win.setFrame(screen.frame, display: true)
            }
        } else {
            let newWin = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            newWin.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            newWin.isOpaque = false
            newWin.backgroundColor = .black
            newWin.hasShadow = false
            newWin.ignoresMouseEvents = true
            newWin.animationBehavior = .none
            newWin.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            overlayWindows[id] = newWin
            win = newWin
        }

        win.alphaValue = alpha
        if alpha > 0.002 {
            win.orderFrontRegardless()
        } else {
            win.orderOut(nil)
        }
    }
}
