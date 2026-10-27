//! Descriptor numbering shared by both spawn paths.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

/// A close-on-exec copy of `fd` numbered `floor` or more.
pub(crate) fn dup_above(fd: &OwnedFd, floor: RawFd) -> io::Result<OwnedFd> {
    // SAFETY: F_DUPFD_CLOEXEC returns a new descriptor or -1.
    let copy = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, floor) };
    if copy < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a new descriptor this function owns.
    Ok(unsafe { OwnedFd::from_raw_fd(copy) })
}

/// The Linux plan of [`Command::inherit_fd`](crate::Command::inherit_fd):
/// each source whose number is one of the targets, or 0-2 (std places the
/// streams first), is replaced in the parent with a copy above every target,
/// as the macOS spawn does with its own plan. The child's `dup2` calls then
/// never replace a source that a later one still reads.
#[cfg(not(target_vendor = "apple"))]
pub(crate) fn lift_sources_above_targets(plan: &mut [(OwnedFd, RawFd)]) -> io::Result<()> {
    let targets: std::collections::BTreeSet<RawFd> =
        plan.iter().map(|(_, target)| *target).collect();
    let floor = targets.iter().max().map_or(3, |max| max + 1);
    for (source, _) in plan.iter_mut() {
        let number = source.as_raw_fd();
        if number < 3 || targets.contains(&number) {
            *source = dup_above(source, floor)?;
        }
    }
    Ok(())
}
