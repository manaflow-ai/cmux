//! The fixture is the holder of wire version 3: a current client settles on
//! version 3 with it, so the adoption tests of newer daemons run against an
//! older holder. (Its integration test also makes cargo build the fixture
//! binary that `cmux-tui`'s tests start.)

#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_holder::client::{HolderClient, launch};

#[test]
fn a_current_client_settles_on_wire_version_3_with_the_fixture() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
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
