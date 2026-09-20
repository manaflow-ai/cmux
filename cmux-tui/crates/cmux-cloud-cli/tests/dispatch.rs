#![cfg(unix)]
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    process::Command,
};

#[test]
fn cloud_dispatch_all_spellings_preserve_arguments_and_exit_status() {
    let dir = std::env::temp_dir().join(format!("cmux-cloud-cli-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let router = dir.join("router");
    let adapter = dir.join("adapter");
    fs::write(&router, "#!/bin/sh\nprintf 'machine=%s\\n' \"$CMUX_CODEROUTER_MACHINE\"\nprintf '<%s>\\n' \"$@\"\nexit 37\n").unwrap();
    fs::write(&adapter, "#!/bin/sh\nprintf 'adapter\\n'\nprintf '<%s>\\n' \"$@\"\n").unwrap();
    for file in [&router, &adapter] {
        fs::set_permissions(file, fs::Permissions::from_mode(0o700)).unwrap();
    }
    for name in ["cmux", "cr", "coderouter"] {
        symlink(env!("CARGO_BIN_EXE_cmux-cloud-cli"), dir.join(name)).unwrap();
    }
    for (name, prefix) in
        [("cmux", Some("coderouter")), ("cmux", Some("cr")), ("cr", None), ("coderouter", None)]
    {
        let mut c = Command::new(dir.join(name));
        if let Some(prefix) = prefix {
            c.arg(prefix);
        }
        let output = c
            .args(["add", "claude", "--label", "a ; $(whoami)", "--stdin"])
            .env("CMUX_CODEROUTER_BIN", &router)
            .env("CMUX_CLOUD_ADAPTER", &adapter)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(37));
        assert_eq!(
            output.stdout,
            b"machine=1\n<add>\n<claude>\n<--label>\n<a ; $(whoami)>\n<--stdin>\n"
        );
    }
    let local = Command::new(dir.join("cmux"))
        .args(["terminal", "list"])
        .env("CMUX_CLOUD_ADAPTER", &adapter)
        .output()
        .unwrap();
    assert_eq!(local.stdout, b"adapter\n<terminal>\n<list>\n");
    let extension = Command::new(dir.join("cr"))
        .arg("models")
        .env("CMUX_CLOUD_ADAPTER", &adapter)
        .output()
        .unwrap();
    assert_eq!(extension.stdout, b"adapter\n<coderouter>\n<models>\n");
    let recursive =
        Command::new(dir.join("cr")).env("CMUX_CODEROUTER_BIN", dir.join("cmux")).output().unwrap();
    assert_eq!(recursive.status.code(), Some(127));
    let recursive_bare = Command::new(dir.join("cr"))
        .env("CMUX_CODEROUTER_BIN", "cr")
        .env("PATH", format!("{}:/usr/bin:/bin", dir.display()))
        .output()
        .unwrap();
    assert_eq!(recursive_bare.status.code(), Some(127));
    fs::remove_dir_all(dir).unwrap();
}
