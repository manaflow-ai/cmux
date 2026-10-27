// OS probe (vm.sh --suite exec --probe malloc-probguard): this guest's libmalloc honors MallocProbGuard=1, the
// allocator check a sampled 5 % of Nightly launches start the daemon under (p10-stability-201,
// DaemonLaunchEnvironment.swift). The probe runs itself three times as a child:
//   1. MallocProbGuard=1 alone (Nightly's setting): allocates and exits 0, so the setting does not break a start.
//   2. MallocProbGuard=1 MallocProbGuardSampleRate=1 MallocProbGuardAllocations=1024: writes into freed blocks,
//      and ProbGuard's protected freed slots stop it with SIGSEGV or SIGBUS.
//   3. The same writes with no ProbGuard variable: exit 0, so the fault in 2 is ProbGuard's.
// Exit 0: honored; 1: libmalloc ignored the setting (2 exited) or the setting broke a start (1); 2: no verdict
// (a child could not start, or the control in 3 did not exit 0). Self-contained, no package.
import Darwin
import Foundation

let probGuardKeys = ["MallocProbGuard", "MallocProbGuardSampleRate", "MallocProbGuardAllocations"]
let blocks = 1024

/// How a child ended: its exit code, or the signal that stopped it.
enum Ending: CustomStringConvertible {
    case exited(Int32), signaled(Int32)

    init(waitStatus status: Int32) {
        let signal = status & 0x7f
        self = signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }

    var description: String {
        switch self {
        case .exited(let code): "exit \(code)"
        case .signaled(let signal): "signal \(signal)"
        }
    }
}

/// Runs this binary with `--child mode`, the probe's environment without any ProbGuard variable, plus `extra`.
func runChild(_ mode: String, extra: [String: String]) -> Ending? {
    guard let path = Bundle.main.executablePath else { return nil }
    var environment = ProcessInfo.processInfo.environment
    for key in probGuardKeys { environment[key] = nil }
    environment.merge(extra) { _, new in new }
    let argv: [UnsafeMutablePointer<CChar>?] = [path, "--child", mode].map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        for pointer in argv { free(pointer) }
        for pointer in envp { free(pointer) }
    }
    var pid: pid_t = 0
    guard posix_spawn(&pid, path, nil, nil, argv, envp) == 0 else { return nil }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        if errno != EINTR { return nil }
    }
    return Ending(waitStatus: status)
}

typealias MallocFunction = @convention(c) (Int) -> UnsafeMutableRawPointer?
typealias FreeFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// The child: `blocks` small blocks, then (mode "uaf") a write into each after all are freed. malloc and free
/// come from dlsym, so the optimizer cannot see the writes land in freed memory and drop them. The child
/// allocates nothing between the frees and its _exit, so the control run's writes into freed blocks are
/// never read by the allocator.
func child(_ mode: String) -> Never {
    let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    guard let mallocSymbol = dlsym(defaultHandle, "malloc"), let freeSymbol = dlsym(defaultHandle, "free") else { _exit(3) }
    let allocate = unsafeBitCast(mallocSymbol, to: MallocFunction.self)
    let release = unsafeBitCast(freeSymbol, to: FreeFunction.self)
    let pointers = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: blocks)
    for index in 0..<blocks { pointers[index] = allocate(64) }
    for index in 0..<blocks { pointers[index]?.storeBytes(of: 0xA5, as: UInt8.self) }
    if mode == "uaf" {
        for index in 0..<blocks { release(pointers[index]) }
        for index in 0..<blocks { pointers[index]?.storeBytes(of: 0x5A, as: UInt8.self) }
    }
    _exit(0)
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--child" { child(arguments[2]) }

let os = ProcessInfo.processInfo.operatingSystemVersionString
guard let nightly = runChild("alive", extra: ["MallocProbGuard": "1"]),
      let guarded = runChild("uaf", extra: ["MallocProbGuard": "1", "MallocProbGuardSampleRate": "1",
                                            "MallocProbGuardAllocations": String(blocks)]),
      let control = runChild("uaf", extra: [:]) else {
    print("malloc-probguard: a child did not start (\(os))"); exit(2)
}
print("malloc-probguard: \(os): MallocProbGuard=1 alone: \(nightly); use after free under ProbGuard: \(guarded); "
      + "without it: \(control)")
guard case .exited(0) = control else {
    print("malloc-probguard: NO VERDICT: the control child did not exit 0, so a fault proves nothing"); exit(2)
}
guard case .exited(0) = nightly else {
    print("malloc-probguard: FAIL: a process started with MallocProbGuard=1 did not exit 0"); exit(1)
}
switch guarded {
case .signaled(SIGSEGV), .signaled(SIGBUS):
    print("malloc-probguard: PASS: libmalloc honors MallocProbGuard"); exit(0)
case .exited(0):
    print("malloc-probguard: FAIL: no write into a freed block faulted: libmalloc ignored MallocProbGuard"); exit(1)
default:
    print("malloc-probguard: FAIL: the ProbGuard child ended with \(guarded), not SIGSEGV or SIGBUS"); exit(1)
}
