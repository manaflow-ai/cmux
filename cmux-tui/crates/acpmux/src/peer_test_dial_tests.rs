use std::cell::RefCell;

/// One dial: its monotonic instant and its wall-clock millisecond.
pub(crate) type Attempt = (tokio::time::Instant, u64);

thread_local!(static ATTEMPTS: RefCell<Option<Vec<Attempt>>> = const { RefCell::new(None) });
thread_local!(static AUTH: std::cell::Cell<bool> = const { std::cell::Cell::new(false) });
thread_local!(static HOST_KEY: std::cell::Cell<bool> = const { std::cell::Cell::new(false) });

pub(crate) fn refuse_all() {
    ATTEMPTS.with(|a| *a.borrow_mut() = Some(Vec::new()));
    AUTH.with(|a| a.set(false));
    HOST_KEY.with(|a| a.set(false));
}

/// Every dial fails as ssh does when the remote refuses this computer's key or password
/// (`Permission denied`), and is recorded.
pub(crate) fn refuse_login_all() {
    refuse_all();
    AUTH.with(|a| a.set(true));
}

/// Every dial fails as ssh does when the machine's host key does not match
/// (`Host key verification failed`), and is recorded.
pub(crate) fn refuse_host_key_all() {
    refuse_all();
    HOST_KEY.with(|a| a.set(true));
}

/// Whether the dials fail as a refused host key.
pub(super) fn host_key_refused() -> bool {
    HOST_KEY.with(|a| a.get())
}

/// Whether the dials fail as a refused login.
pub(super) fn login_refused() -> bool {
    AUTH.with(|a| a.get())
}

/// The dials so far; dials keep failing.
pub(crate) fn attempts() -> Vec<Attempt> {
    ATTEMPTS.with(|a| a.borrow().clone().unwrap_or_default())
}

/// Dials go out for real again.
pub(crate) fn clear() {
    ATTEMPTS.with(|a| *a.borrow_mut() = None);
    AUTH.with(|a| a.set(false));
    HOST_KEY.with(|a| a.set(false));
}

pub(super) fn refused() -> bool {
    ATTEMPTS.with(|a| {
        let mut a = a.borrow_mut();
        let Some(list) = a.as_mut() else { return false };
        list.push((tokio::time::Instant::now(), crate::store::now_ms()));
        true
    })
}
