//! `cmux sidebar plugin install` often runs from a project directory, so a
//! relative `XDG_DATA_HOME` (a quoted `"~/.local/share"`) must not install
//! plugins under that project.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;
use std::process::Command;

fn git(dir: &Path, args: &[&str]) {
    let output = Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
}

#[test]
fn cmux_next_plugin_install_ignores_a_relative_xdg_data_home() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let project = root.path().join("project");
    let source = root.path().join("source");
    for dir in [&home, &project, &source.join("bin")] {
        fs::create_dir_all(dir).unwrap();
    }
    fs::write(
        source.join("cmux-plugin.toml"),
        "[plugin]\nname = \"fixture\"\nkind = \"sidebar\"\nversion = \"0.1.0\"\n\n[run]\ncommand = [\"bin/sidebar\"]\n",
    )
    .unwrap();
    let runnable = source.join("bin/sidebar");
    fs::write(&runnable, "#!/bin/sh\nprintf 'fixture sidebar\\n'\n").unwrap();
    fs::set_permissions(&runnable, fs::Permissions::from_mode(0o755)).unwrap();
    git(&source, &["init", "-q"]);
    git(&source, &["add", "."]);
    git(
        &source,
        &[
            "-c",
            "user.name=cmux",
            "-c",
            "user.email=cmux@example.invalid",
            "commit",
            "-qm",
            "fixture",
        ],
    );
    let config = root.path().join("config/mux.json");
    fs::create_dir_all(config.parent().unwrap()).unwrap();
    fs::write(&config, "{}").unwrap();
    let url = format!("file://{}", source.display());

    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--socket"])
        .arg(root.path().join("missing.sock"))
        .args(["sidebar", "plugin", "install", &url, "--name", "fixture"])
        .current_dir(&project)
        .env("HOME", &home)
        .env("XDG_DATA_HOME", "~/.local/share")
        .env("CMUX_MUX_CONFIG", &config)
        .env_remove("CMUX_TUI_CONFIG")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));

    let leaked: Vec<_> =
        fs::read_dir(&project).unwrap().map(|entry| entry.unwrap().path()).collect();
    assert!(leaked.is_empty(), "the install wrote into the project: {leaked:?}");
    let installed = home.join(".local/share/cmux/mux-plugins/fixture/cmux-plugin.toml");
    assert!(installed.is_file(), "{installed:?}");
}
