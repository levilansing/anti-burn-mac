import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import CoreAudio
import CoreMediaIO

struct ActivityStatus: Equatable {
    var idleSeconds: Double = 0
    var isVideoOrDisplaySleepPrevented: Bool = false
    var sleepAssertionProcessName: String? = nil
    var isMicActive: Bool = false
    var isCameraActive: Bool = false
    var isAudioOutputActive: Bool = false

    var shouldBlockIdleDimming: Bool {
        let settings = AppSettings.shared
        guard settings.pauseIdleOnCallsAndMedia else { return false }

        if settings.pauseOnVideoSleepAssertion && isVideoOrDisplaySleepPrevented {
            return true
        }
        if settings.pauseOnActiveMicOrCamera && (isMicActive || isCameraActive) {
            return true
        }
        if settings.pauseOnAudioPlayback && isAudioOutputActive {
            return true
        }
        return false
    }

    var activeBlockReason: String? {
        let settings = AppSettings.shared
        guard settings.pauseIdleOnCallsAndMedia else { return nil }

        if settings.pauseOnActiveMicOrCamera {
            if isMicActive && isCameraActive {
                return "In a Call (Mic + Camera Active)"
            } else if isMicActive {
                return "In a Call (Microphone Active)"
            } else if isCameraActive {
                return "In a Call (Camera Active)"
            }
        }
        if settings.pauseOnVideoSleepAssertion && isVideoOrDisplaySleepPrevented {
            if let proc = sleepAssertionProcessName {
                return "Media / Call Active (\(proc))"
            }
            return "Media / Display Assertion Active"
        }
        if settings.pauseOnAudioPlayback && isAudioOutputActive {
            return "Audio Output Active"
        }
        return nil
    }
}

final class ActivityDetector {
    static let shared = ActivityDetector()

    private init() {}

    /// Returns seconds since the user last moved the mouse, clicked, scrolled, or pressed a key.
    func systemIdleSeconds() -> Double {
        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
            .keyDown,
            .flagsChanged
        ]
        var minIdle = Double.greatestFiniteMagnitude
        for type in types {
            let secs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            if secs < minIdle {
                minIdle = secs
            }
        }
        return minIdle == Double.greatestFiniteMagnitude ? 0 : minIdle
    }

    func currentActivityStatus() -> ActivityStatus {
        let idle = systemIdleSeconds()
        let (hasDisplayAssertion, procName) = checkDisplaySleepAssertions()
        let (micActive, audioOutActive) = checkAudioActivity()
        let camActive = checkCameraActivity()

        return ActivityStatus(
            idleSeconds: idle,
            isVideoOrDisplaySleepPrevented: hasDisplayAssertion,
            sleepAssertionProcessName: procName,
            isMicActive: micActive,
            isCameraActive: camActive,
            isAudioOutputActive: audioOutActive
        )
    }

    /// Checks IOKit power assertions for any process holding PreventUserIdleDisplaySleep or NoDisplaySleepAssertion
    /// (used by Safari, Chrome, Teams, Zoom, QuickTime, VLC, IINA, etc. during video playback or calls, even in a window).
    private func checkDisplaySleepAssertions() -> (Bool, String?) {
        var assertionsByProcess: Unmanaged<CFDictionary>?
        let kr = IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard kr == kIOReturnSuccess,
              let dict = assertionsByProcess?.takeRetainedValue() as? [Int: [[String: Any]]] else {
            return (false, nil)
        }

        let displayTypes: Set<String> = [
            "PreventUserIdleDisplaySleep",
            "NoDisplaySleepAssertion",
            "kIOPMAssertionTypePreventUserIdleDisplaySleep",
            "kIOPMAssertionTypeNoDisplaySleep"
        ]

        let myPID = Int(ProcessInfo.processInfo.processIdentifier)

        for (pid, assertions) in dict {
            if pid == myPID { continue }
            for assertion in assertions {
                let trueType = assertion["AssertionTrueType"] as? String ?? ""
                let assertType = assertion["AssertionType"] as? String ?? ""
                if displayTypes.contains(trueType) || displayTypes.contains(assertType) {
                    let proc = assertion["Process Name"] as? String ?? "PID \(pid)"
                    // Ignore core OS daemon false positives if any, though powerd/WindowServer rarely hold PreventUserIdleDisplaySleep without a client
                    if proc == "WindowServer" || proc == "powerd" { continue }
                    return (true, proc)
                }
            }
        }
        return (false, nil)
    }

    /// Checks CoreAudio devices for active input (microphone in use by Teams/Zoom/etc.) and active output.
    private func checkAudioActivity() -> (micActive: Bool, outputActive: Bool) {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return (false, false)
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &devices) == noErr else {
            return (false, false)
        }

        var micRunning = false
        var outputRunning = false

        for dev in devices {
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunning: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(dev, &runAddr, 0, nil, &runSize, &isRunning) == noErr,
                  isRunning != 0 else {
                continue
            }

            // Check if device has input streams
            var inAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(dev, &inAddr, 0, nil, &inSize)
            let inStreams = inSize / UInt32(MemoryLayout<AudioStreamID>.size)

            // Check if device has output streams
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(dev, &outAddr, 0, nil, &outSize)
            let outStreams = outSize / UInt32(MemoryLayout<AudioStreamID>.size)

            if inStreams > 0 {
                micRunning = true
            }
            if outStreams > 0 {
                outputRunning = true
            }
        }

        return (micRunning, outputRunning)
    }

    /// Checks CoreMediaIO for any webcam/camera currently running.
    private func checkCameraActivity() -> Bool {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }

        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var devs = [CMIODeviceID](repeating: 0, count: count)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, dataSize, &dataSize, &devs) == noErr else {
            return false
        }

        for d in devs {
            var runProp = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var isRunning: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(d, &runProp, 0, nil, runSize, &runSize, &isRunning) == noErr && isRunning != 0 {
                return true
            }
        }
        return false
    }
}
