use super::*;
use std::path::Path;

#[test]
fn the_shims_are_exactly_the_heavy_tables_programs() {
    let mut want = super::super::run_vm::heavy_programs();
    let mut have = SHIMMED.to_vec();
    want.sort_unstable();
    have.sort_unstable();
    assert_eq!(have, want);
}

#[test]
fn the_switch_reads_local_routed_and_otherwise_auto() {
    assert_eq!(Force::parse(None), Force::Auto);
    assert_eq!(Force::parse(Some("")), Force::Auto);
    assert_eq!(Force::parse(Some("auto")), Force::Auto);
    assert_eq!(Force::parse(Some(" LOCAL ")), Force::Local);
    assert_eq!(Force::parse(Some("routed")), Force::Routed);
    assert_eq!(Force::parse(Some("sideways")), Force::Auto);
}

#[test]
fn route_keeps_the_kill_switch_and_the_machine_above_the_switch() {
    // Auto: the heavy table.
    assert!(route(true, Some("vm"), "cargo build", Force::Auto).is_some());
    assert!(route(true, Some("vm"), "git status", Force::Auto).is_none());
    // Local keeps a heavy class here.
    assert!(route(true, Some("vm"), "cargo build", Force::Local).is_none());
    // Routed sends anything, naming the heavy class when there is one.
    assert_eq!(route(true, Some("vm"), "cargo test", Force::Routed), Some("a Rust test run"));
    assert!(route(true, Some("vm"), "ls -la", Force::Routed).is_some());
    // The kill switch and a missing machine win over routed.
    assert!(route(false, Some("vm"), "cargo build", Force::Routed).is_none());
    assert!(route(true, None, "cargo build", Force::Routed).is_none());
    assert!(route(true, Some(" "), "cargo build", Force::Routed).is_none());
}

#[test]
fn prepend_puts_the_shims_first_once() {
    let dir = Path::new("/h/exec-shims");
    assert_eq!(prepend("/usr/bin:/bin", dir), "/h/exec-shims:/usr/bin:/bin");
    assert_eq!(prepend("/usr/bin:/h/exec-shims:/bin", dir), "/h/exec-shims:/usr/bin:/bin");
    assert_eq!(prepend("", dir), "/h/exec-shims");
    assert_eq!(strip("/h/exec-shims:/usr/bin::/bin", "/h/exec-shims"), "/usr/bin:/bin");
}

#[test]
fn install_writes_every_shim_executable_and_leaves_a_current_one_alone() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("exec-shims");
    let bin = Path::new("/opt/acpmux");
    install(&dir, bin).unwrap();
    for program in SHIMMED {
        let text = std::fs::read_to_string(dir.join(program)).unwrap();
        assert!(text.starts_with("#!/bin/sh\n"));
        assert!(text.contains(&format!("run-vm --shim '{program}' --")));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(dir.join(program)).unwrap().permissions().mode();
            assert_eq!(mode & 0o111, 0o111, "{program} is executable");
        }
    }
    let before = std::fs::metadata(dir.join("cargo")).unwrap().modified().unwrap();
    install(&dir, bin).unwrap();
    assert_eq!(std::fs::metadata(dir.join("cargo")).unwrap().modified().unwrap(), before);
    // No temporary file is left behind.
    let names: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert!(names.iter().all(|n| !n.starts_with('.')), "{names:?}");
}

/// The shim, run by a real `sh`: with no Cloud machine id (or decided, or killed) it runs the
/// real program found past the shim folder, with the shim folder gone from its PATH; with one it
/// hands the program and its words to acpmux untouched.
#[cfg(unix)]
#[test]
fn the_shim_passes_through_or_hands_over_with_words_intact() {
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let shims = tmp.path().join("exec-shims");
    let real = tmp.path().join("real");
    std::fs::create_dir_all(&real).unwrap();
    // The "real" cargo prints its words and its PATH.
    let fake = real.join("cargo");
    std::fs::write(&fake, "#!/bin/sh\nprintf 'real:%s|' \"$@\"; printf 'PATH=%s\\n' \"$PATH\"\n")
        .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    // The "acpmux" prints what it was asked.
    let acpmux = tmp.path().join("acpmux");
    std::fs::write(&acpmux, "#!/bin/sh\nprintf 'acpmux:%s|' \"$@\"; echo\n").unwrap();
    std::fs::set_permissions(&acpmux, std::fs::Permissions::from_mode(0o755)).unwrap();
    install(&shims, &acpmux).unwrap();
    let path = format!("{}:{}:/usr/bin:/bin", shims.display(), real.display());
    let run = |env: &[(&str, &str)]| {
        let mut cmd = std::process::Command::new(shims.join("cargo"));
        cmd.args(["build", "a b", "--x=$HOME"]).env_clear().env("PATH", &path);
        for (k, v) in env {
            cmd.env(k, v);
        }
        String::from_utf8(cmd.output().unwrap().stdout).unwrap()
    };
    let through = run(&[]);
    assert!(through.starts_with("real:build|real:a b|real:--x=$HOME|"), "{through}");
    assert!(!through.contains("exec-shims"), "the shim folder left PATH: {through}");
    assert!(run(&[("CMUX_VM_ID", "vm_1"), (ROUTED_ENV, "fork")]).starts_with("real:"));
    assert!(run(&[("CMUX_VM_ID", "vm_1"), ("CMUX_RUN_VMS", "0")]).starts_with("real:"));
    let handed = run(&[("CMUX_VM_ID", "vm_1")]);
    assert_eq!(
        handed.trim(),
        "acpmux:run-vm|acpmux:--shim|acpmux:cargo|acpmux:--|acpmux:build|acpmux:a b|acpmux:--x=$HOME|"
    );
}

#[test]
fn a_trace_line_says_where_why_and_bytes() {
    let row = serde_json::json!({
        "at": "2026-11-25T12:40:00.123+00:00", "class": "a Rust build", "ran": "fork",
        "via": "shim", "program": "cargo", "wallMs": 41_200, "exit": 0, "patchBytes": 900,
        "outBytes": 100, "files": 2, "fork": "vm_f"
    });
    assert_eq!(
        trace_line(&row),
        "2026-11-25T12:40:00  fork  via shim   a Rust build (cargo), 41.2 s, exit 0, 1000 B back, \
         2 file(s), fork vm_f"
    );
    let here = serde_json::json!({
        "at": "2026-11-25T12:41:00Z", "class": "a Rust test run", "ran": "here",
        "cause": "fork: no machine.fork"
    });
    assert_eq!(
        trace_line(&here),
        "2026-11-25T12:41:00  here  via hook   a Rust test run — fork: no machine.fork"
    );
}

#[test]
fn the_rows_file_keeps_its_newer_half_past_the_bound() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("run-vm.jsonl");
    let text: String = (0..100).map(|i| format!("{{\"n\":{i}}}\n")).collect();
    std::fs::write(&path, &text).unwrap();
    super::super::run_vm::bound_rows(&path, 10_000);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "under the bound: untouched");
    super::super::run_vm::bound_rows(&path, 100);
    let kept = std::fs::read_to_string(&path).unwrap();
    assert!(kept.len() < text.len() && kept.ends_with("{\"n\":99}\n"), "{kept}");
    assert!(kept.lines().all(|l| serde_json::from_str::<serde_json::Value>(l).is_ok()));
}

#[test]
fn a_rows_file_whose_middle_splits_a_character_is_bounded_without_a_panic() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("run-vm.jsonl");
    // Two ASCII bytes, then 4-byte characters: the byte midpoint (105 of 211) lands inside one.
    let text = format!("ab{}\n{{\"n\":1}}\n", "𝄞".repeat(50));
    assert!(!text.is_char_boundary(text.len() / 2), "the fixture must split a character");
    std::fs::write(&path, &text).unwrap();
    super::super::run_vm::bound_rows(&path, 10);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "{\"n\":1}\n");
}

#[test]
fn a_rows_program_is_its_first_word_never_an_assignment_or_arguments() {
    use super::super::run_vm::program_of;
    assert_eq!(program_of("TOKEN=s3cret /usr/bin/cargo build").as_deref(), Some("cargo"));
    assert_eq!(program_of("cd x && cargo test").as_deref(), Some("cargo"));
    assert_eq!(program_of("cd x && ls").as_deref(), Some("cd"));
    assert_eq!(program_of("").as_deref(), None);
}
