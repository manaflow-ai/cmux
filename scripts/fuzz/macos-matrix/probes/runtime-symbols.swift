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
var missing: [String] = []
var checked = 0
var libraries = 0
for binary in binaries {
    guard let dependents = run(["-dependents", binary]), let imports = run(["-imports", binary]) else {
        print("runtime-symbols: dyld_info could not read \(binary)"); exit(2)
    }
    if binary == binaries.first {
        // The format this OS's dyld_info prints, for the record (it differs between majors).
        print("dependents head: " + dependents.split(separator: "\n").prefix(4).joined(separator: " | "))
        print("imports head: " + imports.split(separator: "\n").prefix(4).joined(separator: " | "))
    }
    // System libraries only (bundled @rpath ones are the same on every OS), keyed by their leaf name.
    var handles: [String: UnsafeMutableRawPointer] = [:]
    for line in dependents.split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let path = fields.last, path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/") else { continue }
        let weak = fields.dropLast().contains { $0.contains("weak") }
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            if !weak { missing.append("\(binary): library \(path)") }
            continue
        }
        handles[leaf(path)] = handle
        libraries += 1
    }
    for line in imports.split(separator: "\n") where !line.contains("[weak-import]") {
        guard let from = line.range(of: "(from "), line.hasSuffix(")") else { continue }
        let library = String(line[from.upperBound..<line.index(before: line.endIndex)])
        guard let handle = handles[library] else { continue }
        let fields = line[..<from.lowerBound].split(separator: " ", omittingEmptySubsequences: true)
        guard let symbol = fields.last, symbol.hasPrefix("_") else { continue }
        checked += 1
        if dlsym(handle, String(symbol.dropFirst())) == nil {
            missing.append("\(binary.replacingOccurrences(of: app + "/", with: "")): \(symbol) (\(library))")
        }
    }
}
print("runtime-symbols macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion): \(checked) strong system imports from \(libraries) system libraries in \(binaries.count) binaries, \(missing.count) missing")
for line in missing.prefix(200) { print("MISSING \(line)") }
// A check that read nothing proves nothing: no verdict, never a pass.
guard checked > 0 else { print("runtime-symbols: no import was checked; the dyld_info format was not understood"); exit(2) }
exit(missing.isEmpty ? 0 : 1)
