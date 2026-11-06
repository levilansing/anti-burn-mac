import Foundation
import Combine

enum MenuBarBlendStyle: String, CaseIterable, Identifiable {
    case classicAlpha = "alpha"
    case skyLightNativeAlpha = "skylight"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classicAlpha:
            return "Classic Translucent Dimming (Recommended)"
        case .skyLightNativeAlpha:
            return "Native SkyLight Menu Bar Alpha (Private API)"
        }
    }

    var subtitle: String {
        switch self {
        case .classicAlpha:
            return "Clean translucent dimming strip over the menu bar with independent Clock region support and 1:1 opacity matching with Focus & Idle Dim."
        case .skyLightNativeAlpha:
            return "Uses macOS private SLSSetMenuBarInsetAndAlpha API to fade the native menu bar window directly against your wallpaper (no dark rectangle)."
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let settingsFileURL: URL
    private var isLoading = true
    private var persistedDict: [String: Any] = [:]

    // MARK: - General / Display
    @Published var isEnabled: Bool { didSet { save("isEnabled", isEnabled) } }
    @Published var externalMonitorsOnly: Bool { didSet { save("externalMonitorsOnly", externalMonitorsOnly) } }
    @Published var launchAtLogin: Bool { didSet { save("launchAtLogin", launchAtLogin); LaunchAtLoginManager.shared.setEnabled(launchAtLogin) } }

    // MARK: - Menu Bar Dimming & Intent Detection
    @Published var menuBarDimmingEnabled: Bool { didSet { save("menuBarDimmingEnabled", menuBarDimmingEnabled) } }
    @Published var menuBarBlendStyle: MenuBarBlendStyle { didSet { save("menuBarBlendStyle", menuBarBlendStyle.rawValue) } }
    /// How much to dim the menu bar when inactive (0.0 = no dim, 0.85 = very dim; default 0.60 means icons capped to 40% brightness)
    @Published var menuBarDimStrength: Double { didSet { save("menuBarDimStrength", menuBarDimStrength) } }
    /// Proximity distance in points from the top of the screen where intent detection starts (default 100pt)
    @Published var menuBarProximityZone: Double { didSet { save("menuBarProximityZone", menuBarProximityZone) } }
    /// Target visibility (0..1) when moving towards the menu bar inside the proximity zone (default 0.50 = 50%)
    @Published var menuBarIntentVisibility: Double { didSet { save("menuBarIntentVisibility", menuBarIntentVisibility) } }
    /// Seconds before a stationary cursor inside the proximity zone fades the menu bar back out (default 1.2s)
    @Published var menuBarStationaryTimeout: Double { didSet { save("menuBarStationaryTimeout", menuBarStationaryTimeout) } }

    // MARK: - Clock Region Override
    @Published var clockCustomDimEnabled: Bool { didSet { save("clockCustomDimEnabled", clockCustomDimEnabled) } }
    /// Separate dim strength for the clock region on the far right (default 0.30 so clock remains more visible)
    @Published var clockDimStrength: Double { didSet { save("clockDimStrength", clockDimStrength) } }
    /// Width of the clock region on the right end of the menu bar in points (default 165pt)
    @Published var clockWidthPoints: Double { didSet { save("clockWidthPoints", clockWidthPoints) } }
    /// Optional right offset in points if Spotlight/Control Center sits to the right of or inside the clock zone (default 0pt)
    @Published var clockRightOffsetPoints: Double { didSet { save("clockRightOffsetPoints", clockRightOffsetPoints) } }
    /// Visual highlight guide while configuring clock dimensions
    @Published var showClockRegionGuide: Bool = false
    /// Selected tab in the popover UI
    @Published var selectedPopoverTab: Int = 0

    // MARK: - Idle Full-Screen Dimming
    @Published var idleDimmingEnabled: Bool { didSet { save("idleDimmingEnabled", idleDimmingEnabled) } }
    /// Idle timeout in seconds before dimming full screen (default 180s = 3 minutes)
    @Published var idleTimeoutSeconds: Double { didSet { save("idleTimeoutSeconds", idleTimeoutSeconds) } }
    /// How much to reduce brightness when idle (default 0.50 = 50% reduction)
    @Published var idleDimAmount: Double { didSet { save("idleDimAmount", idleDimAmount) } }
    /// Prefer native HDR / DisplayServices hardware brightness when available
    @Published var preferHardwareBrightnessInHDR: Bool { didSet { save("preferHardwareBrightnessInHDR", preferHardwareBrightnessInHDR) } }

    // MARK: - Smart Media & Call Exclusion
    @Published var pauseIdleOnCallsAndMedia: Bool { didSet { save("pauseIdleOnCallsAndMedia", pauseIdleOnCallsAndMedia) } }
    @Published var pauseOnActiveMicOrCamera: Bool { didSet { save("pauseOnActiveMicOrCamera", pauseOnActiveMicOrCamera) } }
    @Published var pauseOnVideoSleepAssertion: Bool { didSet { save("pauseOnVideoSleepAssertion", pauseOnVideoSleepAssertion) } }
    @Published var pauseOnAudioPlayback: Bool { didSet { save("pauseOnAudioPlayback", pauseOnAudioPlayback) } }

    // MARK: - Active Window Focus Backdrop Dimming (Idea #1)
    @Published var focusBackdropDimmingEnabled: Bool { didSet { save("focusBackdropDimmingEnabled", focusBackdropDimmingEnabled) } }
    /// Opacity of the dim backdrop behind the focused window (default 0.35 = 35%)
    @Published var focusBackdropDimStrength: Double { didSet { save("focusBackdropDimStrength", focusBackdropDimStrength) } }
    /// Whether to dim all windows of non-active apps or even non-frontmost windows of the same app
    @Published var focusSingleWindowOnly: Bool { didSet { save("focusSingleWindowOnly", focusSingleWindowOnly) } }
    /// Whether Focus Dim also covers the menu bar strip (fading out when mouse approaches/hovers the menu bar)
    @Published var focusDimCoversMenuBar: Bool { didSet { save("focusDimCoversMenuBar", focusDimCoversMenuBar) } }

    private init() {
        let cwdSettingsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("settings.json")
        if FileManager.default.isWritableFile(atPath: FileManager.default.currentDirectoryPath) {
            self.settingsFileURL = cwdSettingsURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let folder = appSupport.appendingPathComponent("AntiBurn", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.settingsFileURL = folder.appendingPathComponent("settings.json")
        }

        var loaded: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsFileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            loaded = json
        }
        self.persistedDict = loaded

        self.isEnabled = loaded["isEnabled"] as? Bool ?? true
        self.externalMonitorsOnly = loaded["externalMonitorsOnly"] as? Bool ?? true
        self.launchAtLogin = loaded["launchAtLogin"] as? Bool ?? true

        self.menuBarDimmingEnabled = loaded["menuBarDimmingEnabled"] as? Bool ?? true
        let rawStyle = loaded["menuBarBlendStyle"] as? String ?? MenuBarBlendStyle.skyLightNativeAlpha.rawValue
        self.menuBarBlendStyle = MenuBarBlendStyle(rawValue: rawStyle) ?? .skyLightNativeAlpha
        self.menuBarDimStrength = loaded["menuBarDimStrength"] as? Double ?? 0.62
        self.menuBarProximityZone = loaded["menuBarProximityZone"] as? Double ?? 100.0
        self.menuBarIntentVisibility = loaded["menuBarIntentVisibility"] as? Double ?? 0.50
        self.menuBarStationaryTimeout = loaded["menuBarStationaryTimeout"] as? Double ?? 1.2

        self.clockCustomDimEnabled = loaded["clockCustomDimEnabled"] as? Bool ?? true
        self.clockDimStrength = loaded["clockDimStrength"] as? Double ?? 0.28
        self.clockWidthPoints = loaded["clockWidthPoints"] as? Double ?? 160.0
        self.clockRightOffsetPoints = loaded["clockRightOffsetPoints"] as? Double ?? 0.0

        self.idleDimmingEnabled = loaded["idleDimmingEnabled"] as? Bool ?? true
        self.idleTimeoutSeconds = loaded["idleTimeoutSeconds"] as? Double ?? 180.0
        self.idleDimAmount = loaded["idleDimAmount"] as? Double ?? 0.50
        self.preferHardwareBrightnessInHDR = loaded["preferHardwareBrightnessInHDR"] as? Bool ?? true

        self.pauseIdleOnCallsAndMedia = loaded["pauseIdleOnCallsAndMedia"] as? Bool ?? true
        self.pauseOnActiveMicOrCamera = loaded["pauseOnActiveMicOrCamera"] as? Bool ?? true
        self.pauseOnVideoSleepAssertion = loaded["pauseOnVideoSleepAssertion"] as? Bool ?? true
        self.pauseOnAudioPlayback = loaded["pauseOnAudioPlayback"] as? Bool ?? false

        self.focusBackdropDimmingEnabled = loaded["focusBackdropDimmingEnabled"] as? Bool ?? false
        self.focusBackdropDimStrength = loaded["focusBackdropDimStrength"] as? Double ?? 0.35
        self.focusSingleWindowOnly = loaded["focusSingleWindowOnly"] as? Bool ?? true
        self.focusDimCoversMenuBar = loaded["focusDimCoversMenuBar"] as? Bool ?? true

        self.isLoading = false
    }

    private func save(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        persistedDict[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: persistedDict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsFileURL, options: .atomic)
        }
    }
}
