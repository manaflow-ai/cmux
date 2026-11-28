//! Issue 57201 through a real mount: a projected folder of clones (itself no repository) swaps a
//! nested clone's `.git` to its own machine repository ([`run_nested`]), git there reads the same
//! repository as on the Mac with the unpushed commits local, and Bring Back's listing and mark see
//! a commit made on the machine.

use super::*;
use crate::layer::Layer;

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
