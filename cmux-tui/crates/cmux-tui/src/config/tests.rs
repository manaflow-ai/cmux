//! Unit tests for `config`; topic tests live in `tests/`.

use super::*;
#[cfg(unix)]
use crate::test_exec::write_executable;

use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_TEST_DIRECTORY: AtomicU64 = AtomicU64::new(0);

struct TestDirectory {
    path: PathBuf,
}

impl TestDirectory {
    fn new(label: &str) -> Self {
        loop {
            let sequence = NEXT_TEST_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("cmux-tui-config-{label}-{}-{sequence}", std::process::id()));
            match std::fs::create_dir(&path) {
                Ok(()) => return Self { path },
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create config test directory failed: {error}"),
            }
        }
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

mod ghostty_defaults;
mod ghostty_helper;
