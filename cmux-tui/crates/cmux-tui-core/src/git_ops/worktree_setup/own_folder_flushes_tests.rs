use std::cell::RefCell;
use std::fs::File;
use std::io;

/// What runs in the place of a flush. It gets the open `.partial` file.
type Flush = Box<dyn FnMut(&File) -> io::Result<()>>;

thread_local! {
    static IN_PLACE: RefCell<Option<Flush>> = const { RefCell::new(None) };
}

/// Runs `run` with `flush` in the place of each flush of this thread.
/// The tests that use it are Unix only.
#[cfg(unix)]
pub(in super::super) fn in_place_of<T>(
    flush: impl FnMut(&File) -> io::Result<()> + 'static,
    run: impl FnOnce() -> T,
) -> T {
    IN_PLACE.set(Some(Box::new(flush)));
    let result = run();
    IN_PLACE.set(None);
    result
}

/// The result of the flush that is in the place for this thread, for
/// `file`. `None` when no flush is in the place.
pub(super) fn in_place(file: &File) -> Option<io::Result<()>> {
    IN_PLACE.with_borrow_mut(|flush| flush.as_mut().map(|flush| flush(file)))
}
