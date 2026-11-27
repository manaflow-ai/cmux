// OS probe (vm.sh --suite exec --probe runtime-symbols): every symbol the build's app binds strongly from a
// system library must exist in this guest's OS. A strong reference to a symbol that a later macOS added (for
// example swift_task_addPriorityEscalationHandler, macOS 26, referenced under `#available` from an
// always-emit-into-client API: 537ab90cf05) passes every compile and every test on a new OS, and stops dyld
// before main on the old one ("Symbol not found", exit 134). Exit 0: all present; 1: some missing (listed);
// 2: the probe could not read the app. Self-contained, no package.
import Darwin
import Foundation

func run(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/dyld_info")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

/// The leaf name dyld_info prints after "from" for a load path: "libswift_Concurrency", "Foundation".
func leaf(_ path: String) -> String {
    var name = (path as NSString).lastPathComponent
    if name.hasSuffix(".dylib") { name = String(name.dropLast(6)) }
    if let dot = name.firstIndex(of: "."), name.hasPrefix("lib") { name = String(name[..<dot]) }
    return name
}

guard let app = ProcessInfo.processInfo.environment["CMUX_MATRIX_APP"], !app.isEmpty else {
    print("runtime-symbols: no CMUX_MATRIX_APP"); exit(2)
}
let fm = FileManager.default
var binaries: [String] = []
let macos = app + "/Contents/MacOS"
for name in (try? fm.contentsOfDirectory(atPath: macos)) ?? [] { binaries.append(macos + "/" + name) }
let frameworks = app + "/Contents/Frameworks"
for name in (try? fm.contentsOfDirectory(atPath: frameworks)) ?? [] {
    if name.hasSuffix(".dylib") { binaries.append(frameworks + "/" + name) }
    if name.hasSuffix(".framework") {
        let binary = frameworks + "/" + name + "/" + String(name.dropLast(10))
        if fm.fileExists(atPath: binary) { binaries.append(binary) }
    }
}
guard !binaries.isEmpty else { print("runtime-symbols: no binaries in \(app)"); exit(2) }

let os = ProcessInfo.processInfo.operatingSystemVersion
#if arch(arm64)
let arch = "arm64"
#else
let arch = "x86_64"
#endif
var missing: [String] = []
var checked = 0
var libraries = 0
for binary in binaries {
    // The guest's own slice only: a universal framework's x86_64 slice imports symbols (`_stat$INODE64`,
    // `_objc_msgSend_stret`) that arm64 never binds.
    guard let dependents = run(["-arch", arch, "-dependents", binary]), let imports = run(["-arch", arch, "-imports", binary]) else {
        print("runtime-symbols: dyld_info could not read \(binary)"); exit(2)
    }
    if binary == binaries.first {
        // The format this OS's dyld_info prints, for the record (it differs between majors).
        print("dependents head: " + dependents.split(separator: "\n").prefix(4).joined(separator: " | "))
        print("imports head: " + imports.split(separator: "\n").prefix(4).joined(separator: " | "))
    }
    // Every linked library in load-command order (an import's ordinal is its 1-based index here); only system
    // ones (/usr/lib, /System) are checked: bundled @rpath ones are the same on every OS.
    var ordered: [(path: String, handle: UnsafeMutableRawPointer?)] = []
    var handles: [String: UnsafeMutableRawPointer] = [:]
    for line in dependents.split(separator: "\n") {
        guard let start = line.firstIndex(where: { $0 == "/" || $0 == "@" }), !line.hasSuffix(":") else { continue }
        let path = String(line[start...]).trimmingCharacters(in: .whitespaces)
        let attributes = String(line[..<start])
        let system = path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/")
        var handle: UnsafeMutableRawPointer?
        if system {
            handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
            if handle == nil, !attributes.contains("weak") { missing.append("\(binary): library \(path)") }
            if let handle { handles[leaf(path)] = handle; libraries += 1 }
        }
        ordered.append((path, handle))
    }
    for line in imports.split(separator: "\n") where !line.contains("weak") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let handle: UnsafeMutableRawPointer?
        let symbol: String?
        if let from = line.range(of: "(from "), line.hasSuffix(")") {
            // macOS 15 and later: `0x0000  _symbol  (from library)`.
            handle = handles[String(line[from.upperBound..<line.index(before: line.endIndex)])]
            symbol = line[..<from.lowerBound].split(separator: " ", omittingEmptySubsequences: true).last.map(String.init)
        } else if fields.count >= 3, fields[0].hasPrefix("0x"), fields[1].hasPrefix("0x"),
                  let ordinal = Int(fields[1].dropFirst(2), radix: 16), ordinal >= 1, ordinal <= ordered.count {
            // macOS 14: `0x0000  0x01B  _symbol`, the second column the library's ordinal.
            handle = ordered[ordinal - 1].handle
            symbol = fields[2]
        } else {
            continue
        }
        guard let handle, let symbol, symbol.hasPrefix("_") else { continue }
        checked += 1
        if dlsym(handle, String(symbol.dropFirst())) == nil {
            missing.append("\(binary.replacingOccurrences(of: app + "/", with: "")): \(symbol)")
        }
    }
}
print("runtime-symbols macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion): \(checked) strong system imports from \(libraries) system libraries in \(binaries.count) binaries, \(missing.count) missing")
for line in missing.prefix(200) { print("MISSING \(line)") }
// A check that read nothing proves nothing: no verdict, never a pass.
guard checked > 0 else { print("runtime-symbols: no import was checked; the dyld_info format was not understood"); exit(2) }
exit(missing.isEmpty ? 0 : 1)
