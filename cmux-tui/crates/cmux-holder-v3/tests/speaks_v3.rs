//! The fixture is the holder of wire version 3: a current client settles on
//! version 3 with it, so the adoption tests of newer daemons run against an
//! older holder. (Its integration test also makes cargo build the fixture
//! binary that `cmux-tui`'s tests start.)

#![cfg(unix)]

use std::path::{Path, PathBuf};

use cmux_holder::client::{HolderClient, launch};

#[test]
fn a_current_client_settles_on_wire_version_3_with_the_fixture() {
    let stamp = unique_nanos();
    let dir = PathBuf::from("/tmp").join(format!(
        "cmhx3-{}-{}",
        std::process::id(),
        stamp % 1_000_000_000
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("h.sock");
    let token = [0x33; 32];
    let mut holder =
        launch(Path::new(env!("CARGO_BIN_EXE_cmux-holder-v3")), &socket, &token).unwrap();
    let (client, listed) = HolderClient::connect(&socket, &token).unwrap();
    assert!(listed.is_empty());
    assert_eq!(client.version(), 3, "the fixture is the version 3 holder");
    const { assert!(cmux_holder::wire::VERSION > 3, "the current holder is newer than the fixture") };
    drop(client);
    let _ = holder.kill();
    let _ = holder.wait();
    let _ = std::fs::remove_dir_all(&dir);
}

/// A stamp for a temporary name that no other call in this process gets: the clock's nanoseconds,
/// moved past the last stamp when two calls read the same nanosecond. Parallel tests did, and one
/// then used or deleted the other's folder ("File exists", a fixture gone mid-test).
fn unique_nanos() -> u128 {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_nanos()).unwrap_or(u64::MAX));
    let (Ok(last) | Err(last)) =
        LAST.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |last| Some(now.max(last + 1)));
    u128::from(now.max(last + 1))
}
