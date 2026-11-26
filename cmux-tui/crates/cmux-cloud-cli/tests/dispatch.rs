#![cfg(unix)]
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    process::Command,
};

#[test]
fn cloud_dispatch_preserves_arguments_and_refuses_itself() {
    let dir = std::env::temp_dir().join(format!("cmux-cloud-cli-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let adapter = dir.join("adapter");
    fs::write(&adapter, "#!/bin/sh\nprintf 'adapter\\n'\nprintf '<%s>\\n' \"$@\"\nexit 37\n")
        .unwrap();
    fs::set_permissions(&adapter, fs::Permissions::from_mode(0o700)).unwrap();
    symlink(env!("CARGO_BIN_EXE_cmux-cloud-cli"), dir.join("cmux")).unwrap();
    let local = Command::new(dir.join("cmux"))
        .args(["terminal", "list", "--label", "a ; $(whoami)"])
        .env("CMUX_CLOUD_ADAPTER", &adapter)
        .output()
        .unwrap();
    assert_eq!(local.status.code(), Some(37));
    assert_eq!(local.stdout, b"adapter\n<terminal>\n<list>\n<--label>\n<a ; $(whoami)>\n");
    let recursive = Command::new(dir.join("cmux"))
        .env("CMUX_CLOUD_ADAPTER", dir.join("cmux"))
        .output()
        .unwrap();
    assert_eq!(recursive.status.code(), Some(127));
    let recursive_bare = Command::new(dir.join("cmux"))
        .env("CMUX_CLOUD_ADAPTER", "cmux")
        .env("PATH", format!("{}:/usr/bin:/bin", dir.display()))
        .output()
        .unwrap();
    assert_eq!(recursive_bare.status.code(), Some(127));
    fs::remove_dir_all(dir).unwrap();
}
