import AppKit
import Testing
@testable import RemoteMic

@MainActor
@Suite("G9 wake recovery")
struct G9N9NWakeRecoveryTests {
    @Test func wakeRebuildsManagerAndStopRemovesObserver() {
        let notifications = NotificationCenter()
        var starts = 0
        var recoveries = 0
        let bridge = G9N9NBluetoothBridge(makeCentral: { _ in starts += 1; return nil }, wakeNotifications: notifications)
        bridge.onWakeRecovery = { recoveries += 1 }
        bridge.start(); bridge.start()
        #expect(starts == 1)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(starts == 2)
        #expect(recoveries == 1)
        bridge.stop()
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(starts == 2)
        #expect(recoveries == 1)
    }

    @Test func wakeLeavesHealthyVoiceAndHostDrainUndisturbed() {
        let notifications = NotificationCenter()
        let voice = G9N9NVoiceSession()
        var starts = 0
        var completed = 0
        let bridge = G9N9NBluetoothBridge(makeCentral: { _ in starts += 1; return nil },
                                        wakeNotifications: notifications, voiceSession: voice)
        bridge.onVoiceStop = { _ in completed += 1 }
        bridge.start()
        #expect(voice.acceptCapabilities(Data([0x0B, 1, 0, 2, 3, 0, 247])))
        voice.control(Data([8]), now: 0)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(starts == 1 && voice.active)
        voice.control(Data([0]), now: 1)
        voice.drain(now: 1.2)
        #expect(completed == 1 && starts == 1)
        bridge.stop()
    }

    @Test func wakeRecoversAfterAbnormalVoiceCompletion() {
        let notifications = NotificationCenter()
        let voice = G9N9NVoiceSession()
        var starts = 0
        let bridge = G9N9NBluetoothBridge(makeCentral: { _ in starts += 1; return nil },
                                        wakeNotifications: notifications, voiceSession: voice)
        bridge.start()
        #expect(voice.acceptCapabilities(Data([0x0B, 1, 0, 2, 3, 0, 247])))
        voice.control(Data([8]), now: 0)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(starts == 1)
        voice.cancel(reason: "audio_timeout", now: 5)
        #expect(starts == 2)
        bridge.stop()
    }
}
