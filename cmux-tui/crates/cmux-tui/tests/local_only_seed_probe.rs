//! What lands on a Cloud machine when Move to Cloud seeds a local-only folder: a git repository
//! with no remote, and a folder that is not git at all (RFD 0066, hq#20711). It prints what the
//! receiver holds and the push's answer, then the way back: one file edited there, Bring Back
//! (`cmux link seed pull --or-copy`), and what came home. A probe, not a gate: it asserts only
//! that each push answered.
//!
//! `cargo test -p cmux-tui --test local_only_seed_probe -- --ignored --nocapture`
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::Value;

/// The fixture's files, as hq#20711's `run/c` and `run/d` hold them.
fn fill(dir: &Path, with_git: bool) {
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::write(dir.join(".gitignore"), "node_modules/\n").unwrap();
    fs::write(dir.join("package.json"), "{\"name\":\"x\"}\n").unwrap();
    fs::write(dir.join("src/index.js"), "console.log(1)\n").unwrap();
    if with_git {
        git(dir, &["init", "-q", "-b", "main"]);
        git(dir, &["add", "."]);
        git(dir, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one"]);
    }
    fs::write(dir.join("src/index.js"), "console.log(1)\nconsole.log(2)\n").unwrap();
    if with_git {
        git(dir, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-am", "two"]);
    }
    fs::write(dir.join("src/index.js"), "console.log(1)\nconsole.log(2)\nchanged\n").unwrap();
    fs::write(dir.join("untracked.txt"), "new\n").unwrap();
    fs::write(dir.join(".env"), "SECRET=1\n").unwrap();
    fs::create_dir_all(dir.join("node_modules/leftpad")).unwrap();
    fs::write(dir.join("node_modules/leftpad/index.js"), "module.exports=1\n").unwrap();
    // 30 MiB that does not compress.
    let mut big = Vec::with_capacity(30 << 20);
    let mut x: u64 = 0x9e37_79b9_7f4a_7c15;
    while big.len() < 30 << 20 {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        big.extend_from_slice(&x.to_le_bytes());
    }
    fs::write(dir.join("big.bin"), big).unwrap();
}

/// Every file under `dir` with its size, `.git` as one count line.
fn listing(dir: &Path) -> String {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<String>, git: &mut (u64, u64)) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            let rel = path.strip_prefix(root).unwrap().to_string_lossy().into_owned();
            let meta = fs::symlink_metadata(&path).unwrap();
            if meta.is_dir() {
                walk(root, &path, out, git);
            } else if rel.starts_with(".git/") {
                git.0 += 1;
                git.1 += meta.len();
            } else {
                out.push(format!("{rel}\t{}", meta.len()));
            }
        }
    }
    let (mut out, mut git) = (Vec::new(), (0, 0));
    walk(dir, dir, &mut out, &mut git);
    out.sort();
    let total: u64 =
        out.iter().map(|l| l.rsplit('\t').next().unwrap().parse::<u64>().unwrap()).sum();
    let mut text = out.join("\n");
    if git.0 > 0 {
        text.push_str(&format!("\n.git/ ({} files, {} B)", git.0, git.1));
    }
    text.push_str(&format!(
        "\n= {} files, {} B outside .git; {} files, {} B with it",
        out.len(),
        total,
        out.len() as u64 + git.0,
        total + git.1
    ));
    text
}

fn brief(answer: &Value) -> Value {
    let keys =
        ["ok", "mode", "fallback_code", "fallback", "skipped", "bytes", "error_code", "error"];
    let mut kept = serde_json::Map::new();
    if let Some(object) = answer.as_object() {
        for (key, value) in object {
            if keys.contains(&key.as_str()) || key.contains("byte") || key.contains("skip") {
                kept.insert(key.clone(), value.clone());
            }
        }
    }
    Value::Object(kept)
}

#[test]
#[ignore = "a probe for RFD 0066; prints what lands, run by hand"]
fn local_only_folders_seeded_to_a_cloud_machine() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("lop-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());
    let github = root.join("github");
    fs::create_dir_all(&github).unwrap();
    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_TEST_GIT_SEED_GITHUB", github.to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-local-only-probe".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    let mut answered = Vec::new();
    for (name, with_git) in [("c", true), ("d", false)] {
        let local = mac.home().join(format!("run/{name}"));
        fill(&local, with_git);
        let remote = vm.home().join(format!("work/{name}"));
        let started = Instant::now();
        let (ok, pushed) = run_json(
            Command::new(bin())
                .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .args(["link", "seed", "push", "--socket"])
                .arg(&vm.socket)
                .arg(&local)
                .arg(&remote),
        );
        let secs = started.elapsed().as_secs_f64();
        println!("==== {name} ({}) ====", if with_git { "git, no remote" } else { "not git" });
        println!("push exit ok={ok} in {secs:.2} s: {}", brief(&pushed));
        println!("push answer (whole): {pushed}");
        println!("-- receiver {}:\n{}", remote.display(), listing(&remote));
        answered.push(pushed["ok"].is_boolean());

        // The way back: one file edited there, then Bring Back.
        if remote.join("src/index.js").exists() {
            fs::write(remote.join("src/index.js"), "console.log(1)\nedited on the vm\n").unwrap();
        }
        fs::write(remote.join("made-on-vm.txt"), "vm\n").unwrap();
        let started = Instant::now();
        let (ok, back) = run_json(
            Command::new(bin())
                .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .args(["link", "seed", "pull", "--socket"])
                .arg(&vm.socket)
                .arg(&local)
                .arg(&remote)
                .arg("--or-copy"),
        );
        let secs = started.elapsed().as_secs_f64();
        println!("bring back exit ok={ok} in {secs:.2} s: {}", brief(&back));
        println!("bring back answer (whole): {back}");
        println!(
            "-- home src/index.js: {:?}; made-on-vm.txt: {:?}; .env: {:?}; node_modules kept: {}",
            fs::read_to_string(local.join("src/index.js")).ok(),
            fs::read_to_string(local.join("made-on-vm.txt")).ok(),
            fs::read_to_string(local.join(".env")).ok(),
            local.join("node_modules/leftpad/index.js").exists()
        );
        println!("-- home {}:\n{}", local.display(), listing(&local));
    }
    assert!(answered.iter().all(|a| *a), "a push gave no ok field");
}
