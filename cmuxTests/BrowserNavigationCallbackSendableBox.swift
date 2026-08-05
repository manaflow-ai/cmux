/// The value crosses into a detached task, while the callback enforces its
/// own actor contract before touching browser state.
struct BrowserNavigationCallbackSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
