import Foundation
import IOKit
import IOKit.pwr_mgt

/// Watches for host sleep/wake and invokes callbacks on the main queue.
///
/// Guest RAM pages get zeroed across host sleep/wake on macOS 26
/// (Virtualization.framework bug), corrupting the guest kernel and, via
/// written-back page cache, the persistent disks. Pausing the VM before the
/// host sleeps avoids this.
///
/// Registration uses IORegisterForSystemPower rather than NSWorkspace
/// notifications: it works without a CFRunLoop (we run under dispatchMain),
/// and acking via IOAllowPowerChange holds off sleep until the pause has
/// actually completed.
final class SleepWatcher {
    /// Called when the host is about to sleep. The handler must call the
    /// provided acknowledgement exactly once; sleep is delayed until then.
    private let onSleep: (_ ack: @escaping () -> Void) -> Void
    private let onWake: () -> Void

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init?(
        onSleep: @escaping (_ ack: @escaping () -> Void) -> Void,
        onWake: @escaping () -> Void
    ) {
        self.onSleep = onSleep
        self.onWake = onWake

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
            let watcher = Unmanaged<SleepWatcher>.fromOpaque(refcon!).takeUnretainedValue()
            watcher.handle(messageType: messageType, argument: messageArgument)
        }

        rootPort = IORegisterForSystemPower(refcon, &notifyPort, callback, &notifier)
        guard rootPort != 0, let notifyPort else {
            fputs("[run-spirit] failed to register for system power notifications\n", stderr)
            return nil
        }
        IONotificationPortSetDispatchQueue(notifyPort, DispatchQueue.main)
    }

    // The kIOMessage* macros from IOKit/IOMessage.h don't import into Swift
    // (iokit_common_msg is a function-like macro); these are their values.
    private static let canSystemSleep: UInt32 = 0xE000_0270  // kIOMessageCanSystemSleep
    private static let systemWillSleep: UInt32 = 0xE000_0280  // kIOMessageSystemWillSleep
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300  // kIOMessageSystemHasPoweredOn

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            // Don't veto idle sleep; we handle it in systemWillSleep.
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemWillSleep:
            onSleep { [rootPort] in
                IOAllowPowerChange(rootPort, notificationID)
            }
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }
}
