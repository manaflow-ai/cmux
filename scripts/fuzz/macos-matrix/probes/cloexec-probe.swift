// cloexec-probe: does a child started by Foundation's `Process` inherit a file
// descriptor that lacks FD_CLOEXEC? The app receives a terminal output ring's
// descriptor with recvmsg and sets FD_CLOEXEC right after (Darwin has no
// MSG_CMSG_CLOEXEC); a Process child spawned in that window must not inherit it
// (plans/cmux-next/app-daemon-connection-DESIGN.md 4.3). Run per macOS major by
// `os-matrix.sh --suite exec:cloexec-probe`, which compiles it on the Tart host from
// the reviewed runner tree. Exit 0 = PASS (the child did not inherit the
// descriptor), 1 = FAIL (it did), anything else = no verdict; the last stdout line
// goes to the step log.
import Foundation

let path = NSTemporaryDirectory() + "cloexec-probe-\(getpid())"
guard FileManager.default.createFile(atPath: path, contents: Data("x".utf8)) else {
    print("cloexec-probe: cannot create \(path)"); exit(2)
}
defer { unlink(path) }
let fd = open(path, O_RDONLY)
guard fd >= 0, fcntl(fd, F_GETFD) & FD_CLOEXEC == 0 else {
    print("cloexec-probe: cannot open a descriptor without FD_CLOEXEC"); exit(2)
}
let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/sh")
child.arguments = ["-c", "[ -e /dev/fd/\(fd) ] && echo inherited || echo closed"]
let output = Pipe()
child.standardOutput = output
do { try child.run() } catch { print("cloexec-probe: cannot start /bin/sh: \(error)"); exit(2) }
child.waitUntilExit()
let seen = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let os = ProcessInfo.processInfo.operatingSystemVersionString
print("cloexec-probe: macOS \(os): child \(seen)")
exit(seen == "closed" ? 0 : 1)
