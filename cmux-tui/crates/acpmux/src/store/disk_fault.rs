//! Debug builds only: the fault harness's disk switch (`cmux-fault` `disk.rs`, the `disk-full`
//! fault). With `ACPMUX_TEST_DISK_FAULT_FILE=<path>`, that file's line fails every log append
//! before it writes, as a full disk (`enospc`) or a spent quota (`edquot`) does, or slows every
//! log sync (`slow-fsync <ms>`); no file, a healthy disk. A journaled append writes its log line
//! first, so it fails here too. The variable is read per process, so parallel tests never share
//! a switch. Release builds have no seam.

use std::path::PathBuf;
use std::sync::OnceLock;

fn switch() -> Option<String> {
    static PATH: OnceLock<Option<PathBuf>> = OnceLock::new();
    let path = PATH
        .get_or_init(|| std::env::var_os("ACPMUX_TEST_DISK_FAULT_FILE").map(PathBuf::from))
        .as_ref()?;
    std::fs::read_to_string(path).ok()
}

pub(crate) fn write() -> std::io::Result<()> {
    use std::io::{Error, ErrorKind};
    match switch().as_deref().map(str::trim) {
        Some("enospc") => {
            Err(Error::new(ErrorKind::StorageFull, "no space left on device (disk-full fault)"))
        }
        Some("edquot") => {
            Err(Error::new(ErrorKind::QuotaExceeded, "disk quota exceeded (disk-full fault)"))
        }
        _ => Ok(()),
    }
}

pub(crate) fn sync() {
    let slow = switch().and_then(|line| {
        line.trim().strip_prefix("slow-fsync ").and_then(|ms| ms.parse::<u64>().ok())
    });
    if let Some(ms) = slow {
        std::thread::sleep(std::time::Duration::from_millis(ms));
    }
}
