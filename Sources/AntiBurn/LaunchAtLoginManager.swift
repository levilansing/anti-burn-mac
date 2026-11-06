import Foundation
import ServiceManagement

final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let label = "com.antiburn.mac"

    private var plistURL: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private init() {}

    func setEnabled(_ enabled: Bool) {
        if enabled {
            installLaunchAgent()
            try? SMAppService.mainApp.register()
        } else {
            removeLaunchAgent()
            try? SMAppService.mainApp.unregister()
        }
    }

    private func installLaunchAgent() {
        guard let execPath = Bundle.main.executablePath else { return }
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plistDict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [execPath],
            "WorkingDirectory": FileManager.default.currentDirectoryPath,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]

        if let data = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) {
            try? data.write(to: plistURL, options: .atomic)
        }
    }

    private func removeLaunchAgent() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
