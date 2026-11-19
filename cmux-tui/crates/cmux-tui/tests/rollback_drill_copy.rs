//! DRILL, NOT FOR A MERGE. Step 1 of 2 of a rollback drill with real
//! binaries: this build's `cmux-tui` is the OLDER build of the drill. The
//! test copies it to one fixed file in `/tmp`, so that a second step, at the
//! newer build's commit on the same machine, can run it against stores that
//! the newer build wrote. The second step checks the copy's SHA-256 and
//! deletes the copy.
//!
//! Each line starts with `rollback drill copy:`.

#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::Command;

use sha2::{Digest, Sha256};

/// The copy. The name has the lane and the short hash of the older build's
/// commit; the second step has the same name.
const COPY: &str = "/tmp/daemon-git-cost-drill-5fc484aa-cmux-tui";

fn say(text: &str) {
    println!("rollback drill copy: {text}");
}

fn sha256(path: &Path) -> String {
    let bytes = fs::read(path).unwrap();
    Sha256::digest(&bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// One run of the copy with `args`, in an empty state folder of its own:
/// its exit code, stdout and stderr.
fn run(state: &Path, args: &[&str]) -> String {
    let output = Command::new(COPY)
        .args(args)
        .env("CMUX_TUI_STATE_DIR", state.join("sessions"))
        .env("CMUX_TUI_CONFIG", state.join("config.json"))
        .env("CMUX_TUI_LOG_FILE", state.join("client.log"))
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    format!(
        "exit code {:?}, stdout {:?}, stderr {:?}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout).trim(),
        String::from_utf8_lossy(&output.stderr).trim()
    )
}

#[test]
fn rollback_drill_copy_of_the_older_build() {
    let built = Path::new(env!("CARGO_BIN_EXE_cmux-tui"));
    say(&format!("a file of that name from an earlier run: {}", Path::new(COPY).exists()));
    let bytes = fs::copy(built, COPY).unwrap();
    let (of_the_build, of_the_copy) = (sha256(built), sha256(Path::new(COPY)));
    say(&format!("the copy {COPY} has {bytes} bytes and the SHA-256 {of_the_copy}"));
    assert_eq!(of_the_build, of_the_copy, "the build's file and the copy");
    // The copy runs from `/tmp`: it needs no file of its build folder.
    let state = std::env::temp_dir().join(format!("cmux-drill-copy-{}", std::process::id()));
    fs::create_dir_all(state.join("sessions")).unwrap();
    say(&format!("`__store-schemas` of the copy: {}", run(&state, &["__store-schemas"])));
    say(&format!(
        "`__store-schemas --stored` of the copy, with no session: {}",
        run(&state, &["__store-schemas", "--stored"])
    ));
    let _ = fs::remove_dir_all(&state);
}
