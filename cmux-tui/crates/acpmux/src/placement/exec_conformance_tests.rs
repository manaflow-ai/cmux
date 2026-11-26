use super::*;
use crate::placement::run_vm::{Ran, ShellHarness, on_fork};
use crate::placement::sub_fork::Machines;
use crate::placement::sub_fork::tests::fork_of;
use crate::placement::sub_fork_run::{ForkLink, Job, Lines, run_job};
use std::collections::HashMap;
use std::os::unix::fs::PermissionsExt as _;
use std::sync::{Arc, Mutex};

/// Forks by copying the parent's disk (as a run VM's copy-on-write disk is); each fork's disk
/// kept by id.
#[derive(Default)]
struct CopyMachines {
    parent: Mutex<PathBuf>,
    disks: Arc<Mutex<HashMap<String, tempfile::TempDir>>>,
}

impl Machines for CopyMachines {
    async fn fork(&self, machine: &str, _key: &str) -> Result<String, String> {
        let disk = fork_of(&self.parent.lock().unwrap());
        let mut disks = self.disks.lock().unwrap();
        let id = format!("{machine}-fork-{}", disks.len());
        disks.insert(id.clone(), disk);
        Ok(id)
    }
    async fn delete(&self, machine: &str) -> Result<(), String> {
        self.disks.lock().unwrap().remove(machine);
        Ok(())
    }
}

/// Runs the command job with the real [`ShellHarness`] and [`run_job`] on the fork's disk, over
/// a pipe, as the ssh link does; the parent's paths mapped onto the fork's disk.
struct ShellLink {
    disks: Arc<Mutex<HashMap<String, tempfile::TempDir>>>,
    parent: PathBuf,
}

impl ForkLink for ShellLink {
    async fn start(&self, _fork: &str) -> Result<(), String> {
        Ok(())
    }
    async fn open(&self, fork: &str, job: &Job) -> Result<Lines, String> {
        let disk = self.disks.lock().unwrap().get(fork).map(|d| d.path().to_owned());
        let disk = disk.ok_or("no such fork")?;
        let mut job = job.clone();
        let rel = job.cwd.as_deref().and_then(|c| c.strip_prefix(&self.parent).ok());
        job.cwd = Some(disk.join(rel.unwrap_or(Path::new(""))));
        job.checkout = disk;
        let (ours, mut theirs) = tokio::io::duplex(64);
        tokio::spawn(async move {
            run_job(&job, &ShellHarness, &mut theirs).await.unwrap();
        });
        Ok(Box::pin(tokio::io::BufReader::new(ours)))
    }
}

/// What the routed side does to the fork's result before it lands: nothing, or a broken router.
#[derive(Clone, Copy, PartialEq)]
enum Fault {
    None,
    /// Drops every file change the run VM sent back.
    LoseFiles,
    /// Reports exit 0 whatever the command's exit.
    ZeroExit,
}

/// Local: `sh -c` here, as `run_vm::run_here` runs it, with the case's environment. Routed: the
/// real [`on_fork`] on a copied disk, its lines written to stdout as `run_vm::fork_or_here` does.
struct FakeRunner {
    fault: Fault,
}

impl Runner for FakeRunner {
    async fn run(&self, mode: Mode, case: &Case, dir: &Path) -> anyhow::Result<Outcome> {
        if mode == Mode::Local {
            let argv = vec!["/bin/sh".to_owned(), "-c".to_owned(), case.command.to_owned()];
            let env: Vec<(String, String)> =
                case.env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
            let (exit, stdout, stderr) = capture(&argv, dir, &env, &[], case.streams)?;
            return Ok(Outcome { exit, stdout, stderr, ran: "here", cause: None });
        }
        let machines = Arc::new(CopyMachines::default());
        *machines.parent.lock().unwrap() = dir.to_owned();
        let link = ShellLink { disks: machines.disks.clone(), parent: dir.to_owned() };
        let before = (self.fault == Fault::LoseFiles).then(|| fork_of(dir));
        let mut lines = Vec::new();
        let mut out = |l: &str| lines.push(l.to_owned());
        let ran = on_fork(
            machines,
            &link,
            "vm_c",
            "a conformance case",
            case.command,
            dir,
            None,
            &mut out,
        )
        .await;
        let stdout: Vec<u8> = lines.iter().flat_map(|l| format!("{l}\n").into_bytes()).collect();
        let (exit, ran, cause) = match ran {
            Ran::Done { exit, .. } => (exit, "fork", None),
            Ran::Here { row } => (-1, "here", row.cause),
        };
        if let Some(before) = before {
            // A router that drops what came back: the checkout as it was before the patch.
            restore(before.path(), dir);
        }
        let exit = if self.fault == Fault::ZeroExit { 0 } else { exit };
        Ok(Outcome { exit, stdout, stderr: Vec::new(), ran, cause })
    }
}

/// Make `dir` a copy of `before` again, `.git` aside (both test scratch trees).
fn restore(before: &Path, dir: &Path) {
    for e in std::fs::read_dir(dir).unwrap() {
        let e = e.unwrap();
        if e.file_name() == ".git" {
            continue;
        }
        let p = e.path();
        if std::fs::symlink_metadata(&p).unwrap().is_dir() {
            std::fs::remove_dir_all(&p).unwrap();
        } else {
            std::fs::remove_file(&p).unwrap();
        }
    }
    let ok = std::process::Command::new("cp")
        .arg("-a")
        .arg(format!("{}/.", before.display()))
        .arg(dir)
        .status()
        .unwrap()
        .success();
    assert!(ok);
}

fn print_rows(rows: &[Row]) -> String {
    rows.iter().map(|r| serde_json::to_string(r).unwrap() + "\n").collect()
}

/// The whole corpus, routed through the real fork path on a copied disk: every case without a
/// known divergence is identical, every known divergence still diverges (so a fix drops its
/// note), every routed side really ran on the fork, and the rows and summary say so.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_corpus_is_identical_local_and_routed_but_its_known_divergences() {
    let root = tempfile::tempdir().unwrap();
    let mut seen = Vec::new();
    let rows = run_suite(&FakeRunner { fault: Fault::None }, root.path(), CORPUS, |r| {
        seen.push(r.case.clone())
    })
    .await
    .unwrap();
    let dump = print_rows(&rows);
    assert_eq!(seen.len(), CORPUS.len(), "one row per case, as it is done");
    for row in &rows {
        if row.skipped.is_some() {
            continue;
        }
        assert_eq!(row.routed_ran, "fork", "{}: the routed side ran on the fork\n{dump}", row.case);
        if row.known.is_none() {
            assert!(row.identical, "{} differs: {:?}\n{dump}", row.case, row.diffs);
        } else {
            assert!(
                !row.identical,
                "{}: its known divergence is gone, drop the note\n{dump}",
                row.case
            );
        }
    }
    let s = Summary::of(&rows);
    assert!(s.ok, "{}\n{dump}", s.line());
    assert!(s.unexpected.is_empty() && s.known_gone.is_empty() && s.not_routed.is_empty());
    let known = CORPUS.iter().filter(|c| c.known.is_some()).count();
    assert_eq!(s.known, known);
    assert_eq!(s.identical, format!("{}/{}", s.total - known, s.total));
    // The cases the brief names are all there and not known-divergent.
    for name in [
        "cargo-build-test",
        "shell-writes-files",
        "failing-exit",
        "stdout-stderr-order",
        "files-create-delete-rename-symlink",
    ] {
        let case = CORPUS.iter().find(|c| c.name == name).expect(name);
        assert!(case.known.is_none(), "{name} must be identical, not a known divergence");
    }
    // The failing case's exit is its own on both sides, and the rename case's tree came back.
    let failing = rows.iter().find(|r| r.case == "failing-exit").unwrap();
    assert_eq!(failing.exit, Some(Pair { local: 7, routed: 7 }));
    let routed = root.path().join("files-create-delete-rename-symlink/routed");
    assert_eq!(std::fs::read_link(routed.join("link-to-new")).unwrap(), Path::new("moved/new.txt"));
    assert!(!routed.join("notes.txt").exists() && !routed.join("scratch").exists());
    let mode = std::fs::metadata(routed.join("tool.sh")).unwrap().permissions().mode();
    assert_eq!(mode & 0o111, 0o111, "the executable bit came back");
    // The cargo case built for real when cargo is here (and its target/ is the exemption).
    if on_path("cargo") {
        let cargo = rows.iter().find(|r| r.case == "cargo-build-test").unwrap();
        assert!(cargo.skipped.is_none());
        let local = root.path().join("cargo-build-test/local");
        assert!(local.join("target").is_dir() && local.join("Cargo.lock").is_file());
        assert!(root.path().join("cargo-build-test/routed/Cargo.lock").is_file(), "{dump}");
    }
}

/// A router that loses the run VM's file changes, or its exit code, is caught: the rows say
/// `tree` or `exit`, and the summary is not ok.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_broken_router_is_caught() {
    let pick = |names: &[&str]| -> Vec<Case> {
        CORPUS.iter().filter(|c| names.contains(&c.name)).copied().collect()
    };
    let root = tempfile::tempdir().unwrap();
    let cases = pick(&["shell-writes-files", "files-create-delete-rename-symlink"]);
    let rows = run_suite(&FakeRunner { fault: Fault::LoseFiles }, root.path(), &cases, |_| {})
        .await
        .unwrap();
    for row in &rows {
        assert!(!row.identical && row.diffs == ["tree"], "{}", print_rows(&rows));
        assert!(!row.tree_paths.is_empty());
        let tree = row.tree.as_ref().unwrap();
        assert_ne!(tree.local, tree.routed);
    }
    let writes = rows.iter().find(|r| r.case == "shell-writes-files").unwrap();
    assert!(writes.tree_paths.contains(&"out/a.txt".to_owned()), "{:?}", writes.tree_paths);
    let s = Summary::of(&rows);
    assert!(!s.ok && s.unexpected.len() == 2, "{}", s.line());
    assert!(s.line().starts_with("identical 0/2"), "{}", s.line());

    let root = tempfile::tempdir().unwrap();
    let rows = run_suite(
        &FakeRunner { fault: Fault::ZeroExit },
        root.path(),
        &pick(&["failing-exit"]),
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(rows[0].diffs, ["exit"]);
    assert_eq!(rows[0].exit, Some(Pair { local: 7, routed: 0 }));
    assert!(rows[0].line().starts_with("DIFF  failing-exit (exit)"), "{}", rows[0].line());
}

#[test]
fn the_router_notes_are_not_output_and_name_where_it_ran() {
    let routed = b"[run-vm] a Rust build: running on a fork of this machine\nbuilt\n\
[run-vm] ran on a run VM: exit 0, 2 file(s) back, 3 s\n";
    let (kept, verdict) = split_notes(routed);
    assert_eq!(kept, b"built\n");
    assert_eq!(verdict, Some(("fork", None)));
    let here = b"[run-vm] ran here: fork: the pool has no room\nout\n";
    let (kept, verdict) = split_notes(here);
    assert_eq!(kept, b"out\n");
    assert_eq!(verdict, Some(("here", Some("fork: the pool has no room".to_owned()))));
    // A line the router writes into the output itself is a difference, not a note.
    let mid = b"[run-vm] the run VM failed mid-command: gone\n";
    assert_eq!(split_notes(mid).0, mid.to_vec());
    assert_eq!(split_notes(b"no newline").0, b"no newline");
    assert_eq!(split_notes(b"").1, None);
}

#[test]
fn durations_are_the_only_rewrite() {
    assert_eq!(
        normalize(b"test result: ok. 1 passed; finished in 0.52s\n"),
        b"test result: ok. 1 passed; finished in <t>s\n"
    );
    assert_eq!(normalize(b"v1.2 and 3 s"), b"v1.2 and 3 s");
}

#[test]
fn the_tree_hash_sees_contents_modes_symlinks_and_empty_folders_but_not_the_exemptions() {
    let t = tempfile::tempdir().unwrap();
    let p = t.path();
    std::fs::write(p.join("a"), "one").unwrap();
    std::fs::create_dir_all(p.join("d/e")).unwrap();
    std::os::unix::fs::symlink("a", p.join("l")).unwrap();
    let base = tree_of(p).unwrap();
    assert_eq!(base.keys().collect::<Vec<_>>(), ["a", "d", "d/e", "l"]);
    assert_eq!(base["l"], "link -> a");
    let digest = tree_digest(&base);
    // The exemptions, and only at the root, change nothing.
    std::fs::create_dir_all(p.join(".git/objects")).unwrap();
    std::fs::create_dir_all(p.join("target/debug")).unwrap();
    std::fs::write(p.join("target/debug/x"), "obj").unwrap();
    assert_eq!(tree_digest(&tree_of(p).unwrap()), digest);
    std::fs::create_dir_all(p.join("d/target")).unwrap();
    assert_ne!(tree_digest(&tree_of(p).unwrap()), digest, "a nested target/ is no exemption");
    std::fs::remove_dir(p.join("d/target")).unwrap();
    // Contents, a mode, a link's target, an empty folder each change it.
    let changes: &[&dyn Fn()] = &[
        &|| std::fs::write(p.join("a"), "two").unwrap(),
        &|| std::fs::set_permissions(p.join("a"), std::fs::Permissions::from_mode(0o755)).unwrap(),
        &|| {
            std::fs::remove_file(p.join("l")).unwrap();
            std::os::unix::fs::symlink("d", p.join("l")).unwrap();
        },
        &|| std::fs::create_dir(p.join("d/e/empty")).unwrap(),
    ];
    let mut last = digest;
    for change in changes {
        change();
        let now = tree_of(p).unwrap();
        let d = tree_digest(&now);
        assert_ne!(d, last);
        last = d;
    }
    let paths = tree_diff(&base, &tree_of(p).unwrap());
    assert_eq!(paths, ["a", "d/e/empty", "l"]);
}

#[test]
fn rows_and_the_summary_read_as_the_brief_asks() {
    let case = CORPUS.iter().find(|c| c.name == "failing-exit").unwrap();
    let side = |exit, out: &str, ran| Outcome {
        exit,
        stdout: out.as_bytes().to_vec(),
        stderr: Vec::new(),
        ran,
        cause: (ran == "here").then(|| "fork: no machine.fork".to_owned()),
    };
    let tree: BTreeMap<String, String> = [("a".to_owned(), "file 644 00".to_owned())].into();
    let same = compare(case, &side(7, "x\n", "here"), &side(7, "x\n", "fork"), (&tree, &tree));
    assert!(same.identical && same.diffs.is_empty() && same.stdout.is_none());
    let v = serde_json::to_value(&same).unwrap();
    assert_eq!(v["case"], "failing-exit");
    assert_eq!(v["identical"], true);
    assert_eq!(v["routedRan"], "fork");
    assert_eq!(v["exit"], serde_json::json!({"local": 7, "routed": 7}));
    assert!(v["tree"]["local"].as_str().unwrap().len() == 64);
    let differs = compare(case, &side(7, "x\n", "here"), &side(7, "y\n", "here"), (&tree, &tree));
    assert_eq!(differs.diffs, ["stdout"]);
    assert_eq!(differs.stdout, Some(Pair { local: "x\n".into(), routed: "y\n".into() }));
    assert!(differs.line().contains("[routed side ran here: fork: no machine.fork]"));
    let s = Summary::of(&[same, differs]);
    assert_eq!(s.identical, "1/2");
    assert_eq!(s.on_run_vm, 1);
    assert_eq!(s.not_routed, ["failing-exit"]);
    assert!(!s.ok);
    assert!(s.line().starts_with("identical 1/2; on a run VM 1/2"), "{}", s.line());
    assert_eq!(s.exempt.len(), EXEMPT.len());
    // Nothing ran: not ok.
    assert!(!Summary::of(&[]).ok);
}

#[test]
fn the_corpus_names_are_unique_and_every_exemption_says_why() {
    let mut names: Vec<_> = CORPUS.iter().map(|c| c.name).collect();
    names.sort_unstable();
    names.dedup();
    assert_eq!(names.len(), CORPUS.len());
    assert!(EXEMPT.iter().all(|(p, why)| !p.contains('/') && why.len() > 20));
    assert!(CORPUS.iter().all(|c| c.known.is_none_or(|k| k.len() > 20)));
}

#[test]
fn the_fixture_is_a_checkout_with_uncommitted_work() {
    let t = tempfile::tempdir().unwrap();
    let p = t.path().join("fx");
    write_fixture(&p).unwrap();
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(&p)
        .args(["status", "--porcelain"])
        .output()
        .unwrap();
    let status = String::from_utf8(out.stdout).unwrap();
    assert!(status.contains(" M edited.txt") && status.contains("?? draft.txt"), "{status}");
    let mode = std::fs::metadata(p.join("tool.sh")).unwrap().permissions().mode();
    assert_eq!(mode & 0o111, 0, "a case sets the bit");
}
