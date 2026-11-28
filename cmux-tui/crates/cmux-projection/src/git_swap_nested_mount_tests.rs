//! Issue 57201 through a real mount: a projected folder of clones (itself no repository) swaps a
//! nested clone's `.git` to its own machine repository ([`run_nested`]), git there reads the same
//! repository as on the Mac with the unpushed commits local, and Bring Back's listing and mark see
//! a commit made on the machine.

use super::*;
use crate::layer::Layer;
use std::sync::atomic::Ordering;

#[test]
fn a_nested_clone_swaps_through_the_mount_and_bring_back_sees_its_commits() {
    let repo = repo(6, 4096);
    // The Mac's folder of clones: `work/` holds the clone at `work/app`, and no `.git` itself.
    let work = repo.mac.parent().unwrap().join("work");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::rename(&repo.mac, work.join("app")).unwrap();
    std::fs::write(work.join("notes.txt"), "not a repository\n").unwrap();
    let mac = work.join("app");
    let Some(p) = mount(&work) else { return };
    let at = p.at.path();
    assert_eq!(nested_repositories(at), ["app"]);
    let before = view(&at.join("app")).unwrap();
    assert_eq!(before, view(&mac).unwrap());

    let forget = |folder: u64| p.mounted.forget_entry(folder, ".git");
    let started = std::time::Instant::now();
    let outcome = run_nested(&p.overlay, &forget, at, "app", p.state.path()).unwrap();
    println!("nested swap of app/.git: {outcome:?} in {} ms", started.elapsed().as_millis());
    let local = local_dir(p.state.path(), "app");
    assert_eq!(outcome, Outcome::Swapped(local.clone()));
    assert_eq!(std::fs::read_link(at.join("app/.git")).unwrap(), local);
    // The same repository as the Mac's: HEAD, log, refs, the staged change, the unpushed file.
    assert_eq!(view(&at.join("app")).unwrap(), before);
    // The unpushed commits are local: they read with the public remote gone.
    std::fs::rename(&repo.public, repo.public.with_extension("gone")).unwrap();
    assert_eq!(sh(&at.join("app"), &["show", "HEAD~1:unpushed.txt"]), "only on the mac\n");
    assert_eq!(
        run_nested(&p.overlay, &forget, at, "app", p.state.path()).unwrap(),
        Outcome::Already
    );

    // Bring Back: the swapped `.git` lists as the files its git leg reads, without the swap's
    // packs, and a commit on the machine changes the mark and lists its objects.
    let listed = |layer: &Layer| -> Vec<String> {
        layer
            .upper
            .iter()
            .map(|entry| entry.path.clone())
            .filter(|path| path.starts_with("app/.git/"))
            .collect()
    };
    let layer = Layer::collect(p.state.path()).unwrap();
    let paths = listed(&layer);
    assert!(paths.contains(&"app/.git/HEAD".to_owned()), "{paths:?}");
    assert!(!paths.iter().any(|path| path.contains("objects/pack/pack-")), "{paths:?}");
    let mark = crate::state::mark(p.state.path()).unwrap();
    std::fs::write(at.join("app/made-here.txt"), "the machine's file\n").unwrap();
    sh(&at.join("app"), &["add", "made-here.txt"]);
    sh(&at.join("app"), &["commit", "--quiet", "-m", "on the machine"]);
    assert_ne!(crate::state::mark(p.state.path()).unwrap(), mark);
    let commit = sh(&at.join("app"), &["rev-parse", "HEAD"]);
    let paths = listed(&Layer::collect(p.state.path()).unwrap());
    let loose = format!("app/.git/objects/{}/{}", &commit[..2], commit[2..].trim());
    assert!(paths.contains(&loose), "the machine's commit object: {paths:?}");
    // The Mac's own clone is untouched.
    assert_eq!(view(&mac).unwrap(), before);
}

/// The Mac's files as [`Disk`] reads them, counting what crosses the link: every byte, and the
/// bytes of files under a `.git` folder.
struct Counted {
    disk: Disk,
    git_entries: std::collections::HashSet<u32>,
    bytes: std::sync::atomic::AtomicU64,
    git_bytes: std::sync::atomic::AtomicU64,
}

impl Counted {
    fn count(&self, entry: u32, len: usize) {
        let len = len as u64;
        self.bytes.fetch_add(len, Ordering::Relaxed);
        if self.git_entries.contains(&entry) {
            self.git_bytes.fetch_add(len, Ordering::Relaxed);
        }
    }

    fn take(&self) -> (u64, u64) {
        (self.bytes.swap(0, Ordering::Relaxed), self.git_bytes.swap(0, Ordering::Relaxed))
    }
}

impl Fetch for Counted {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let result = self.disk.read(entry, offset, len);
        self.count(entry, result.as_ref().map_or(0, Vec::len));
        result
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        let result = self.disk.batch(entries);
        for (entry, read) in entries.iter().zip(&result) {
            self.count(*entry, read.as_ref().map_or(0, Vec::len));
        }
        result
    }
}

/// Issue 57201 reproduced and fixed, through a real mount: in a projected folder of clones, `git`
/// in a nested clone reads that clone's packs over the Mac's link. Once the clone's `.git` swaps,
/// the same commands read nothing of `.git` over the link.
#[test]
fn git_in_a_nested_clone_reads_its_packs_over_the_link_until_it_swaps() {
    let repo = repo(120, 64 * 1024);
    let work = repo.mac.parent().unwrap().join("work");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::rename(&repo.mac, work.join("app")).unwrap();
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let (manifest, disk) = project(&work);
    let git_entries = (0..manifest.len() as u32)
        .filter(|&index| {
            manifest.entry(index).is_some_and(|entry| entry.kind == Kind::File)
                && manifest.path_of(index).contains(".git/")
        })
        .collect();
    let link = Arc::new(Counted {
        disk,
        git_entries,
        bytes: Default::default(),
        git_bytes: Default::default(),
    });
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let meta = std::fs::metadata(state.path()).unwrap();
    let overlay = Arc::new(
        Overlay::open(Arc::new(manifest), state.path(), link.clone(), (meta.uid(), meta.gid()))
            .unwrap(),
    );
    let mounted = match crate::mount::mount(overlay.clone(), at.path()) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            return;
        }
    };
    let app = at.path().join("app");
    // What an agent runs first in a clone: its log, status, an old file and a diff.
    let agent = || {
        let started = std::time::Instant::now();
        sh(&app, &["log", "--oneline", "-n", "200"]);
        sh(&app, &["-c", "core.checkStat=minimal", "status", "--porcelain"]);
        sh(&app, &["show", "HEAD~100:file-3.bin"]);
        sh(&app, &["diff", "--stat", "HEAD~60", "HEAD~2"]);
        started.elapsed().as_millis()
    };
    link.take();
    let before_ms = agent();
    let (before, before_git) = link.take();
    println!(
        "57201 before the swap: git in app/ read {before_git} bytes of .git over the link \
         ({before} in all) in {before_ms} ms"
    );
    assert!(before_git > 1_000_000, "the bug: git reads the clone's packs over the link");

    let forget = |folder: u64| mounted.forget_entry(folder, ".git");
    let started = std::time::Instant::now();
    let outcome = run_nested(&overlay, &forget, at.path(), "app", state.path()).unwrap();
    let (swap, swap_git) = link.take();
    println!(
        "57201 swap: {outcome:?} in {} ms, {swap_git} bytes of .git over the link ({swap} in all)",
        started.elapsed().as_millis()
    );
    assert!(matches!(outcome, Outcome::Swapped(_)));

    let after_ms = agent();
    let (after, after_git) = link.take();
    println!(
        "57201 after the swap: git in app/ read {after_git} bytes of .git over the link \
         ({after} in all) in {after_ms} ms"
    );
    assert_eq!(after_git, 0, "fixed: nothing of .git crosses the link once it swapped");
}
