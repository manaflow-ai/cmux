// The watcher and the floor experiments of scripts/measure/dev-loop/swift_inject.sh (macOS).
//
//   probe watch FILE -- CMD ARGS...   on each FSEvents event that changed FILE's bytes, print
//                                     "fs_event at=T" and run CMD (inject.sh), then "injected at=T status=S"
//   probe fsevents-floor DIR N        write a file in DIR, time to its FSEvents callback (the same stream
//                                     flags as watch); prints a JSON list of ms
//   probe pickup-floor DIR N          rename a file into DIR, time to a DispatchSource .write on DIR firing
//                                     (what cmux-view-shell --live watches its folder with)
//   probe dlopen-floor DYLIB WORK N   dlopen a fresh copy of a trivial DYLIB in this running process
//   probe paint-floor N               one frame of the shell's badge: ImageRenderer to a CGImage, warm
import AppKit
import CoreServices
import Darwin
import Foundation
import SwiftUI

func now() -> Double { Date().timeIntervalSince1970 }
func say(_ line: String) { print(line); fflush(stdout) }
func emit(_ samples: [Double]) { say("[" + samples.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]") }
func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

/// An FSEvents stream on `dir`, file-level events, no latency, no deferral: the fastest a watcher can hear a save.
final class FileEvents {
    let handler: ([String]) -> Void
    var stream: FSEventStreamRef?
    init(dir: String, queue: DispatchQueue, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            let me = Unmanaged<FileEvents>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.handler(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, callback, &context, [dir] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, flags)
        FSEventStreamSetDispatchQueue(stream!, queue)
        FSEventStreamStart(stream!)
    }
}

/// What must outlive its last use (a stream's callback holds it unretained); a global lives until exit.
var keep: [AnyObject] = []
let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { FileHandle.standardError.write(Data("usage: probe VERB ...\n".utf8)); exit(64) }

switch verb {
case "watch":
    guard args.count >= 4, args[2] == "--" else { exit(64) }
    let file = real(args[1])
    let command = Array(args[3...])
    var last = FileManager.default.contents(atPath: file)
    let queue = DispatchQueue(label: "watch")
    let stream = FileEvents(dir: (file as NSString).deletingLastPathComponent, queue: queue) { paths in
        let heard = now()
        // Every event's paths, for a reader of watch.log when a round never fired.
        FileHandle.standardError.write(Data("event at=\(heard) paths=\(paths)\n".utf8))
        guard paths.contains(where: { real($0) == file }) else { return }
        let bytes = FileManager.default.contents(atPath: file)
        guard bytes != last else { return }  // an event for bytes already injected (or a restore)
        last = bytes
        say("fs_event at=\(heard)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        do {
            try process.run()
            process.waitUntilExit()
            say("injected at=\(now()) status=\(process.terminationStatus)")
        } catch {
            say("injected at=\(now()) status=127 error=\(error)")
        }
    }
    keep.append(stream)
    say("watching \(file)")
    dispatchMain()

case "fsevents-floor":
    let dir = real(args[1]), n = Int(args[2]) ?? 5
    let file = dir + "/fsevents-probe.txt"
    FileManager.default.createFile(atPath: file, contents: Data("0".utf8))
    let heard = DispatchSemaphore(value: 0)
    var armed = false
    let lock = NSLock()
    let stream = FileEvents(dir: dir, queue: DispatchQueue(label: "fs")) { paths in
        guard paths.contains(where: { real($0) == file }) else { return }
        lock.lock(); defer { lock.unlock() }
        if armed { armed = false; heard.signal() }
    }
    keep.append(stream)
    Thread.sleep(forTimeInterval: 0.5)  // the stream's setup events pass
    var samples: [Double] = []
    for i in 0..<n {
        lock.lock(); armed = true; lock.unlock()
        let start = now()
        FileManager.default.createFile(atPath: file, contents: Data("\(i + 1) edit".utf8))
        if heard.wait(timeout: .now() + 5) == .timedOut { FileHandle.standardError.write(Data("fsevents-floor: no event\n".utf8)); exit(1) }
        samples.append((now() - start) * 1000)
        Thread.sleep(forTimeInterval: 0.2)
    }
    emit(samples)

case "pickup-floor":
    let dir = real(args[1]), n = Int(args[2]) ?? 5
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let descriptor = open(dir, O_EVTONLY)
    guard descriptor >= 0 else { exit(1) }
    let heard = DispatchSemaphore(value: 0)
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: DispatchQueue(label: "pickup"))
    source.setEventHandler { heard.signal() }
    source.resume()
    keep.append(source as AnyObject)
    var samples: [Double] = []
    for i in 0..<n {
        let staged = dir + "/../.pickup-\(i).tmp"
        FileManager.default.createFile(atPath: staged, contents: Data(count: 4096))
        while heard.wait(timeout: .now()) == .success {}  // nothing stale
        let start = now()
        rename(staged, dir + "/pickup-\(i).dylib")
        if heard.wait(timeout: .now() + 5) == .timedOut { FileHandle.standardError.write(Data("pickup-floor: no event\n".utf8)); exit(1) }
        samples.append((now() - start) * 1000)
        Thread.sleep(forTimeInterval: 0.1)
    }
    emit(samples)

case "dlopen-floor":
    let dylib = args[1], work = args[2], n = Int(args[3]) ?? 5
    var samples: [Double] = []
    for i in 0..<n {
        // A new path each time: dlopen of a path already loaded is a refcount, not a load.
        let copy = work + "/trivial-\(i)-\(getpid()).dylib"
        try? FileManager.default.removeItem(atPath: copy)
        try FileManager.default.copyItem(atPath: dylib, toPath: copy)
        let start = now()
        guard dlopen(copy, RTLD_NOW | RTLD_LOCAL) != nil else {
            FileHandle.standardError.write(Data("dlopen-floor: \(String(cString: dlerror()))\n".utf8)); exit(1)
        }
        samples.append((now() - start) * 1000)
    }
    emit(samples)

case "paint-floor":
    let n = Int(args[1]) ?? 5
    // Prototypes/ViewShell's PreviewBadge as the shell draws it after a patch (LiveCode.drawn).
    struct Badge: View {
        var body: some View {
            Text("live code").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(.quaternary)).padding(4)
        }
    }
    let frame = { () -> Double in
        MainActor.assumeIsolated {
            let start = now()
            let renderer = ImageRenderer(content: Badge())
            renderer.scale = 2
            guard renderer.cgImage != nil else { FileHandle.standardError.write(Data("paint-floor: no image\n".utf8)); exit(1) }
            return (now() - start) * 1000
        }
    }
    _ = frame()  // warm, as the shell is by its first patch (it drew generation 0 at launch)
    emit((0..<n).map { _ in frame() })

default:
    FileHandle.standardError.write(Data("probe: unknown verb \(verb)\n".utf8))
    exit(64)
}
