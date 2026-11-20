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

/// A plugin source repository, a home, a project folder and a mux config under one temporary root.
struct Fixture {
    root: tempfile::TempDir,
    home: std::path::PathBuf,
    project: std::path::PathBuf,
    config: std::path::PathBuf,
    url: String,
}

fn fixture() -> Fixture {
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
    Fixture { root, home, project, config, url }
}

fn install(fixture: &Fixture, env: &[(&str, &std::ffi::OsStr)]) -> std::process::Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .args(["--json", "--socket"])
        .arg(fixture.root.path().join("missing.sock"))
        .args(["sidebar", "plugin", "install", &fixture.url, "--name", "fixture"])
        .current_dir(&fixture.project)
        .env("HOME", &fixture.home)
        .env("CMUX_MUX_CONFIG", &fixture.config)
        .env_remove("XDG_DATA_HOME")
        .env_remove("CMUX_NEXT_MUX_PLUGINS_DIR")
        .env_remove("CMUX_TUI_CONFIG")
        .env_remove("CMUX_TUI_SOCKET");
    for (key, value) in env {
        command.env(key, value);
    }
    command.output().unwrap()
}

#[test]
fn cmux_next_plugin_install_ignores_a_relative_xdg_data_home() {
    let fixture = fixture();
    let output = install(&fixture, &[("XDG_DATA_HOME", std::ffi::OsStr::new("~/.local/share"))]);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));

    let leaked: Vec<_> =
        fs::read_dir(&fixture.project).unwrap().map(|entry| entry.unwrap().path()).collect();
    assert!(leaked.is_empty(), "the install wrote into the project: {leaked:?}");
    let installed = fixture.home.join(".local/share/cmux/mux-plugins/fixture/cmux-plugin.toml");
    assert!(installed.is_file(), "{installed:?}");
}

/// A DEV build names its own plugin folder (`CMUX_NEXT_MUX_PLUGINS_DIR`, BuildStatePaths): a plugin
/// it installs never lands in `~/.local/share/cmux/mux-plugins`, NIGHTLY's and stable's.
#[test]
fn dev_build_own_mux_plugins_dir_takes_the_install() {
    let fixture = fixture();
    let own = fixture.root.path().join("build/mux-plugins");
    let output = install(&fixture, &[("CMUX_NEXT_MUX_PLUGINS_DIR", own.as_os_str())]);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(own.join("fixture/cmux-plugin.toml").is_file(), "not in the build's own folder");
    let shared = fixture.home.join(".local/share/cmux/mux-plugins");
    assert!(!shared.exists(), "the DEV build installed into the shared folder");
}
