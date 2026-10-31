//! Fuzz-catalog row l (security), path handling: the `fs-v1` sandbox
//! (`fs_ops::Roots`, `FsService`) that serves a remote peer's file requests.
//! Random request paths built from `.`, `..`, symlinks that point outside
//! (absolute, relative, chained, looping), NUL bytes, empty and long
//! components, and names with separators. The oracle: no request reads,
//! lists, writes, creates, renames or deletes anything outside the root;
//! every refusal is a typed `FsError`; nothing panics.
//!
//! Seeded: `CMUX_FUZZ_SEED=<seed>` replays (the seed is printed);
//! `CMUX_FUZZ_CASES=<n>` sets the cases per op.
#![cfg(unix)]

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::symlink;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_tui_core::fs_ops::{FsService, Roots};
use serde_json::{Value, json};

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: usize) -> usize {
        if n == 0 { 0 } else { (self.next() % n as u64) as usize }
    }
    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

fn seed(test: &str) -> u64 {
    let seed =
        std::env::var("CMUX_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or_else(|| {
            SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1)
        });
    eprintln!("fuzz-seed {test} {seed} (replay: CMUX_FUZZ_SEED={seed})");
    seed
}

fn cases() -> usize {
    std::env::var("CMUX_FUZZ_CASES")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|n| *n > 0)
        .unwrap_or(1500)
}

/// `base/root` is served; `base/outside` holds the secret. Every symlink
/// that leaves the root points into `base/outside` (never `/`), so a
/// mutation that escapes can only touch the test's own folder.
struct Sandbox {
    base: PathBuf,
    root: PathBuf,
    outside: PathBuf,
    secret: String,
}

impl Sandbox {
    fn new(label: &str, rng: &mut Rng) -> Self {
        let base = PathBuf::from("/tmp").join(format!(
            "cxfs-{label}-{}-{:x}",
            std::process::id(),
            rng.next()
        ));
        let root = base.join("root");
        let outside = base.join("outside");
        fs::create_dir_all(root.join("in/deeper")).unwrap();
        fs::create_dir_all(outside.join("sub")).unwrap();
        let secret = format!("FUZZ-SECRET-{:016x}", rng.next());
        fs::write(outside.join("secret.txt"), &secret).unwrap();
        fs::write(outside.join("sub/secret.txt"), &secret).unwrap();
        let sandbox = Self { base, root, outside, secret };
        sandbox.restore();
        sandbox
    }

    /// (Re)creates the root's files and symlinks; a delete or a rename in an
    /// earlier case may have removed them.
    fn restore(&self) {
        let (root, outside) = (&self.root, &self.outside);
        let _ = fs::create_dir_all(root.join("in/deeper"));
        for file in ["in/a.txt", "note.txt"] {
            if fs::symlink_metadata(root.join(file)).is_err() {
                let _ = fs::write(root.join(file), "inside");
            }
        }
        for (name, target) in [
            ("out_abs", outside.to_str().unwrap().to_string()),
            ("out_file", outside.join("secret.txt").to_str().unwrap().to_string()),
            ("out_rel", "../outside".to_string()),
            ("out_rel_file", "../outside/secret.txt".to_string()),
            ("chain1", "chain2".to_string()),
            ("chain2", "in/up".to_string()),
            ("loop", "loop".to_string()),
            ("in_link", "in".to_string()),
            ("dotdot", "..".to_string()),
            ("dangling", "nowhere/at/all".to_string()),
            ("in/up", "../../outside".to_string()),
            ("in/deeper/top", "../..".to_string()),
        ] {
            if fs::symlink_metadata(root.join(name)).is_err() {
                let _ = symlink(target, root.join(name));
            }
        }
    }

    fn service(&self) -> FsService {
        FsService::new(Roots::new([self.root.clone()]))
    }

    /// Names, sizes and contents of everything under `outside`.
    fn outside_state(&self) -> BTreeMap<String, String> {
        fn walk(dir: &Path, prefix: &str, out: &mut BTreeMap<String, String>) {
            let Ok(entries) = fs::read_dir(dir) else { return };
            for entry in entries.flatten() {
                let name = format!("{prefix}/{}", entry.file_name().to_string_lossy());
                let path = entry.path();
                if path.is_dir() {
                    out.insert(name.clone(), "dir".into());
                    walk(&path, &name, out);
                } else {
                    out.insert(name, fs::read_to_string(&path).unwrap_or_else(|_| "?".into()));
                }
            }
        }
        let mut out = BTreeMap::new();
        walk(&self.outside, "", &mut out);
        // The base folder too: an escape may create a sibling of root.
        for entry in fs::read_dir(&self.base).into_iter().flatten().flatten() {
            out.insert(format!("base:{}", entry.file_name().to_string_lossy()), String::new());
        }
        out
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

const COMPONENTS: &[&str] = &[
    ".",
    "..",
    "in",
    "a.txt",
    "note.txt",
    "deeper",
    "top",
    "up",
    "out_abs",
    "out_file",
    "out_rel",
    "out_rel_file",
    "chain1",
    "chain2",
    "loop",
    "in_link",
    "dotdot",
    "dangling",
    "secret.txt",
    "sub",
    "outside",
    "root",
    "",
    "x\u{0}y",
    "%2e%2e",
    "..\\..",
    "\u{2025}",
    "．．",
];

/// A request path: mostly under the root's spelling, sometimes not.
fn request_path(sandbox: &Sandbox, rng: &mut Rng) -> String {
    let root = fs::canonicalize(&sandbox.root).unwrap();
    let long = "n".repeat(300);
    let mut path = match rng.below(12) {
        0 => sandbox.outside.join("secret.txt").to_str().unwrap().to_string(),
        1 => "in/a.txt".to_string(),
        2 => format!("{}/../outside/secret.txt", sandbox.root.display()),
        _ => root.to_str().unwrap().to_string(),
    };
    for _ in 0..rng.below(6) {
        path.push('/');
        if rng.below(20) == 0 {
            path.push_str(&long);
        } else {
            path.push_str(rng.pick(COMPONENTS));
        }
    }
    if rng.below(10) == 0 {
        path.push('/');
    }
    if rng.below(30) == 0 {
        path = "x".repeat(5000);
    }
    path
}

fn call(service: &FsService, cmd: &str, params: Value) -> Result<Result<Value, String>, String> {
    catch_unwind(AssertUnwindSafe(|| {
        service.call("fuzz", cmd, params).map_err(|e| format!("{e:?}"))
    }))
    .map_err(|panic| {
        panic
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_default()
    })
}

fn shown(value: &Value) -> String {
    value.to_string().chars().take(400).collect()
}

#[test]
fn fuzz_bl_no_read_list_or_stat_reaches_outside_the_root() {
    let mut rng = Rng(seed("fs_read_side"));
    let sandbox = Sandbox::new("read", &mut rng);
    let service = sandbox.service();
    let mut findings = Vec::new();
    let mut ok = 0usize;
    for n in 0..cases() * 3 {
        let path = request_path(&sandbox, &mut rng);
        let (cmd, params) = match n % 3 {
            0 => ("fs.read", json!({"path": path, "offset": 0, "max_bytes": 65536})),
            1 => ("fs.list", json!({"path": path, "limit": 1000})),
            _ => ("fs.stat", json!({"path": path})),
        };
        match call(&service, cmd, params.clone()) {
            Err(panic) => findings.push(format!("PANIC {cmd} {}: {panic}", shown(&params))),
            Ok(Err(_typed)) => {}
            Ok(Ok(answer)) => {
                ok += 1;
                let text = answer.to_string();
                if text.contains(&sandbox.secret) || text.contains("\"secret.txt\"") {
                    findings.push(format!("ESCAPE {cmd} {} -> {}", shown(&params), shown(&answer)));
                }
            }
        }
    }
    eprintln!("FUZZ-SUMMARY fs-read cases={} ok={ok} findings={}", cases() * 3, findings.len());
    assert!(
        findings.is_empty(),
        "{} fs findings: {:#?}",
        findings.len(),
        &findings[..findings.len().min(8)]
    );
}

const NAMES: &[&str] = &[
    "new.txt",
    "..",
    ".",
    "a/b",
    "",
    "x\u{0}y",
    "../outside/evil",
    "out_abs",
    "secret.txt",
    "..\\evil",
    "dir",
];

#[test]
fn fuzz_bl_no_write_mkdir_rename_or_delete_changes_anything_outside_the_root() {
    let mut rng = Rng(seed("fs_write_side"));
    let sandbox = Sandbox::new("write", &mut rng);
    let service = sandbox.service();
    let before = sandbox.outside_state();
    let mut findings = Vec::new();
    for n in 0..cases() {
        let path = request_path(&sandbox, &mut rng);
        let name = rng.pick(NAMES).to_string();
        let (cmd, params) = match n % 5 {
            0 => {
                let mode = *rng.pick(&["create", "overwrite"]);
                ("fs.write", json!({"path": path, "text": "FUZZ-WROTE", "mode": mode}))
            }
            1 => ("fs.mkdir", json!({"path": path, "name": name})),
            2 => ("fs.rename", json!({"path": path, "name": name})),
            3 => ("fs.delete", json!({"paths": [path], "permanent": true})),
            _ => (
                "fs.write",
                json!({"path": format!("{path}/{name}"), "text": "FUZZ-WROTE", "mode": "create"}),
            ),
        };
        match call(&service, cmd, params.clone()) {
            Err(panic) => findings.push(format!("PANIC {cmd} {}: {panic}", shown(&params))),
            Ok(_) => {}
        }
        let after = sandbox.outside_state();
        if after != before {
            let changed: Vec<_> = after
                .iter()
                .filter(|(k, v)| before.get(*k) != Some(*v))
                .map(|(k, _)| k.clone())
                .collect();
            let gone: Vec<_> = before.keys().filter(|k| !after.contains_key(*k)).cloned().collect();
            findings.push(format!(
                "ESCAPE {cmd} {}: changed {changed:?} removed {gone:?}",
                shown(&params)
            ));
            break;
        }
        sandbox.restore();
    }
    eprintln!("FUZZ-SUMMARY fs-write cases={} findings={}", cases(), findings.len());
    assert!(
        findings.is_empty(),
        "{} fs findings: {:#?}",
        findings.len(),
        &findings[..findings.len().min(8)]
    );
}
