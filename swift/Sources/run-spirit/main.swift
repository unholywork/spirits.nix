import Foundation
import Virtualization

struct Options {
    var kernel: String = ""
    var initrd: String = ""
    var cmdline: String = ""
    var cpus: Int = 4
    var memory: UInt64 = 4096
    var shares: [SharedDirectory] = []
    var disks: [String] = []
    var saveStatePath: String? = nil
    var restoreStatePath: String? = nil
    var headless: Bool = false
}

func parseArgs() -> Options {
    var opts = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0

    func usage() -> Never {
        fputs("""
        Usage: run-spirit --kernel PATH --initrd PATH --cmdline STRING [options]

        Options:
          --kernel PATH           Path to uncompressed Linux kernel Image
          --initrd PATH           Path to initrd/initramfs
          --cmdline STRING        Kernel command line
          --cpus N                Number of virtual CPUs (default: 4)
          --memory N              Memory in MiB (default: 4096)
          --share PATH:TAG        Virtio-fs share (repeatable)
          --disk PATH             Disk image to attach (repeatable)
          --save-state PATH       Path used by the Ctrl-] menu 's' option to save VM state
          --restore-state PATH    Restore VM state from file (skip boot)
          --headless              Run without terminal interaction (for automated use)
          --help                  Show this help

        Press Ctrl-] while running to pause the VM and show the control menu.

        """, stderr)
        Darwin.exit(1)
    }

    func nextArg(_ flag: String) -> String {
        i += 1
        guard i < args.count else {
            fputs("Error: \(flag) requires an argument\n", stderr)
            Darwin.exit(1)
        }
        return args[i]
    }

    while i < args.count {
        switch args[i] {
        case "--kernel":
            opts.kernel = nextArg("--kernel")
        case "--initrd":
            opts.initrd = nextArg("--initrd")
        case "--cmdline":
            opts.cmdline = nextArg("--cmdline")
        case "--cpus":
            guard let n = Int(nextArg("--cpus")), n > 0 else {
                fputs("Error: --cpus must be a positive integer\n", stderr)
                Darwin.exit(1)
            }
            opts.cpus = n
        case "--memory":
            guard let n = UInt64(nextArg("--memory")), n > 0 else {
                fputs("Error: --memory must be a positive integer\n", stderr)
                Darwin.exit(1)
            }
            opts.memory = n
        case "--share":
            let val = nextArg("--share")
            let parts = val.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                fputs("Error: --share must be in HOST_PATH:TAG format\n", stderr)
                Darwin.exit(1)
            }
            opts.shares.append(SharedDirectory(hostPath: String(parts[0]), tag: String(parts[1])))
        case "--disk":
            opts.disks.append(nextArg("--disk"))
        case "--save-state":
            opts.saveStatePath = nextArg("--save-state")
        case "--restore-state":
            opts.restoreStatePath = nextArg("--restore-state")
        case "--headless":
            opts.headless = true
        case "--help", "-h":
            usage()
        default:
            fputs("Error: unknown option '\(args[i])'\n", stderr)
            usage()
        }
        i += 1
    }

    if opts.kernel.isEmpty || opts.initrd.isEmpty || opts.cmdline.isEmpty {
        fputs("Error: --kernel, --initrd, and --cmdline are required\n", stderr)
        usage()
    }

    return opts
}

// Terminal
var originalTermios = termios()
// Virtualization.framework uses dispatch_io on stdout, which sets O_NONBLOCK on the
// shared terminal file description — affecting stdin too. Open /dev/tty as a
// separate file description so our reads are not subject to that flag.
var ttyReadFd: Int32 = STDIN_FILENO

func setupRawTerminal() {
    tcgetattr(STDIN_FILENO, &originalTermios)
    var raw = originalTermios
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
}

func restoreTerminal() {
    tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
}

// Menu
func printMenu(hasSavePath: Bool) {
    fputs("\r\n  spirits  (VM paused)\r\n", stderr)
    fputs("  ─────────────────────\r\n", stderr)
    fputs("  r / Enter / Esc  resume\r\n", stderr)
    fputs("  q                quit gracefully\r\n", stderr)
    if hasSavePath {
        fputs("  s                save state and exit\r\n", stderr)
    }
    fputs("  k                force kill\r\n", stderr)
    fputs("\r\n> ", stderr)
}

func readMenuKey(vm: VZVirtualMachine, saveStatePath: String?, semaphore: DispatchSemaphore) {
    DispatchQueue.global(qos: .userInteractive).async {
        var key: UInt8 = 0
        var n: Int
        repeat {
            n = read(ttyReadFd, &key, 1)
        } while n == -1 && errno == EINTR
        guard n == 1 else {
            DispatchQueue.main.async {
                restoreTerminal()
                Darwin.exit(0)
            }
            return
        }
        DispatchQueue.main.async {
            handleMenuKey(key, vm: vm, saveStatePath: saveStatePath, semaphore: semaphore)
        }
    }
}

func handleMenuKey(_ key: UInt8, vm: VZVirtualMachine, saveStatePath: String?, semaphore: DispatchSemaphore) {
    switch key {
    case UInt8(ascii: "r"), 13, 0x1B, 0x1D:  // r, Enter, ESC, Ctrl+]
        fputs("resuming...\r\n", stderr)
        vm.resume { result in
            if case .failure(let error) = result {
                fputs("Failed to resume VM: \(error.localizedDescription)\r\n", stderr)
                restoreTerminal()
                Darwin.exit(1)
            }
            semaphore.signal()
        }
    case UInt8(ascii: "q"):
        fputs("stopping VM...\r\n", stderr)
        vm.resume { _ in
            restoreTerminal()
            do {
                try vm.requestStop()
            } catch {
                fputs("Failed to stop VM: \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
        }
    case UInt8(ascii: "s"):
        guard let savePath = saveStatePath else {
            fputs("  (no --save-state path configured)\r\n", stderr)
            printMenu(hasSavePath: false)
            readMenuKey(vm: vm, saveStatePath: nil, semaphore: semaphore)
            return
        }
        fputs("saving state to \(savePath)...\r\n", stderr)
        vm.saveMachineStateTo(url: URL(fileURLWithPath: savePath)) { saveError in
            if let error = saveError {
                fputs("Failed to save state: \(error.localizedDescription)\n", stderr)
                restoreTerminal()
                Darwin.exit(1)
            }
            fputs("VM state saved to \(savePath)\n", stderr)
            restoreTerminal()
            Darwin.exit(0)
        }
    case UInt8(ascii: "k"):
        fputs("force killing.\r\n", stderr)
        restoreTerminal()
        Darwin.exit(1)
    default:
        printMenu(hasSavePath: saveStatePath != nil)
        readMenuKey(vm: vm, saveStatePath: saveStatePath, semaphore: semaphore)
    }
}

func showMenu(vm: VZVirtualMachine, saveStatePath: String?, semaphore: DispatchSemaphore) {
    vm.pause { result in
        if case .failure(let error) = result {
            fputs("\r\nCould not pause VM: \(error.localizedDescription)\r\n", stderr)
            semaphore.signal()
            return
        }
        printMenu(hasSavePath: saveStatePath != nil)
        readMenuKey(vm: vm, saveStatePath: saveStatePath, semaphore: semaphore)
    }
}

// Entry point
let opts = parseArgs()

// Ignore SIGPIPE so writes to a broken pipe produce an error instead of
// silently killing the process.
signal(SIGPIPE, SIG_IGN)

// Open /dev/tty for a fresh file description for reading keyboard input.
if !opts.headless {
    let ttyFd = Darwin.open("/dev/tty", O_RDONLY)
    if ttyFd >= 0 { ttyReadFd = ttyFd }
}

do {
    let inputPipe = Pipe()

    let config = try createVMConfiguration(
        kernelPath: opts.kernel,
        initrdPath: opts.initrd,
        cmdline: opts.cmdline,
        cpus: opts.cpus,
        memoryMiB: opts.memory,
        shares: opts.shares,
        disks: opts.disks,
        serialInput: inputPipe.fileHandleForReading
    )

    let vm = VZVirtualMachine(configuration: config)

    if !opts.headless {
        setupRawTerminal()
    }

    // Observe VM state
    let delegate = VMDelegate {
        if !opts.headless { restoreTerminal() }
        Darwin.exit(0)
    }
    vm.delegate = delegate

    // Start or restore
    if let restorePath = opts.restoreStatePath,
       FileManager.default.fileExists(atPath: restorePath) {
        fputs("Restoring VM state from \(restorePath)...\n", stderr)
        vm.restoreMachineStateFrom(url: URL(fileURLWithPath: restorePath)) { restoreError in
            if let error = restoreError {
                fputs("Failed to restore state: \(error.localizedDescription)\n", stderr)
                fputs("Falling back to fresh boot...\n", stderr)
                try? FileManager.default.removeItem(atPath: restorePath)
                vm.start { result in
                    switch result {
                    case .success:
                        fputs("VM started.\n", stderr)
                    case .failure(let error):
                        restoreTerminal()
                        fputs("Failed to start VM: \(error.localizedDescription)\n", stderr)
                        Darwin.exit(1)
                    }
                }
                return
            }
            fputs("State restored, resuming VM...\n", stderr)
            vm.resume { resumeResult in
                switch resumeResult {
                case .failure(let error):
                    fputs("Failed to resume VM: \(error.localizedDescription)\n", stderr)
                    fputs("Falling back to fresh boot...\n", stderr)
                    try? FileManager.default.removeItem(atPath: restorePath)
                    vm.start { result in
                        switch result {
                        case .success:
                            fputs("VM started.\n", stderr)
                        case .failure(let error):
                            restoreTerminal()
                            fputs("Failed to start VM: \(error.localizedDescription)\n", stderr)
                            Darwin.exit(1)
                        }
                    }
                case .success:
                    fputs("VM resumed.\n", stderr)
                    try? FileManager.default.removeItem(atPath: restorePath)
                }
            }
        }
    } else {
        vm.start { result in
            switch result {
            case .success:
                fputs("VM started.\n", stderr)
            case .failure(let error):
                restoreTerminal()
                fputs("Failed to start VM: \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
        }
    }

    // Forward stdin to the VM's serial port, intercepting Ctrl+] for the menu.
    if !opts.headless {
        let menuSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            var byte: UInt8 = 0
            while true {
                let n = read(ttyReadFd, &byte, 1)
                if n == 1 {
                    if byte == 0x1D {  // Ctrl+]
                        DispatchQueue.main.async {
                            showMenu(vm: vm, saveStatePath: opts.saveStatePath, semaphore: menuSemaphore)
                        }
                        menuSemaphore.wait()
                    } else {
                        inputPipe.fileHandleForWriting.write(Data([byte]))
                    }
                } else if n == -1 && errno == EINTR {
                    continue  // retry on signal interrupt (e.g. SIGWINCH)
                } else {
                    let reason = n == 0 ? "EOF" : "error (errno=\(errno): \(String(cString: strerror(errno))))"
                    fputs("\r\n[run-spirit] stdin read exited: \(reason)\r\n", stderr)
                    break
                }
            }
            // stdin EOF/error
            DispatchQueue.main.async {
                restoreTerminal()
                Darwin.exit(0)
            }
        }
    }

    dispatchMain()
} catch {
    if !opts.headless { restoreTerminal() }
    fputs("Error: \(error.localizedDescription)\n", stderr)
    Darwin.exit(1)
}
