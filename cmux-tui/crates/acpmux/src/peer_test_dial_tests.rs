use std::cell::RefCell;

/// One dial: its monotonic instant and its wall-clock millisecond.
pub(crate) type Attempt = (tokio::time::Instant, u64);

thread_local!(static ATTEMPTS: RefCell<Option<Vec<Attempt>>> = const { RefCell::new(None) });

pub(crate) fn refuse_all() {
    ATTEMPTS.with(|a| *a.borrow_mut() = Some(Vec::new()));
}

/// The dials so far; dials keep failing.
pub(crate) fn attempts() -> Vec<Attempt> {
    ATTEMPTS.with(|a| a.borrow().clone().unwrap_or_default())
}

/// Dials go out for real again.
pub(crate) fn clear() {
    ATTEMPTS.with(|a| *a.borrow_mut() = None);
}

pub(super) fn refused() -> bool {
    ATTEMPTS.with(|a| {
        let mut a = a.borrow_mut();
        let Some(list) = a.as_mut() else { return false };
        list.push((tokio::time::Instant::now(), crate::store::now_ms()));
        true
    })
}
