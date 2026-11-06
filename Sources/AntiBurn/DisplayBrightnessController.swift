import AppKit
import CoreGraphics

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    var isBuiltInDisplay: Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    var isHDRActive: Bool {
        // In macOS, maximumExtendedDynamicRangeColorComponentValue > 1.0 indicates EDR/HDR headroom is currently active,
        // or maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0 when HDR mode is enabled in System Settings.
        return maximumExtendedDynamicRangeColorComponentValue > 1.0 ||
               maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
    }
}

final class DisplayBrightnessController {
    static let shared = DisplayBrightnessController()

    private typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightnessFunc = @convention(c) (CGDirectDisplayID) -> Bool

    private var getBrightnessSym: GetBrightnessFunc?
    private var setBrightnessSym: SetBrightnessFunc?
    private var canChangeBrightnessSym: CanChangeBrightnessFunc?

    /// Stores the user's pre-dim hardware brightness per display so we always restore accurately
    private var savedBaselineBrightness: [CGDirectDisplayID: Float] = [:]
    /// Current animated hardware brightness target per display
    private var activeCustomBrightness: [CGDirectDisplayID: Float] = [:]

    private init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
            if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
                getBrightnessSym = unsafeBitCast(sym, to: GetBrightnessFunc.self)
            }
            if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
                setBrightnessSym = unsafeBitCast(sym, to: SetBrightnessFunc.self)
            }
            if let sym = dlsym(handle, "DisplayServicesCanChangeBrightness") {
                canChangeBrightnessSym = unsafeBitCast(sym, to: CanChangeBrightnessFunc.self)
            }
        }
    }

    /// Returns all screens that AntiBurn should protect based on user settings
    func targetScreens() -> [NSScreen] {
        let externalOnly = AppSettings.shared.externalMonitorsOnly
        let screens = NSScreen.screens
        if externalOnly {
            let externals = screens.filter { !$0.isBuiltInDisplay }
            // If an external monitor is plugged in, return externals; if none plugged in, return empty
            return externals
        }
        return screens
    }

    func canControlHardwareBrightness(for displayID: CGDirectDisplayID) -> Bool {
        guard let canChange = canChangeBrightnessSym,
              let getB = getBrightnessSym,
              setBrightnessSym != nil else {
            return false
        }
        guard canChange(displayID) else { return false }
        var current: Float = -1
        let err = getB(displayID, &current)
        return err == 0 && current >= 0.0 && current <= 1.0
    }

    func getHardwareBrightness(for displayID: CGDirectDisplayID) -> Float? {
        guard let getB = getBrightnessSym else { return nil }
        var current: Float = -1
        let err = getB(displayID, &current)
        guard err == 0, current >= 0.0 else { return nil }
        return current
    }

    @discardableResult
    func setHardwareBrightness(_ value: Float, for displayID: CGDirectDisplayID) -> Bool {
        guard let setB = setBrightnessSym else { return false }
        let clamped = max(0.02, min(1.0, value))
        let err = setB(displayID, clamped)
        if err == 0 {
            activeCustomBrightness[displayID] = clamped
            return true
        }
        return false
    }

    /// Captures the current user brightness before beginning an idle dim cycle
    func captureBaselineIfNeeded(for displayID: CGDirectDisplayID) {
        if savedBaselineBrightness[displayID] == nil {
            if let current = getHardwareBrightness(for: displayID) {
                savedBaselineBrightness[displayID] = current
            }
        }
    }

    /// Applies an interpolated dim factor `progress` (0.0 = normal baseline, 1.0 = dimmed by `dimFraction`)
    func applyDimProgress(progress: Double, dimFraction: Double, for displayID: CGDirectDisplayID) -> Bool {
        captureBaselineIfNeeded(for: displayID)
        guard let baseline = savedBaselineBrightness[displayID] else { return false }

        // If progress == 0, restore baseline and clear saved state
        if progress <= 0.001 {
            let ok = setHardwareBrightness(baseline, for: displayID)
            savedBaselineBrightness.removeValue(forKey: displayID)
            activeCustomBrightness.removeValue(forKey: displayID)
            return ok
        }

        let targetMultiplier = 1.0 - (dimFraction * min(1.0, max(0.0, progress)))
        let targetBrightness = baseline * Float(targetMultiplier)
        return setHardwareBrightness(targetBrightness, for: displayID)
    }

    /// Immediately restores all modified displays to their baseline brightness (e.g., on app quit)
    func restoreAllBaselines() {
        for (displayID, baseline) in savedBaselineBrightness {
            _ = setHardwareBrightness(baseline, for: displayID)
        }
        savedBaselineBrightness.removeAll()
        activeCustomBrightness.removeAll()
    }
}
