//! The pinned host keys live in `<data>/ssh/known_hosts` (0600, folder
//! 0700), written atomically, read at start, and updated when the Cloud
//! API sends a new key for a machine.

mod attach_common;
mod common;
mod edge_common;

use cmux_cloud::app_env::AppEnv;
use cmux_cloud::fs::KnownHosts;
use cmux_cloud::{Origin, Request};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

const KEY_A: &str =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBERERERERERERERERERERERERERERERERERERERERER";
const KEY_B: &str =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIi";
const KEY_OLD: &str =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMz";

fn data_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-c12-kh-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn file(data: &Path) -> PathBuf {
    data.join("ssh/known_hosts")
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn pins_survive_a_restart() {
    let data = data_dir("restart");
    let (mut first, _) = KnownHosts::load(file(&data));
    first.pin("vm-alpha01", KEY_A).unwrap();
    drop(first);
    let (mut second, warnings) = KnownHosts::load(file(&data));
    assert!(warnings.is_empty(), "{warnings:?}");
    assert_eq!(second.get("vm-alpha01"), Some(KEY_A), "the pin was read at start");
    second.pin("vm-beta02", KEY_B).unwrap();
    let text = std::fs::read_to_string(file(&data)).unwrap();
    assert_eq!(text, format!("cmux-scp-vm-alpha01 {KEY_A}\ncmux-scp-vm-beta02 {KEY_B}\n"));
}

#[test]
fn the_file_is_owner_only_in_an_owner_only_folder() {
    let data = data_dir("modes");
    let (mut pins, _) = KnownHosts::load(file(&data));
    pins.pin("vm-alpha01", KEY_A).unwrap();
    assert_eq!(mode(&file(&data)), 0o600);
    assert_eq!(mode(&data.join("ssh")), 0o700);
}

fn failing_rename(_: &Path, _: &Path) -> std::io::Result<()> {
    Err(std::io::Error::other("crash before rename"))
}

#[test]
fn a_crash_before_the_rename_leaves_the_old_file() {
    let data = data_dir("crash");
    let (mut pins, _) = KnownHosts::load(file(&data));
    pins.pin("vm-alpha01", KEY_OLD).unwrap();
    let before = std::fs::read(file(&data)).unwrap();
    let mut pins = pins.with_rename(failing_rename);
    assert!(pins.pin("vm-alpha01", KEY_A).is_err(), "the failed rename is an error");
    assert_eq!(std::fs::read(file(&data)).unwrap(), before, "the old file is intact");
    assert_eq!(pins.get("vm-alpha01"), Some(KEY_OLD), "memory follows the file");
    let names: Vec<String> = std::fs::read_dir(data.join("ssh"))
        .unwrap()
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["known_hosts"], "no staging file is left");
}

#[test]
fn a_corrupt_line_is_skipped_with_a_warning_and_the_other_pins_stay() {
    let data = data_dir("corrupt");
    std::fs::create_dir_all(data.join("ssh")).unwrap();
    let text = format!(
        "cmux-scp-vm-alpha01 {KEY_A}\nthis is not a pin\n\u{0}\u{1}garbage\ncmux-scp-vm-beta02 {KEY_B}\ncmux-scp-vm-gamma03 ssh-rsa AAAAB3Nz\n"
    );
    std::fs::write(file(&data), text).unwrap();
    let (pins, warnings) = KnownHosts::load(file(&data));
    assert_eq!(pins.get("vm-alpha01"), Some(KEY_A));
    assert_eq!(pins.get("vm-beta02"), Some(KEY_B));
    assert_eq!(pins.get("vm-gamma03"), None, "a key that is not one Ed25519 key is skipped");
    assert_eq!(warnings.len(), 3, "one warning per skipped line: {warnings:?}");
    assert!(warnings.iter().all(|w| w.contains("line")), "{warnings:?}");
}

#[test]
fn the_server_reads_the_pins_at_start_and_the_api_key_replaces_an_old_one() {
    let env = attach_common::test_env();
    let data = env.data_dir().unwrap().to_path_buf();
    std::fs::create_dir_all(data.join("ssh")).unwrap();
    // A pin from an earlier run of the server, and an old key for alpha.
    std::fs::write(
        file(&data),
        format!("cmux-scp-vm-alpha01 {KEY_OLD}\ncmux-scp-vm-beta02 {KEY_B}\n"),
    )
    .unwrap();
    let mut rig = edge_common::rig_with_env(
        &["vm-get", "attach_endpoint_alpha", "scp-endpoint"],
        AppEnv::from_vars([("CMUX_APP_DATA_DIR", data.to_str().unwrap())]),
    );
    let local = data.join("upload.txt");
    std::fs::write(&local, b"payload").unwrap();
    let push = Request::new(
        "cloud.file.push",
        serde_json::json!({"machine": "vm-alpha01", "localPath": local, "path": "/home/cmux/a"}),
    )
    .key("p-1")
    .origin(Origin::User);
    rig.server.handle(&push).expect("the push starts");
    rig.server.wait_transfers();
    let text = std::fs::read_to_string(file(&data)).unwrap();
    assert_eq!(
        text,
        format!("cmux-scp-vm-alpha01 {KEY_A}\ncmux-scp-vm-beta02 {KEY_B}\n"),
        "beta's pin from the earlier run stays; alpha has the Cloud API's key once"
    );
}
