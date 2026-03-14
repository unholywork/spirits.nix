import Foundation
import Virtualization

struct SharedDirectory {
    let hostPath: String
    let tag: String
}

enum VMConfigError: LocalizedError {
    case kernelNotFound(String)
    case initrdNotFound(String)
    case sharedDirectoryNotFound(String)
    case diskNotFound(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .kernelNotFound(let path): return "Kernel not found: \(path)"
        case .initrdNotFound(let path): return "Initrd not found: \(path)"
        case .sharedDirectoryNotFound(let path): return "Shared directory not found: \(path)"
        case .diskNotFound(let path): return "Disk image not found: \(path)"
        case .validationFailed(let msg): return "VM configuration invalid: \(msg)"
        }
    }
}

func createVMConfiguration(
    kernelPath: String,
    initrdPath: String,
    cmdline: String,
    cpus: Int,
    memoryMiB: UInt64,
    shares: [SharedDirectory],
    disks: [String],
    serialInput: FileHandle
) throws -> VZVirtualMachineConfiguration {
    let config = VZVirtualMachineConfiguration()

    // Boot loader
    let kernelURL = URL(fileURLWithPath: kernelPath)
    let initrdURL = URL(fileURLWithPath: initrdPath)

    guard FileManager.default.fileExists(atPath: kernelPath) else {
        throw VMConfigError.kernelNotFound(kernelPath)
    }
    guard FileManager.default.fileExists(atPath: initrdPath) else {
        throw VMConfigError.initrdNotFound(initrdPath)
    }

    let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
    bootLoader.commandLine = cmdline
    bootLoader.initialRamdiskURL = initrdURL
    config.bootLoader = bootLoader

    // CPU and memory
    config.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                          min(cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
    config.memorySize = UInt64(memoryMiB) * 1024 * 1024

    // Serial console on stdio
    let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
    let stdioAttachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: serialInput,
        fileHandleForWriting: FileHandle.standardOutput
    )
    serialPort.attachment = stdioAttachment
    config.serialPorts = [serialPort]

    // NAT networking
    let networkDevice = VZVirtioNetworkDeviceConfiguration()
    networkDevice.attachment = VZNATNetworkDeviceAttachment()
    config.networkDevices = [networkDevice]

    // Entropy
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    // Virtio-fs shared directories
    var fsDevices: [VZVirtioFileSystemDeviceConfiguration] = []
    for share in shares {
        guard FileManager.default.fileExists(atPath: share.hostPath) else {
            throw VMConfigError.sharedDirectoryNotFound(share.hostPath)
        }
        let sharedDir = VZSharedDirectory(url: URL(fileURLWithPath: share.hostPath), readOnly: false)
        let singleDirShare = VZSingleDirectoryShare(directory: sharedDir)
        let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
        fsDevice.share = singleDirShare
        fsDevices.append(fsDevice)
    }
    config.directorySharingDevices = fsDevices

    // Memory balloon for dynamic memory management
    config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

    // Disk images
    var storageDevices: [VZStorageDeviceConfiguration] = []
    for diskPath in disks {
        guard FileManager.default.fileExists(atPath: diskPath) else {
            throw VMConfigError.diskNotFound(diskPath)
        }
        let diskURL = URL(fileURLWithPath: diskPath)
        let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
    }
    config.storageDevices = storageDevices

    // Validate
    try config.validate()

    return config
}

class VMDelegate: NSObject, VZVirtualMachineDelegate {
    let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("\r\nVM stopped with error: \(error.localizedDescription)\r\n", stderr)
        onStop()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        fputs("\r\nVM stopped.\r\n", stderr)
        onStop()
    }
}
