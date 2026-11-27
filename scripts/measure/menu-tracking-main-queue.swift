// What a context menu's tracking loop does to the main queue, in a real NSApplication run loop.
// A host menu (NSMenu.popUp) runs a nested run loop in the event-tracking mode until it closes. Base
// opened the Chromium page's menu, the agent chat's More and fork menus and the sidebar profile menu
// inside a main-queue job (a main-actor Task, a CEF pump pass); the fix opens them from a main
// run-loop block (MainRunLoopBlock). A background thread queues a main-queue job every 5 ms while
// the stand-in menu is open (page replies, transcript updates, Chromium events do this) and records
// how long each waited. Arguments: [open seconds, default 0.4] [rounds, default 7]. "after close" is how long the main thread stays busy with that backlog after
// the menu closes: the click that closed the menu waits that long before anything it hit responds.
import AppKit

let args = CommandLine.arguments
let openSeconds = args.count > 1 ? Double(args[1]) ?? 0.4 : 0.4
let rounds = args.count > 2 ? Int(args[2]) ?? 7 : 7

func trackingMenu() {
    let end = Date().addingTimeInterval(openSeconds)
    while Date() < end { _ = RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.005)) }
}

struct Result { var worstWaitMs: Double; var p50WaitMs: Double; var drainAfterCloseMs: Double }

func measure(fromJob: Bool, done: @escaping (Result) -> Void) {
    let lock = NSLock()
    var waits: [Double] = []
    var lastRan = 0.0
    var closedAt = 0.0
    let menu = {
        trackingMenu()
        lock.withLock { closedAt = CFAbsoluteTimeGetCurrent() }
    }
    if fromJob { DispatchQueue.main.async(execute: menu) }
    else {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, menu)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 0.02)
        let group = DispatchGroup()
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < openSeconds * 0.8 {
            let queued = CFAbsoluteTimeGetCurrent()
            group.enter()
            DispatchQueue.main.async {
                // A job's own work: a reply or a transcript row costs a little main-thread time.
                let t = CFAbsoluteTimeGetCurrent()
                while CFAbsoluteTimeGetCurrent() - t < 0.001 {}
                let now = CFAbsoluteTimeGetCurrent()
                lock.withLock { waits.append((t - queued) * 1000); lastRan = now }
                group.leave()
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        group.wait()
        // Let the menu finish when it outlives the jobs.
        while lock.withLock({ closedAt == 0 }) { Thread.sleep(forTimeInterval: 0.01) }
        lock.lock()
        let sorted = waits.sorted()
        let r = Result(worstWaitMs: sorted.last ?? 0, p50WaitMs: sorted[sorted.count / 2],
                       drainAfterCloseMs: max(0, (lastRan - closedAt) * 1000))
        lock.unlock()
        DispatchQueue.main.async { done(r) }
    }
}

func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

final class Bench: NSObject, NSApplicationDelegate {
    var results: [Bool: [Result]] = [true: [], false: []]
    var order: [Bool] = []
    func applicationDidFinishLaunching(_ note: Notification) {
        order = (0..<rounds).flatMap { _ in [true, false] }
        next()
    }
    func next() {
        guard let fromJob = order.first else { return report() }
        order.removeFirst()
        // Start each round from a plain run-loop pass, as an event delivers a right-click.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            measure(fromJob: fromJob) { r in
                self.results[fromJob, default: []].append(r)
                self.next()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    func report() {
        for (label, fromJob) in [("in-main-queue-job", true), ("run-loop-callout", false)] {
            let rs = results[fromJob]!
            print(String(format: "MENU-TRACKING %@ worst_wait_ms=%.1f p50_wait_ms=%.1f drain_after_close_ms=%.1f rounds=%d",
                         label, median(rs.map(\.worstWaitMs)), median(rs.map(\.p50WaitMs)),
                         median(rs.map(\.drainAfterCloseMs)), rs.count))
        }
        exit(0)
    }
}

// A watchdog: a run that makes no progress in 60 s exits 2 instead of hanging its caller.
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: 60)
    FileHandle.standardError.write(Data("menu-tracking-main-queue: no result in 60 s\n".utf8))
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let bench = Bench()
app.delegate = bench
app.run()
