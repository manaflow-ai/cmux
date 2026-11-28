// The launch floor for scripts/measure/ios-first-connect-simctl.sh: a one-file SwiftUI app with no packages and
// no frameworks, logging the same `timing launch <mark> (<ms>ms)` lines as cmux's LaunchMarks (subsystem
// dev.cmux.mobile, category timing, ms since the kernel's process start). Its `main` is the simulator's own
// spawn and dyld cost for an app with nothing to load; cmux's `main` minus this one is what cmux adds before
// main(). Built on the runner by scripts/measure/ios-launch-floor/build.sh.
import Darwin
import OSLog
import QuartzCore
import SwiftUI

enum Marks {
    static let log = Logger(subsystem: "dev.cmux.mobile", category: "timing")
    static let start: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }()
    static var taken: Set<String> = []
    static func mark(_ name: String) {
        guard taken.insert(name).inserted else { return }
        let ms = Date().timeIntervalSince(start) * 1000
        log.info("timing launch \(name, privacy: .public) (\(Int(ms.rounded()), privacy: .public)ms)")
    }
}

final class OneFrame: NSObject {
    static var live: [OneFrame] = []
    var link: CADisplayLink?
    var action: (() -> Void)?
    static func after(_ action: @escaping () -> Void) {
        let f = OneFrame()
        f.action = action
        f.link = CADisplayLink(target: f, selector: #selector(step))
        f.link?.add(to: .main, forMode: .common)
        live.append(f)
    }
    @objc func step() {
        link?.invalidate()
        action?()
        action = nil
    }
}

@main
enum FloorMain {
    static func main() {
        Marks.mark("main")
        FloorApp.main()
    }
}

struct FloorApp: App {
    init() { Marks.mark("app_init_done") }
    var body: some Scene {
        WindowGroup {
            List(0..<150, id: \.self) { Text("row \($0)") }
                .onAppear {
                    OneFrame.after {
                        Marks.mark("first_frame")
                        Marks.mark("shell_frame")
                        Marks.mark("workspaces_list_frame")
                    }
                }
        }
    }
}
