// Counts the FSEvents a folder's subtree gets: what fseventsd journals for it (and keeps every path
// name of until reboot). Prints "ready" once the stream runs, and on SIGINT or SIGTERM one JSON
// line: events, unique paths, and events by kind.
//
// Usage: fsevents-count PATH
import CoreServices
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: fsevents-count PATH\n".data(using: .utf8)!)
    exit(2)
}
let root = CommandLine.arguments[1]

final class Tally {
    var events = 0
    var paths = Set<String>()
    var kinds: [String: Int] = [:]
}
let tally = Tally()

let kindFlags: [(String, Int)] = [
    ("created", kFSEventStreamEventFlagItemCreated),
    ("removed", kFSEventStreamEventFlagItemRemoved),
    ("renamed", kFSEventStreamEventFlagItemRenamed),
    ("modified", kFSEventStreamEventFlagItemModified),
    ("inode_meta", kFSEventStreamEventFlagItemInodeMetaMod),
    ("xattr", kFSEventStreamEventFlagItemXattrMod),
    ("cloned", kFSEventStreamEventFlagItemCloned),
    ("must_scan", kFSEventStreamEventFlagMustScanSubDirs),
    ("dropped", kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped),
]

let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    let tally = Unmanaged<Tally>.fromOpaque(info!).takeUnretainedValue()
    let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
    for index in 0..<count {
        let flag = Int(flags[index])
        if flag & kFSEventStreamEventFlagHistoryDone != 0 { continue }
        tally.events += 1
        tally.paths.insert(names[index])
        for (name, bit) in kindFlags where flag & bit != 0 {
            tally.kinds[name, default: 0] += 1
        }
    }
}

var context = FSEventStreamContext(
    version: 0, info: Unmanaged.passUnretained(tally).toOpaque(), retain: nil, release: nil,
    copyDescription: nil)
let flags = UInt32(
    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagUseCFTypes)
guard
    let stream = FSEventStreamCreate(
        nil, callback, &context, [root] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
else {
    FileHandle.standardError.write("fsevents-count: no stream for \(root)\n".data(using: .utf8)!)
    exit(1)
}
let queue = DispatchQueue(label: "fsevents-count")
FSEventStreamSetDispatchQueue(stream, queue)
FSEventStreamStart(stream)

func finish() -> Never {
    FSEventStreamFlushSync(stream)
    queue.sync {
        let line: [String: Any] = [
            "events": tally.events, "paths": tally.paths.count, "kinds": tally.kinds,
        ]
        let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
    exit(0)
}
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sources = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: .main) }
for source in sources {
    source.setEventHandler { finish() }
    source.resume()
}
print("ready")
fflush(stdout)
dispatchMain()
