import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import Darwin
import SwiftUI

private func hudEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let controller = Unmanaged<HUDController>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        controller.reenableTapFromCallback()
        return Unmanaged.passUnretained(event)
    }

    // NX_SYSDEFINED == 14
    guard type.rawValue == 14 else {
        return Unmanaged.passUnretained(event)
    }

    guard let nsEvent = NSEvent(cgEvent: event),
          nsEvent.type == .systemDefined,
          nsEvent.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }

    let data1 = nsEvent.data1
    let keyCode = Int((data1 & 0xFFFF0000) >> 16)
    let keyState = (data1 & 0x0000FF00) >> 8
    let isKeyDown = (keyState == 0x0A)
    let flags = nsEvent.modifierFlags
    let isFineStep = flags.contains(.option) && flags.contains(.shift)

    return controller.handleMediaKeyEvent(
        keyCode: keyCode,
        isKeyDown: isKeyDown,
        isFineStep: isFineStep,
        originalEvent: event
    )
}

@MainActor
final class HUDController: ObservableObject {
    static let shared = HUDController()

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestTrust() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: kCFBooleanTrue as Any] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // Media key codes from IOKit/hidsystem/ev_keymap.h
    private static let nxKeyTypeSoundUp = 0
    private static let nxKeyTypeSoundDown = 1
    private static let nxKeyTypeBrightnessUp = 2
    private static let nxKeyTypeBrightnessDown = 3
    private static let nxKeyTypeMute = 7

    // Virtual main volume property selector ('vmvc')
    private static let virtualMainVolumeSelector: AudioObjectPropertySelector =
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    private nonisolated(unsafe) var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // DisplayServices function pointers
    private typealias DisplayServicesGetBrightnessFn = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32

    private typealias DisplayServicesSetBrightnessFn = @convention(c) (
        CGDirectDisplayID,
        Float
    ) -> Int32

    private var dsHandle: UnsafeMutableRawPointer?
    private nonisolated(unsafe) var dsGetBrightness: DisplayServicesGetBrightnessFn?
    private nonisolated(unsafe) var dsSetBrightness: DisplayServicesSetBrightnessFn?
    private var didAttemptLoadDS = false

    private init() {}

    func start() {
        guard Self.isTrusted else {
            Self.requestTrust()
            return
        }
        loadDisplayServicesIfNeeded()
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << 14) // CGEventType(rawValue: 14) / NX_SYSDEFINED
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hudEventTapCallback,
            userInfo: selfPtr
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    nonisolated fileprivate func reenableTapFromCallback() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    nonisolated fileprivate func handleMediaKeyEvent(
        keyCode: Int,
        isKeyDown: Bool,
        isFineStep: Bool,
        originalEvent: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let step: Float = isFineStep ? (1.0 / 64.0) : (1.0 / 16.0)

        switch keyCode {
        case Self.nxKeyTypeSoundUp:
            if isKeyDown {
                Task { @MainActor in
                    self.adjustVolume(delta: step)
                }
            }
            return nil

        case Self.nxKeyTypeSoundDown:
            if isKeyDown {
                Task { @MainActor in
                    self.adjustVolume(delta: -step)
                }
            }
            return nil

        case Self.nxKeyTypeMute:
            if isKeyDown {
                Task { @MainActor in
                    self.toggleMute()
                }
            }
            return nil

        case Self.nxKeyTypeBrightnessUp:
            guard isBrightnessAvailable() else {
                return Unmanaged.passUnretained(originalEvent)
            }
            if isKeyDown {
                Task { @MainActor in
                    self.adjustBrightness(delta: step)
                }
            }
            return nil

        case Self.nxKeyTypeBrightnessDown:
            guard isBrightnessAvailable() else {
                return Unmanaged.passUnretained(originalEvent)
            }
            if isKeyDown {
                Task { @MainActor in
                    self.adjustBrightness(delta: -step)
                }
            }
            return nil

        default:
            return Unmanaged.passUnretained(originalEvent)
        }
    }

    // MARK: - DisplayServices Brightness

    private func loadDisplayServicesIfNeeded() {
        guard !didAttemptLoadDS else { return }
        didAttemptLoadDS = true

        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ) else {
            return
        }
        dsHandle = handle

        if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            dsGetBrightness = unsafeBitCast(sym, to: DisplayServicesGetBrightnessFn.self)
        }
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
            dsSetBrightness = unsafeBitCast(sym, to: DisplayServicesSetBrightnessFn.self)
        }
    }

    nonisolated private func isBrightnessAvailable() -> Bool {
        guard let getFn = dsGetBrightness, dsSetBrightness != nil else {
            return false
        }
        var current: Float = 0
        return getFn(CGMainDisplayID(), &current) == 0
    }

    private func adjustBrightness(delta: Float) {
        guard let getFn = dsGetBrightness, let setFn = dsSetBrightness else { return }
        let displayID = CGMainDisplayID()
        var current: Float = 0
        guard getFn(displayID, &current) == 0 else { return }

        let target = min(1.0, max(0.0, current + delta))
        _ = setFn(displayID, target)

        NookState.shared.show(
            NookActivity(
                id: "hud.brightness",
                symbol: "sun.max.fill",
                tint: .white,
                progress: Double(target),
                duration: 1.5
            )
        )
    }

    // MARK: - CoreAudio Volume & Mute

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func getVolume(device: AudioDeviceID) -> Float? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: Self.virtualMainVolumeSelector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &virtualAddr),
           AudioObjectGetPropertyData(device, &virtualAddr, 0, nil, &size, &volume) == noErr {
            return min(1.0, max(0.0, volume))
        }

        var scalarAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &scalarAddr),
           AudioObjectGetPropertyData(device, &scalarAddr, 0, nil, &size, &volume) == noErr {
            return min(1.0, max(0.0, volume))
        }

        var ch1Addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )
        if AudioObjectHasProperty(device, &ch1Addr),
           AudioObjectGetPropertyData(device, &ch1Addr, 0, nil, &size, &volume) == noErr {
            return min(1.0, max(0.0, volume))
        }

        return nil
    }

    private func setVolume(device: AudioDeviceID, volume: Float) {
        var clamped = Float32(min(1.0, max(0.0, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)

        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: Self.virtualMainVolumeSelector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &virtualAddr),
           AudioObjectSetPropertyData(device, &virtualAddr, 0, nil, size, &clamped) == noErr {
            return
        }

        var scalarAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &scalarAddr),
           AudioObjectSetPropertyData(device, &scalarAddr, 0, nil, size, &clamped) == noErr {
            return
        }

        for channel: UInt32 in [1, 2] {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel
            )
            if AudioObjectHasProperty(device, &chAddr) {
                _ = AudioObjectSetPropertyData(device, &chAddr, 0, nil, size, &clamped)
            }
        }
    }

    private func getMute(device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else {
            return false
        }
        return muted != 0
    }

    private func setMute(device: AudioDeviceID, muted: Bool) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    private func adjustVolume(delta: Float) {
        guard let device = defaultOutputDeviceID() else { return }
        let wasMuted = getMute(device: device)
        let current = getVolume(device: device) ?? 0.5

        if delta > 0 && wasMuted {
            setMute(device: device, muted: false)
        }

        let baseVolume = (wasMuted && delta > 0) ? current : current
        let target = min(1.0, max(0.0, baseVolume + delta))
        setVolume(device: device, volume: target)

        if target <= 0.0001 {
            setMute(device: device, muted: true)
            showVolumeHUD(level: 0, muted: true)
        } else {
            if wasMuted && delta < 0 {
                setMute(device: device, muted: false)
            }
            showVolumeHUD(level: Double(target), muted: false)
        }
    }

    private func toggleMute() {
        guard let device = defaultOutputDeviceID() else { return }
        let newMuted = !getMute(device: device)
        setMute(device: device, muted: newMuted)
        let volume = Double(getVolume(device: device) ?? 0)
        showVolumeHUD(level: newMuted ? 0 : volume, muted: newMuted)
    }

    private func showVolumeHUD(level: Double, muted: Bool) {
        let clamped = min(1.0, max(0.0, level))
        let symbol: String
        if muted || clamped <= 0.001 {
            symbol = "speaker.slash.fill"
        } else if clamped < 0.33 {
            symbol = "speaker.wave.1.fill"
        } else if clamped < 0.66 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }

        NookState.shared.show(
            NookActivity(
                id: "hud.volume",
                symbol: symbol,
                tint: .white,
                progress: muted ? 0 : clamped,
                duration: 1.5
            )
        )
    }
}
