import Darwin

@main
struct AppHostLeaseWatcherMain {
    static func main() {
        // A signal shortcut must not satisfy the lease-release regression.
        signal(SIGTERM, SIG_IGN)
        AppHostProcessReceipt.writeIfRequired()
        while true {
            pause()
        }
    }
}
