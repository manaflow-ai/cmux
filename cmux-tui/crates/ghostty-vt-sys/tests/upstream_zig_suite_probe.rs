//! PROBE (work branch only, never on feat-cmux-next): runs ghostty-next's own
//! libghostty-vt Zig tests (Terminal, Screen, PageList: resize and reflow)
//! on the fleet, which only runs Rust tests.
use std::path::PathBuf;
use std::process::Command;

fn run(filter: Option<&str>) {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../ghostty-next");
    let zon = std::fs::read_to_string(dir.join("build.zig.zon")).unwrap();
    let version = zon
        .lines()
        .find_map(|l| l.trim().strip_prefix(".version = \"").map(|r| r.split('"').next().unwrap().to_string()))
        .unwrap();
    let zig = std::env::var("ZIG").unwrap_or_else(|_| "zig".into());
    let mut cmd = Command::new(zig);
    cmd.current_dir(&dir)
        .arg("build")
        .arg("test-lib-vt")
        .arg("-Demit-themes=false")
        .arg(format!("-Dversion-string={version}"))
        .arg("--summary")
        .arg("all");
    if let Some(f) = filter {
        cmd.arg(format!("-Dtest-filter={f}"));
    }
    let out = cmd.output().expect("zig");
    let text = format!("{}\n{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    for line in text.lines() {
        if line.contains("pass") || line.contains("fail") || line.contains("error") || line.contains("FAIL") || line.contains("skip") {
            eprintln!("ZIGSUITE {line}");
        }
    }
    let summary: Vec<&str> = text.lines().filter(|l| l.contains("passed") || l.contains("failed") || l.contains("skipped") || l.contains("leaked")).collect();
    panic!("ZIGSUMMARY status={:?}\n{}", out.status.code(), summary.join("\n"));
}

#[test]
fn ghostty_upstream_probe_full_lib_vt_suite() {
    run(None);
}
