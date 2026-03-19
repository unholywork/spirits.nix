import Foundation
import vmnet

enum VmnetError: LocalizedError {
    case notRoot
    case startFailed(vmnet_return_t)
    case socketpairFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .notRoot:
            return "Bridged networking requires root. Re-run with sudo."
        case .startFailed(let status):
            return "vmnet_start_interface failed (status \(status.rawValue))"
        case .socketpairFailed(let err):
            return "socketpair() failed: \(String(cString: strerror(err)))"
        }
    }
}

/// Manages a vmnet bridged interface and shuttles packets between vmnet and a
/// socket pair. The VM-side file handle can be passed to
/// VZFileHandleNetworkDeviceAttachment.
class VmnetBridge {
    let vmHandle: FileHandle
    private let vmFd: Int32
    private let vmnetFd: Int32
    private var iface: interface_ref?
    private let maxPacketSize: Int
    private var running = true

    /// Start a vmnet bridged interface on `hostInterface` (e.g. "en0").
    /// Must be called as root.
    static func start(bridgedTo hostInterface: String) throws -> VmnetBridge {
        guard getuid() == 0 else { throw VmnetError.notRoot }

        // Create a DGRAM socket pair for packet exchange
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw VmnetError.socketpairFailed(errno)
        }
        let vmnetSide = fds[0]
        let vmSide = fds[1]

        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(operating_modes_t.VMNET_BRIDGED_MODE.rawValue))
        xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, hostInterface)

        let semaphore = DispatchSemaphore(value: 0)
        var startStatus = vmnet_return_t(rawValue: 0)!
        var maxPkt: Int = 1514

        let ifaceRef = vmnet_start_interface(desc, DispatchQueue.global(qos: .userInteractive)) { status, params in
            startStatus = status
            if let params = params {
                if let val = xpc_dictionary_get_value(params, vmnet_max_packet_size_key) {
                    maxPkt = Int(xpc_uint64_get_value(val))
                }
            }
            semaphore.signal()
        }

        semaphore.wait()

        guard startStatus == vmnet_return_t(rawValue: 1000),  // VMNET_SUCCESS
              let iface = ifaceRef else {
            close(vmnetSide)
            close(vmSide)
            throw VmnetError.startFailed(startStatus)
        }

        // Set socket buffers large enough for jumbo-ish frames
        var bufSize: Int32 = 2 * 1024 * 1024
        setsockopt(vmnetSide, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(vmnetSide, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(vmSide, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(vmSide, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        let bridge = VmnetBridge(
            vmFd: vmSide,
            vmnetFd: vmnetSide,
            iface: iface,
            maxPacketSize: maxPkt
        )
        bridge.startForwarding()
        return bridge
    }

    private init(vmFd: Int32, vmnetFd: Int32, iface: interface_ref, maxPacketSize: Int) {
        self.vmFd = vmFd
        self.vmnetFd = vmnetFd
        self.iface = iface
        self.maxPacketSize = maxPacketSize
        self.vmHandle = FileHandle(fileDescriptor: vmFd, closeOnDealloc: false)
    }

    /// Forward packets in both directions on background queues.
    private func startForwarding() {
        let iface = self.iface!
        let maxPkt = self.maxPacketSize
        let vmnetFd = self.vmnetFd

        // vmnet -> VM socket
        vmnet_interface_set_event_callback(iface, interface_event_t.VMNET_INTERFACE_PACKETS_AVAILABLE, DispatchQueue.global(qos: .userInteractive)) { [weak self] _, _ in
            guard let self = self, self.running else { return }

            var pktCount: Int32 = 64
            let buf = UnsafeMutablePointer<vmpktdesc>.allocate(capacity: Int(pktCount))
            defer { buf.deallocate() }

            for i in 0..<Int(pktCount) {
                let iov = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
                let data = UnsafeMutableRawPointer.allocate(byteCount: maxPkt, alignment: 1)
                iov.pointee = iovec(iov_base: data, iov_len: maxPkt)
                buf[i] = vmpktdesc(vm_pkt_size: maxPkt, vm_pkt_iov: iov, vm_pkt_iovcnt: 1, vm_flags: 0)
            }

            let status = vmnet_read(iface, buf, &pktCount)
            if status == vmnet_return_t(rawValue: 1000) { // VMNET_SUCCESS
                for i in 0..<Int(pktCount) {
                    let pkt = buf[Int(i)]
                    let ptr = pkt.vm_pkt_iov.pointee.iov_base!
                    let len = Int(pkt.vm_pkt_size)
                    _ = send(vmnetFd, ptr, len, 0)
                }
            }

            for i in 0..<64 {
                buf[i].vm_pkt_iov.pointee.iov_base.deallocate()
                buf[i].vm_pkt_iov.deallocate()
            }
        }

        // VM socket -> vmnet
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let recvBuf = UnsafeMutableRawPointer.allocate(byteCount: maxPkt, alignment: 1)
            defer { recvBuf.deallocate() }

            while self?.running == true {
                let n = recv(vmnetFd, recvBuf, maxPkt, 0)
                if n <= 0 { break }

                let iov = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
                iov.pointee = iovec(iov_base: recvBuf, iov_len: n)
                var pkt = vmpktdesc(vm_pkt_size: n, vm_pkt_iov: iov, vm_pkt_iovcnt: 1, vm_flags: 0)
                var pktCount: Int32 = 1
                vmnet_write(iface, &pkt, &pktCount)
                iov.deallocate()
            }
        }
    }

    func stop() {
        running = false
        if let iface = iface {
            let sem = DispatchSemaphore(value: 0)
            vmnet_stop_interface(iface, DispatchQueue.global()) { _ in sem.signal() }
            sem.wait()
            self.iface = nil
        }
        close(vmFd)
        close(vmnetFd)
    }

    deinit {
        stop()
    }
}
