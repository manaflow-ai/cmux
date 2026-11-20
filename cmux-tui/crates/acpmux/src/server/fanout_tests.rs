/// A chat id with this prefix panics the fan-out task at its first delivery: no shared state,
/// so parallel tests never trip each other (the test-hooks check, cmux#41350).
pub(in crate::server) const PANIC_PREFIX: &str = "fanout-test-panic-";

pub(super) fn panic_if_marked(session: &str) {
    if session.starts_with(PANIC_PREFIX) {
        panic!("fan-out test panic for {session}");
    }
}
