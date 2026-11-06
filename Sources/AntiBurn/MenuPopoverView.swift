import SwiftUI

struct MenuPopoverView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var coordinator = AntiBurnCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: settings.isEnabled ? "sparkles.tv.fill" : "tv.slash")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(settings.isEnabled ? .cyan : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("AntiBurn OLED Guard")
                        .font(.system(size: 14, weight: .bold))
                    Text(coordinator.activeDisplayNames.isEmpty ? "No External OLED Detected" : coordinator.activeDisplayNames.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: $settings.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            // Live Status Pill Card (Idle Timer & Dim Engine only)
            statusSummaryCard

            sectionDivider

            // Tab Picker for Clean Configuration
            Picker("", selection: $settings.selectedPopoverTab) {
                Text("Menu Bar").tag(0)
                if settings.menuBarBlendStyle != .skyLightNativeAlpha {
                    Text("Clock").tag(1)
                }
                Text("Idle Dim").tag(2)
                Text("Focus").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: settings.menuBarBlendStyle) { _, newStyle in
                if newStyle == .skyLightNativeAlpha && settings.selectedPopoverTab == 1 {
                    settings.selectedPopoverTab = 0
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    switch settings.selectedPopoverTab {
                    case 0:
                        menuBarSettingsSection
                    case 1:
                        clockSettingsSection
                    case 2:
                        idleDimSettingsSection
                    case 3:
                        focusSettingsSection
                    default:
                        EmptyView()
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
                .padding(.trailing, 4)
            }
            .frame(height: 270)

            sectionDivider

            // Footer
            HStack(spacing: 12) {
                Toggle("External Only", isOn: $settings.externalMonitorsOnly)
                    .font(.system(size: 11))
                    .controlSize(.small)

                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .font(.system(size: 11))
                    .controlSize(.small)

                Spacer()

                Button(action: {
                    AntiBurnCoordinator.shared.stop()
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 11, weight: .medium))
                        Text("Quit")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .padding(.top, 18)
        .frame(width: 380)
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 4)
    }

    // MARK: - Live Status Summary Card
    private var statusSummaryCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Idle Timer:", systemImage: "timer")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if let blockReason = coordinator.activityStatus.activeBlockReason {
                    Text("Paused: \(blockReason)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.orange)
                } else if coordinator.isIdleCurrentlyDimmed {
                    Text("Screen Dimmed")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.cyan)
                } else {
                    Text("\(Int(coordinator.activityStatus.idleSeconds))s / \(Int(settings.idleTimeoutSeconds))s")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
            }

            HStack {
                Label("Dim Engine:", systemImage: "sun.max.trianglebadge.exclamationmark")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(coordinator.activeIdleMethodName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.75))
        .cornerRadius(8)
    }

    // MARK: - Tab 0: Menu Bar Protection & Intent
    private var menuBarSettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Dim Menu Bar When Inactive", isOn: $settings.menuBarDimmingEnabled)
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Blend Mode")
                    .font(.system(size: 11, weight: .medium))
                Picker("", selection: $settings.menuBarBlendStyle) {
                    ForEach(MenuBarBlendStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()
                .controlSize(.small)

                Text(settings.menuBarBlendStyle.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                sliderRow(
                    title: "Inactive Icon Dimming",
                    value: $settings.menuBarDimStrength,
                    range: 0.05...0.90,
                    format: { "\(Int($0 * 100))% Dimmed (\(Int((1.0 - $0) * 100))% Bright)" }
                )

                HStack(spacing: 6) {
                    Text("Match Dim %:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Button("Match Focus Dim (\(Int(settings.focusBackdropDimStrength * 100))%)") {
                        settings.menuBarDimStrength = settings.focusBackdropDimStrength
                    }
                    .controlSize(.mini)
                    Button("Match Idle Dim (\(Int(settings.idleDimAmount * 100))%)") {
                        settings.menuBarDimStrength = settings.idleDimAmount
                    }
                    .controlSize(.mini)
                }
            }

            sectionDivider

            Text("Mouse Proximity & Velocity Intent")
                .font(.system(size: 11.5, weight: .semibold))

            sliderRow(
                title: "Proximity Zone Distance",
                value: $settings.menuBarProximityZone,
                range: 40...250,
                format: { "\(Int($0)) px" }
            )

            sliderRow(
                title: "Intent Pre-Fade Visibility",
                value: $settings.menuBarIntentVisibility,
                range: 0.20...0.85,
                format: { "\(Int($0 * 100))%" }
            )

            sliderRow(
                title: "Stationary Fade-Out Delay",
                value: $settings.menuBarStationaryTimeout,
                range: 0.4...4.0,
                format: { String(format: "%.1f s", $0) }
            )
        }
    }

    // MARK: - Tab 1: Clock Region Override
    private var clockSettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Custom Brightness for Clock Region", isOn: $settings.clockCustomDimEnabled)
                .font(.system(size: 12, weight: .semibold))

            Text("Keep the clock on the right side of the menu bar more readable than the static Apple icon and left-side menus.")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Highlight Clock Box on Screen (Alignment Guide)", isOn: $settings.showClockRegionGuide)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.cyan)

            sectionDivider

            sliderRow(
                title: "Clock Dimming Strength",
                value: $settings.clockDimStrength,
                range: 0.0...0.85,
                format: { "\(Int($0 * 100))% Dimmed (\(Int((1.0 - $0) * 100))% Bright)" }
            )

            sliderRow(
                title: "Clock Region Width",
                value: $settings.clockWidthPoints,
                range: 60...360,
                format: { "\(Int($0)) pt" }
            )

            sliderRow(
                title: "Right Edge Offset",
                value: $settings.clockRightOffsetPoints,
                range: 0...150,
                format: { "\(Int($0)) pt" }
            )
        }
        .onDisappear {
            settings.showClockRegionGuide = false
        }
    }

    // MARK: - Tab 2: Idle Screen Dimming & Call/Media Detection
    private var idleDimSettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Fade Full Screen When Idle", isOn: $settings.idleDimmingEnabled)
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Idle Timeout")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(formatDuration(settings.idleTimeoutSeconds))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.idleTimeoutSeconds, in: 15...900, step: 15)
                    .controlSize(.small)

                HStack(spacing: 6) {
                    ForEach([30.0, 60.0, 180.0, 300.0, 600.0], id: \.self) { preset in
                        Button(formatDuration(preset)) {
                            settings.idleTimeoutSeconds = preset
                        }
                        .controlSize(.mini)
                    }
                }
                .padding(.top, 2)
            }

            sliderRow(
                title: "Screen Dimming Amount",
                value: $settings.idleDimAmount,
                range: 0.15...0.85,
                format: { "\(Int($0 * 100))%" }
            )

            Toggle("Use Native HDR Brightness Control When in HDR", isOn: $settings.preferHardwareBrightnessInHDR)
                .font(.system(size: 11))

            sectionDivider

            Toggle("Smart Pause During Calls & Video", isOn: $settings.pauseIdleOnCallsAndMedia)
                .font(.system(size: 11.5, weight: .semibold))

            if settings.pauseIdleOnCallsAndMedia {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Pause when Mic or Camera is active (Teams, Zoom, etc.)", isOn: $settings.pauseOnActiveMicOrCamera)
                        .font(.system(size: 10.5))
                    Toggle("Pause when Video prevents display sleep (Windowed or Fullscreen)", isOn: $settings.pauseOnVideoSleepAssertion)
                        .font(.system(size: 10.5))
                    Toggle("Pause during any active audio output (Music/Podcasts)", isOn: $settings.pauseOnAudioPlayback)
                        .font(.system(size: 10.5))
                }
                .padding(.leading, 8)
            }
        }
    }

    // MARK: - Tab 3: Active Window Focus Backdrop (Idea #1)
    private var focusSettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Dim Background Behind Focused Window", isOn: $settings.focusBackdropDimmingEnabled)
                .font(.system(size: 12, weight: .semibold))

            Text("Places a soft dimming layer right behind your active window so static background windows and desktop wallpaper wear slower while you work.")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                sliderRow(
                    title: "Backdrop Dimming Opacity",
                    value: $settings.focusBackdropDimStrength,
                    range: 0.10...0.75,
                    format: { "\(Int($0 * 100))%" }
                )

                HStack(spacing: 6) {
                    Text("Match Dim %:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Button("Match Menu Bar (\(Int(settings.menuBarDimStrength * 100))%)") {
                        settings.focusBackdropDimStrength = min(0.75, max(0.10, settings.menuBarDimStrength))
                    }
                    .controlSize(.mini)
                    Button("Match Idle Dim (\(Int(settings.idleDimAmount * 100))%)") {
                        settings.focusBackdropDimStrength = min(0.75, max(0.10, settings.idleDimAmount))
                    }
                    .controlSize(.mini)
                }
            }

            Picker("Scope", selection: $settings.focusSingleWindowOnly) {
                Text("Keep Only Frontmost Window Bright").tag(true)
                Text("Keep All Windows of Active App Bright").tag(false)
            }
            .pickerStyle(.radioGroup)
            .font(.system(size: 11))

            sectionDivider

            Toggle("Also Cover Menu Bar With Focus Dim", isOn: $settings.focusDimCoversMenuBar)
                .font(.system(size: 11.5, weight: .semibold))

            Text("Extends Focus Dim over the menu bar so the wallpaper behind the menu bar matches the dimmed desktop below, while still un-dimming to 100% when your mouse approaches the menu bar.")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers
    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 {
            return "\(s)s"
        } else if s % 60 == 0 {
            return "\(s / 60)m"
        } else {
            return "\(s / 60)m \(s % 60)s"
        }
    }
}
