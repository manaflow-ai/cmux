use super::{render, with_toolchain};
use crate::plan::MachineConfig;
use std::process::Command;

#[test]
fn a_package_manager_line_installs_its_tool_when_the_machine_lacks_it() {
    let line = with_toolchain("go mod download");
    assert!(
        line.starts_with("export PATH=\"$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH\"; ")
    );
    assert!(line.contains("command -v go >/dev/null 2>&1 || {"));
    assert!(line.contains("mise use -g go@latest"));
    assert!(line.ends_with("; go mod download"));
    assert!(with_toolchain("cargo fetch").contains("mise use -g rust@latest"));
    assert!(with_toolchain("bundle install").contains("mise use -g ruby@latest"));
}

#[test]
fn other_lines_only_get_mises_path() {
    let line = with_toolchain("docker compose up -d db");
    assert!(!line.contains("mise use"));
    assert!(line.ends_with("; docker compose up -d db"));
}

#[test]
fn render_guards_setup_and_check_lines() {
    let config = MachineConfig {
        setup: vec!["go mod download".into()],
        check: vec!["go vet ./...".into()],
        ..MachineConfig::default()
    };
    let parsed: toml::Table = render(&config).parse().unwrap();
    let run = parsed["setup"]["run"][0].as_str().unwrap();
    assert!(run.contains("mise use -g go@latest") && run.ends_with("go mod download"));
    let check = parsed["setup"]["check"][0].as_str().unwrap();
    assert!(check.ends_with("go vet ./..."));
}

/// The line itself runs: bash parses it, and with the tool present the guard installs nothing.
#[test]
fn a_guarded_line_runs_under_bash_when_the_tool_is_present() {
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("bin");
    std::fs::create_dir(&bin).unwrap();
    let npm = bin.join("npm");
    std::fs::write(&npm, "#!/bin/sh\necho ran-npm \"$@\"\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&npm, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let out = Command::new("bash")
        .arg("-c")
        .arg(with_toolchain("npm ci"))
        .env("HOME", dir.path())
        .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "ran-npm ci");
}
