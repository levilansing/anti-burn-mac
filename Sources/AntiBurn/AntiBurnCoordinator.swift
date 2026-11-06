import AppKit
import Combine

final class AntiBurnCoordinator: ObservableObject {
    static let shared = AntiBurnCoordinator()

    let menuBarController = MenuBarOverlayController()
    let idleDimmerController = IdleDimmerController()
    let focusBackdropController = FocusBackdropController()

    @Published var activityStatus = ActivityStatus()
    @Published var menuBarStateText: String = "Dimmed (Protected)"
    @Published var menuBarVisibilityPercent: Int = 0
    @Published var activeDisplayNames: [String] = []
    @Published var isHDRActiveOnPrimaryTarget: Bool = false
    @Published var activeIdleMethodName: String = "Native HDR / Hardware Brightness"
    @Published var isIdleCurrentlyDimmed: Bool = false

    private var statusTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        menuBarController.start()
        idleDimmerController.start()
        focusBackdropController.start()

        refreshDisplayInfo()

        // Subscribe to settings changes
        AppSettings.shared.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.onSettingsChanged()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        statusTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        pollStatus()
    }

    func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        menuBarController.stop()
        idleDimmerController.stop()
        focusBackdropController.stop()
    }

    @objc private func screensDidChange(_ note: Notification) {
        refreshDisplayInfo()
        menuBarController.rebuildWindows()
        focusBackdropController.updateBackdropOrdering()
    }

    private func onSettingsChanged() {
        refreshDisplayInfo()
        menuBarController.refreshSettings()
        focusBackdropController.updateBackdropOrdering()
        pollStatus()
    }

    func refreshDisplayInfo() {
        let targets = DisplayBrightnessController.shared.targetScreens()
        activeDisplayNames = targets.map { screen in
            let hdrTag = screen.isHDRActive ? "HDR" : "SDR"
            return "\(screen.localizedName) (\(hdrTag))"
        }
        if let first = targets.first {
            isHDRActiveOnPrimaryTarget = first.isHDRActive
            activeIdleMethodName = idleDimmerController.activeDimMethod(for: first).rawValue
        } else {
            isHDRActiveOnPrimaryTarget = false
            activeIdleMethodName = "No Target External Display"
        }
    }

    private func pollStatus() {
        let status = ActivityDetector.shared.currentActivityStatus()
        self.activityStatus = status

        idleDimmerController.evaluateIdleState(activity: status)
        isIdleCurrentlyDimmed = idleDimmerController.isIdleDimmed
        menuBarStateText = menuBarController.intentState.rawValue
        menuBarVisibilityPercent = Int((menuBarController.currentVisibility * 100.0).rounded())
    }

    // MARK: - Instant Test Triggers

    func testMenuBarDimming() {
        menuBarController.triggerTestPreview(duration: 5.0)
        pollStatus()
    }

    func testIdleScreenDimming() {
        idleDimmerController.triggerTestPreview(duration: 5.0)
        pollStatus()
    }

    func testFocusBackdropDimming() {
        focusBackdropController.triggerTestPreview(duration: 5.0)
        pollStatus()
    }
}
