use super::*;
use crate::manifest::Item;

const T: i64 = 1_000;

fn file(path: &str, size: u64) -> Item {
    Item { path: path.into(), kind: Kind::File, mode: 0o644, size, mtime_ns: T, link: None }
}

/// `README.md`, `src/{a.rs,b.rs}`, `src/deep/d.rs`, `docs/` with two files, a link, a repository.
fn manifest() -> Manifest {
    Manifest::build(
        1,
        vec![
            file("README.md", 10),
            file("src/a.rs", 2),
            file("src/b.rs", 3),
            file("src/deep/d.rs", 4),
            file("docs/one.md", 5),
            file("docs/two.md", 6),
            file(".git/HEAD", 21),
            file(".git/index", 100),
            Item {
                path: "link".into(),
                kind: Kind::Link,
                mode: 0o777,
                size: 0,
                mtime_ns: T,
                link: Some("README.md".into()),
            },
        ],
    )
    .unwrap()
}

/// The Mac exactly as the manifest listed it.
fn mac_as_listed(manifest: &Manifest) -> BTreeMap<String, MacStat> {
    let mut out = BTreeMap::new();
    for index in 1..manifest.len() as u32 {
        let entry = manifest.entry(index).unwrap();
        out.insert(
            manifest.path_of(index),
            MacStat {
                kind: entry.kind,
                size: entry.size,
                mode: entry.mode,
                mtime_ns: entry.mtime_ns,
                link: entry.link.clone(),
            },
        );
    }
    out
}

fn up(path: &str, size: u64, mtime_ns: i64) -> Upper {
    Upper { path: path.into(), kind: Kind::File, size, mode: 0o644, mtime_ns, link: None }
}

fn dir(path: &str) -> Upper {
    Upper { path: path.into(), kind: Kind::Dir, size: 0, mode: 0o755, mtime_ns: T, link: None }
}

fn lower(path: &str) -> String {
    path.to_lowercase()
}

fn run(upper: &[Upper], whiteouts: &[&str], mac: &BTreeMap<String, MacStat>) -> Plan {
    let manifest = manifest();
    let whiteouts: Vec<String> = whiteouts.iter().map(|path| (*path).to_owned()).collect();
    plan(&manifest, upper, &whiteouts, mac, &lower)
}

fn paths<T>(items: &[T], path: impl Fn(&T) -> &str) -> Vec<&str> {
    items.iter().map(path).collect()
}

#[test]
fn an_edit_comes_back_when_the_mac_file_still_matches_the_manifest() {
    let mac = mac_as_listed(&manifest());
    let plan = run(&[dir("src"), up("src/a.rs", 9, T + 5)], &[], &mac);
    assert_eq!(
        plan.writes,
        [Write {
            path: "src/a.rs".into(),
            kind: Kind::File,
            mode: 0o644,
            link: None,
            replaces: Some(Kind::File),
        }]
    );
    assert!(plan.conflicts.is_empty() && plan.deletes.is_empty());
    // The folder copied up above it is the manifest's own.
    assert_eq!(plan.unchanged, 1);
}

#[test]
fn an_edit_over_a_mac_file_changed_since_the_manifest_is_a_conflict_written_beside() {
    let mut mac = mac_as_listed(&manifest());
    mac.get_mut("src/a.rs").unwrap().mtime_ns = T + 99;
    let plan = run(&[up("src/a.rs", 9, T + 5)], &[], &mac);
    assert!(plan.writes.is_empty());
    assert_eq!(
        plan.conflicts,
        [Conflict { path: "src/a.rs".into(), why: Why::ChangedOnMac, beside: true }]
    );
    // A size change alone counts too.
    let mut mac = mac_as_listed(&manifest());
    mac.get_mut("src/a.rs").unwrap().size = 77;
    assert_eq!(run(&[up("src/a.rs", 9, T + 5)], &[], &mac).conflicts[0].why, Why::ChangedOnMac);
}

#[test]
fn an_edit_of_a_file_the_mac_deleted_is_a_conflict() {
    let mut mac = mac_as_listed(&manifest());
    mac.remove("src/a.rs");
    let plan = run(&[up("src/a.rs", 9, T + 5)], &[], &mac);
    assert!(plan.writes.is_empty());
    assert_eq!(
        plan.conflicts,
        [Conflict { path: "src/a.rs".into(), why: Why::GoneOnMac, beside: true }]
    );
}

#[test]
fn a_new_file_comes_back_unless_the_mac_made_one_there_too() {
    let mac = mac_as_listed(&manifest());
    let new = up("src/new.rs", 3, T + 5);
    let plan = run(std::slice::from_ref(&new), &[], &mac);
    assert_eq!(paths(&plan.writes, |w| &w.path), ["src/new.rs"]);
    assert_eq!(plan.writes[0].replaces, None);

    let mut mac = mac_as_listed(&manifest());
    mac.insert(
        "src/new.rs".into(),
        MacStat { kind: Kind::File, size: 1, mode: 0o644, mtime_ns: T + 7, link: None },
    );
    let plan = run(&[new], &[], &mac);
    assert!(plan.writes.is_empty());
    assert_eq!(
        plan.conflicts,
        [Conflict { path: "src/new.rs".into(), why: Why::MadeOnBoth, beside: true }]
    );
}

#[test]
fn new_folders_are_made_before_what_they_hold_and_an_existing_one_is_left() {
    let mac = mac_as_listed(&manifest());
    let plan = run(&[up("new/deep/x", 1, T), dir("new/deep"), dir("new"), dir("docs")], &[], &mac);
    assert_eq!(paths(&plan.writes, |w| &w.path), ["new", "new/deep", "new/deep/x"]);
    assert_eq!(plan.unchanged, 1);
}

#[test]
fn a_copy_up_never_written_is_no_write_and_a_mode_change_alone_is_a_chmod() {
    let mac = mac_as_listed(&manifest());
    let copy = up("src/b.rs", 3, T);
    let plan = run(std::slice::from_ref(&copy), &[], &mac);
    assert!(plan.is_empty());
    assert_eq!(plan.unchanged, 1);

    let chmod = Upper { mode: 0o755, ..copy };
    let plan = run(std::slice::from_ref(&chmod), &[], &mac);
    assert!(plan.writes.is_empty());
    assert_eq!(plan.modes, [Chmod { path: "src/b.rs".into(), mode: 0o755 }]);

    // The Mac made it 0600 meanwhile: its mode stays, named.
    let mut mac = mac_as_listed(&manifest());
    mac.get_mut("src/b.rs").unwrap().mode = 0o600;
    let plan = run(std::slice::from_ref(&chmod), &[], &mac);
    assert!(plan.modes.is_empty());
    assert_eq!(plan.conflicts[0].why, Why::ModeOnBoth);
    assert!(!plan.conflicts[0].beside);
    // The Mac made the same change: nothing to do.
    mac.get_mut("src/b.rs").unwrap().mode = 0o755;
    assert!(run(&[chmod], &[], &mac).is_empty());
}

#[test]
fn an_edit_keeps_the_mac_mode_unless_the_machine_changed_it() {
    let mut mac = mac_as_listed(&manifest());
    mac.get_mut("src/a.rs").unwrap().mode = 0o600;
    // The Mac's mode changed (not its bytes): the edit comes back with the Mac's mode.
    let plan = run(&[up("src/a.rs", 9, T + 5)], &[], &mac);
    assert_eq!(plan.writes[0].mode, 0o600);
    let plan = run(&[Upper { mode: 0o755, ..up("src/a.rs", 9, T + 5) }], &[], &mac);
    assert_eq!(plan.writes[0].mode, 0o755);
}

#[test]
fn a_whiteout_deletes_a_file_the_mac_kept_as_listed_and_keeps_a_changed_one() {
    let mac = mac_as_listed(&manifest());
    let plan = run(&[], &["src/a.rs", "link"], &mac);
    assert_eq!(
        plan.deletes,
        [
            Delete { path: "src/a.rs".into(), kind: Kind::File },
            Delete { path: "link".into(), kind: Kind::Link },
        ]
    );

    let mut mac = mac_as_listed(&manifest());
    mac.get_mut("src/a.rs").unwrap().mtime_ns = T + 1;
    mac.get_mut("link").unwrap().link = Some("elsewhere".into());
    let plan = run(&[], &["src/a.rs", "link"], &mac);
    assert!(plan.deletes.is_empty());
    assert_eq!(
        paths(&plan.conflicts, |c| &c.path),
        ["link", "src/a.rs"],
        "both are named, neither deleted"
    );
    assert!(plan.conflicts.iter().all(|c| c.why == Why::DeletedHereChangedThere && !c.beside));

    // Already gone on the Mac: nothing to do.
    let mut mac = mac_as_listed(&manifest());
    mac.remove("src/a.rs");
    assert!(run(&[], &["src/a.rs"], &mac).is_empty());
}

#[test]
fn a_whiteout_of_a_folder_deletes_what_it_held_first_then_the_folder() {
    let mac = mac_as_listed(&manifest());
    let plan = run(&[], &["src/deep", "src/deep/d.rs"], &mac);
    assert_eq!(
        plan.deletes,
        [
            Delete { path: "src/deep/d.rs".into(), kind: Kind::File },
            Delete { path: "src/deep".into(), kind: Kind::Dir },
        ]
    );
    // A whiteout of a folder alone (an opaque folder) hides its children too.
    let plan = run(&[], &["docs"], &mac);
    assert_eq!(paths(&plan.deletes, |d| &d.path), ["docs/two.md", "docs/one.md", "docs"]);
    // A file below it the Mac changed stays, and so then does the folder (removed only empty).
    let mut mac = mac_as_listed(&manifest());
    mac.get_mut("docs/one.md").unwrap().size = 1;
    let plan = run(&[], &["docs"], &mac);
    assert_eq!(paths(&plan.deletes, |d| &d.path), ["docs/two.md", "docs"]);
    assert_eq!(paths(&plan.conflicts, |c| &c.path), ["docs/one.md"]);
}

#[test]
fn a_folder_emptied_and_refilled_on_the_machine_keeps_its_new_files() {
    let mac = mac_as_listed(&manifest());
    // rm -rf docs; mkdir docs; echo > docs/new.md: the mkdir cleared docs' own whiteout.
    let plan =
        run(&[dir("docs"), up("docs/new.md", 2, T + 5)], &["docs/one.md", "docs/two.md"], &mac);
    assert_eq!(paths(&plan.deletes, |d| &d.path), ["docs/two.md", "docs/one.md"]);
    assert_eq!(paths(&plan.writes, |w| &w.path), ["docs/new.md"]);
}

#[test]
fn a_rename_is_a_delete_plus_a_create() {
    let mac = mac_as_listed(&manifest());
    let plan = run(&[up("src/c.rs", 2, T)], &["src/a.rs"], &mac);
    assert_eq!(plan.deletes, [Delete { path: "src/a.rs".into(), kind: Kind::File }]);
    assert_eq!(paths(&plan.writes, |w| &w.path), ["src/c.rs"]);
}

#[test]
fn a_new_name_that_folds_onto_a_kept_mac_name_is_a_conflict_never_an_overwrite() {
    let mac = mac_as_listed(&manifest());
    let plan = run(&[up("Readme.md", 4, T + 5)], &[], &mac);
    assert!(plan.writes.is_empty());
    assert_eq!(
        plan.conflicts,
        [Conflict {
            path: "Readme.md".into(),
            why: Why::CaseFold { mac: "README.md".into() },
            beside: true,
        }]
    );
    // Under a folder spelled differently on the Mac too.
    let plan = run(&[up("SRC/A.rs", 4, T + 5)], &[], &mac);
    assert_eq!(plan.conflicts[0].why, Why::CaseFold { mac: "src/a.rs".into() });
    // Two new names that fold together: the second is named.
    let plan = run(&[up("new.txt", 1, T), up("NEW.txt", 1, T)], &[], &mac);
    assert_eq!(plan.writes.len(), 1);
    assert_eq!(plan.conflicts.len(), 1);
}

#[test]
fn a_case_only_rename_deletes_the_old_name_and_writes_the_new() {
    let mut mac = mac_as_listed(&manifest());
    // A Mac's disk ignores case: its stat of the new name is the old file.
    let old = mac["README.md"].clone();
    mac.insert("Readme.md".into(), old);
    let plan = run(&[up("Readme.md", 10, T)], &["README.md"], &mac);
    assert_eq!(plan.deletes, [Delete { path: "README.md".into(), kind: Kind::File }]);
    assert_eq!(paths(&plan.writes, |w| &w.path), ["Readme.md"]);
    assert!(plan.conflicts.is_empty());
}

#[test]
fn git_internals_never_come_back_as_files_and_go_to_the_git_leg() {
    let mac = mac_as_listed(&manifest());
    let plan = run(
        &[
            dir(".git"),
            up(".git/index", 120, T + 5),
            up(".git/objects/ab/cdef", 30, T + 5),
            up("src/a.rs", 9, T + 5),
        ],
        &[".git/objects/pack/old.pack", ".git/HEAD"],
        &mac,
    );
    assert_eq!(paths(&plan.writes, |w| &w.path), ["src/a.rs"]);
    assert!(plan.deletes.is_empty(), "whiteouts in .git are never deletes on the Mac");
    assert_eq!(
        plan.git,
        BTreeMap::from([(
            String::new(),
            vec![".git".into(), ".git/index".into(), ".git/objects/ab/cdef".into()]
        )])
    );
    // Any spelling of .git.
    let plan = run(&[up(".GIT/config", 1, T)], &[], &mac);
    assert!(plan.writes.is_empty());
    assert_eq!(plan.git.len(), 1);
}

#[test]
fn a_repository_made_on_the_machine_stays_there_with_its_files() {
    let mac = mac_as_listed(&manifest());
    let plan = run(
        &[
            dir("vendor"),
            dir("vendor/lib"),
            up("vendor/lib/.git/HEAD", 21, T),
            up("vendor/lib/x.c", 3, T),
            up("src/a.rs", 9, T + 5),
        ],
        &[],
        &mac,
    );
    assert_eq!(paths(&plan.writes, |w| &w.path), ["src/a.rs", "vendor"]);
    assert!(plan.git.is_empty());
    assert_eq!(paths(&plan.left_out, |(path, _)| path), ["vendor/lib"]);
}

#[test]
fn a_kind_change_replaces_the_mac_path_only_when_it_matched() {
    let mac = mac_as_listed(&manifest());
    // rm src/b.rs; mkdir src/b.rs
    let plan = run(&[dir("src/b.rs")], &[], &mac);
    assert_eq!(
        plan.writes,
        [Write {
            path: "src/b.rs".into(),
            kind: Kind::Dir,
            mode: 0o755,
            link: None,
            replaces: Some(Kind::File),
        }]
    );
    let mut mac = mac_as_listed(&manifest());
    mac.get_mut("src/b.rs").unwrap().size = 1;
    let plan = run(&[dir("src/b.rs")], &[], &mac);
    assert!(plan.writes.is_empty());
    assert_eq!(
        plan.conflicts,
        [Conflict { path: "src/b.rs".into(), why: Why::ChangedOnMac, beside: false }]
    );
}

#[test]
fn a_link_with_new_text_comes_back_and_one_with_the_same_text_does_not() {
    let mac = mac_as_listed(&manifest());
    let link = |text: &str| Upper {
        path: "link".into(),
        kind: Kind::Link,
        size: text.len() as u64,
        mode: 0o777,
        mtime_ns: T + 3,
        link: Some(text.into()),
    };
    assert!(run(&[link("README.md")], &[], &mac).is_empty());
    let plan = run(&[link("src/a.rs")], &[], &mac);
    assert_eq!(plan.writes[0].link.as_deref(), Some("src/a.rs"));
    assert_eq!(plan.writes[0].replaces, Some(Kind::Link));
}

#[test]
fn touched_names_exactly_the_paths_the_plan_reads_and_never_git_internals() {
    let manifest = manifest();
    let touched = touched(
        &manifest,
        &[up("src/a.rs", 1, T), up(".git/index", 1, T), up("new", 1, T)],
        &["docs".into(), ".git/HEAD".into(), "never-listed".into()],
    );
    assert_eq!(touched, ["docs", "docs/one.md", "docs/two.md", "new", "src/a.rs"]);
}

#[test]
fn the_plan_reads_only_touched_paths_whatever_the_folder_size() {
    // 100,000 files, 50 edited: the plan's work is the edits, its stat map just their paths.
    let items: Vec<Item> =
        (0..100_000).map(|n| file(&format!("d{}/f{n}.txt", n % 1000), 10)).collect();
    let manifest = Manifest::build(1, items).unwrap();
    let upper: Vec<Upper> =
        (0..50).map(|n| up(&format!("d{}/f{n}.txt", n % 1000), 11, T + 1)).collect();
    let touched = touched(&manifest, &upper, &[]);
    assert_eq!(touched.len(), 50);
    let mac: BTreeMap<String, MacStat> = touched
        .iter()
        .map(|path| {
            (
                path.clone(),
                MacStat { kind: Kind::File, size: 10, mode: 0o644, mtime_ns: T, link: None },
            )
        })
        .collect();
    let plan = plan(&manifest, &upper, &[], &mac, &lower);
    assert_eq!(plan.writes.len(), 50);
}
