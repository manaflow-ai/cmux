// The cmux side of scripts/measure/files-finder-bench.sh: folder open (DirectoryLister) and
// recursive name search (FolderNameIndex), compiled -O with the CmuxNextFiles sources.
// Usage: files-finder-bench <runs> list <folder> | index <root> <query>...
import Foundation

func ms(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
func p90(_ values: [Double]) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count) * 0.9))] }

let args = CommandLine.arguments
guard args.count >= 4, let runs = Int(args[1]) else {
    FileHandle.standardError.write(Data("usage: files-finder-bench <runs> list <folder> | index <root> <query>...\n".utf8))
    exit(2)
}
let mode = args[2], path = URL(fileURLWithPath: args[3], isDirectory: true)
switch mode {
case "list":
    var count = 0
    let times = try (0..<runs).map { _ in try ms { count = try DirectoryLister.listSync(path).count } }
    print("cmux list \(path.lastPathComponent) items=\(count) median_ms=\(String(format: "%.2f", median(times))) p90_ms=\(String(format: "%.2f", p90(times)))")
case "index":
    var index: FolderNameIndex?
    let build = try (0..<runs).map { _ in try ms { index = try FolderNameIndex.build(root: path) } }
    guard let index else { exit(1) }
    print("cmux index \(path.lastPathComponent) items=\(index.count) build_median_ms=\(String(format: "%.1f", median(build))) build_p90_ms=\(String(format: "%.1f", p90(build)))")
    for query in args.dropFirst(4) {
        var hits = 0
        let times = (0..<max(runs, 25)).map { _ in ms { hits = index.search(query).count } }
        print("cmux search \(path.lastPathComponent) q=\(query) hits=\(hits) median_ms=\(String(format: "%.3f", median(times))) p90_ms=\(String(format: "%.3f", p90(times)))")
    }
default:
    exit(2)
}
