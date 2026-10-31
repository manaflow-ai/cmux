//! Helpers the holder's integration tests share.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

/// A new, empty directory under `/tmp` that no other test, in this process
/// or another, has: its name carries this process's id and a counter, and it
/// is made with an exclusive `mkdir` (taken again on `AlreadyExists`). A
/// name from the pid and the clock alone was shared by two tests that ran
/// in parallel threads and read the same clock value: the second test's
/// holder found the first one's live holder on the same socket and refused
/// to start ("another holder serves this socket"). Short, for `sun_path`.
pub fn unique_dir(prefix: &str) -> PathBuf {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    loop {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.subsec_nanos());
        let dir = PathBuf::from("/tmp").join(format!(
            "{prefix}-{}-{}-{:x}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
            stamp % 0x10000
        ));
        match std::fs::create_dir(&dir) {
            Ok(()) => return dir,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => panic!("make {}: {error}", dir.display()),
        }
    }
}
