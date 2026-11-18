use std::os::unix::fs::FileExt as _;

use super::local::Rules;
use super::*;

#[test]
fn the_manifest_holds_what_a_copy_sends_and_never_a_secret() {
    let folder = tempfile::tempdir().unwrap();
    let root = folder.path();
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
    std::fs::write(root.join("README.md"), "# hi\n").unwrap();
    std::fs::write(root.join(".env"), "TOKEN=secret\n").unwrap();
    std::fs::create_dir_all(root.join("node_modules/x")).unwrap();
    std::fs::write(root.join("node_modules/x/index.js"), "x\n").unwrap();

    let listed = list(&std::fs::canonicalize(root).unwrap()).unwrap();
    let manifest = &listed.manifest;
    let main = manifest.resolve("src/main.rs").expect("src/main.rs is in the manifest");
    assert_eq!(manifest.entry(main).unwrap().size, 13);
    assert!(manifest.resolve("README.md").is_some());
    assert_eq!(manifest.resolve(".env"), None, "a secret never reaches the manifest");
    assert_eq!(manifest.resolve("node_modules"), None, "a heavy folder stays here");

    // Reads are answered from the file the manifest named; an edit since is `changed`.
    assert_eq!(Source::whole(&listed, main), Part::ok(b"fn main() {}\n".to_vec()));
    assert_eq!(Source::read(&listed, main, 3, 4), Part::ok(b"main".to_vec()));
    std::fs::write(root.join("src/main.rs"), "fn main() { edited(); }\n").unwrap();
    assert_eq!(Source::whole(&listed, main).status, wire::CHANGED);
    // Anything that is not a file of the manifest is refused.
    assert_eq!(Source::whole(&listed, 0).status, wire::REFUSED);
    assert_eq!(Source::whole(&listed, 9999).status, wire::REFUSED);
}

#[test]
fn each_chat_folder_has_its_own_projection_name() {
    assert_eq!(name_of("/home/cmux/work/a"), name_of("/home/cmux/work/a"));
    assert_ne!(name_of("/home/cmux/work/a"), name_of("/home/cmux/work/b"));
    assert!(name_of("/x").bytes().all(|byte| byte.is_ascii_alphanumeric()));
}

#[test]
fn each_chat_has_its_own_projection_and_its_name_is_one_the_machine_takes() {
    let one = chat_name("0c6f2c1e-6a4e-4d8e-9a59-1f7d3c2b9e10");
    let two = chat_name("5b0a9d7e-2f43-4c1b-8e6d-3a9c7f1e2d40");
    assert_ne!(one, two);
    assert_eq!(one, chat_name("0c6f2c1e-6a4e-4d8e-9a59-1f7d3c2b9e10"));
    // The daemon's rule (cmux-tui-core projection.rs): 1-64 letters, digits, - or _.
    assert!(one.len() <= 64);
    assert!(one.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte)));
}

#[test]
fn links_inside_the_folder_are_in_the_manifest_and_ones_that_leave_it_or_dangle_are_not() {
    let folder = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(folder.path()).unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("secret.txt"), "not shared\n").unwrap();
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
    std::os::unix::fs::symlink("src/main.rs", root.join("main-link.rs")).unwrap();
    std::os::unix::fs::symlink("src", root.join("current")).unwrap();
    std::os::unix::fs::symlink(outside.path().join("secret.txt"), root.join("absolute-out"))
        .unwrap();
    std::os::unix::fs::symlink("../../../../../../etc/passwd", root.join("src/climbs-out"))
        .unwrap();
    std::os::unix::fs::symlink("not-there.txt", root.join("dangling")).unwrap();

    let listed = list(&root).unwrap();
    let manifest = &listed.manifest;
    let link = manifest.resolve("main-link.rs").expect("an in-tree link is in the manifest");
    let entry = manifest.entry(link).unwrap();
    assert_eq!(entry.kind, Kind::Link);
    assert_eq!(entry.link.as_deref(), Some("src/main.rs"));
    assert_eq!(manifest.entry(manifest.resolve("current").unwrap()).unwrap().kind, Kind::Link);
    for refused in ["absolute-out", "src/climbs-out", "dangling"] {
        assert_eq!(manifest.resolve(refused), None, "{refused} stays on this Mac");
    }
    // A link is never read for bytes.
    assert_eq!(Source::whole(&listed, link).status, wire::REFUSED);
}

#[test]
fn a_file_past_4_gib_is_served_by_range_and_never_whole() {
    let folder = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(folder.path()).unwrap();
    let size: u64 = 5 * 1024 * 1024 * 1024 + 7;
    let image = std::fs::File::create(root.join("disk.img")).unwrap();
    image.set_len(size).unwrap();
    let at: u64 = 4 * 1024 * 1024 * 1024 + 4096 * 3 + 1;
    image.write_all_at(b"past four gib", at).unwrap();
    drop(image);

    let listed = list(&root).unwrap();
    let entry = listed.manifest.resolve("disk.img").expect("a 5 GiB file is in the manifest");
    assert_eq!(listed.manifest.entry(entry).unwrap().size, size);
    assert_eq!(Source::read(&listed, entry, at, 13), Part::ok(b"past four gib".to_vec()));
    assert_eq!(Source::read(&listed, entry, size - 2, 64), Part::ok(vec![0, 0]));
    assert_eq!(Source::whole(&listed, entry).status, wire::FAILED, "only small files go whole");
}

fn git_here(dir: &Path, args: &[&str]) {
    let status = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

/// RFD 0007 hard case 7: git on the Mac rewrites the repository's index (a new file renamed over
/// the old one) after the manifest; a read is told it changed, and once the machine lists it again
/// the new bytes are served.
#[test]
fn an_index_git_rewrites_here_is_listed_again_and_served_new() {
    let folder = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(folder.path()).unwrap();
    std::fs::write(root.join("a.rs"), "fn a() {}\n").unwrap();
    git_here(&root, &["init", "-q"]);
    git_here(&root, &["add", "a.rs"]);
    git_here(&root, &["commit", "-qm", "one"]);
    let listed = list(&root).unwrap();
    let index = listed.manifest.resolve(".git/index").expect("the index is in the manifest");
    let before = std::fs::read(root.join(".git/index")).unwrap();
    assert_eq!(Source::whole(&listed, index), Part::ok(before.clone()));

    // git writes index.lock and renames it over the index: another file, another size.
    std::fs::write(root.join("b.rs"), "fn b() {}\n").unwrap();
    git_here(&root, &["add", "b.rs"]);
    let after = std::fs::read(root.join(".git/index")).unwrap();
    assert_ne!(after, before);
    assert_eq!(Source::whole(&listed, index).status, wire::CHANGED);

    let relisted = Source::relist(&listed, index);
    assert_eq!(relisted.status, wire::OK);
    let (size, _) = wire::stat_of(&relisted.bytes).unwrap();
    assert_eq!(size, after.len() as u64);
    assert_eq!(Source::whole(&listed, index), Part::ok(after));
    assert_eq!(Source::read(&listed, index, 0, 4), Part::ok(b"DIRC".to_vec()));
    // A file gone since cannot be listed again; one made here (a cleaned config) never changes.
    let a = listed.manifest.resolve("a.rs").unwrap();
    std::fs::remove_file(root.join("a.rs")).unwrap();
    assert_eq!(Source::relist(&listed, a).status, wire::FAILED);
    let config = listed.manifest.resolve(".git/config").unwrap();
    assert_eq!(Source::relist(&listed, config).status, wire::FAILED);
}

/// The listing a manifest is made from opens no file: its sizes and times come from the one stat
/// that found each file, on several threads, and match what the copy's own listing finds.
#[test]
fn the_parallel_stat_only_listing_matches_the_copys() {
    let folder = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(folder.path()).unwrap();
    for index in 0..600 {
        let path = root.join(format!("d{}/e{}/f{index}.txt", index % 7, index % 13));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "x".repeat(index)).unwrap();
    }
    std::fs::create_dir_all(root.join("node_modules/y")).unwrap();
    std::fs::write(root.join("node_modules/y/i.js"), "y").unwrap();
    std::fs::write(root.join("d0/.env"), "TOKEN=1").unwrap();
    // A repository inside, its history included.
    let repo = root.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    std::fs::write(repo.join("r.rs"), "fn r() {}\n").unwrap();
    git_here(&repo, &["init", "-q"]);
    git_here(&repo, &["add", "."]);
    git_here(&repo, &["commit", "-qm", "r"]);

    let copy = local::listed(&root, Rules::Copy, None).unwrap().0;
    let projected = local::listed_stats(&root).unwrap();
    assert_eq!(
        projected.files.keys().collect::<Vec<_>>(),
        copy.files.keys().collect::<Vec<_>>(),
        "the same files as the copy lists"
    );
    assert_eq!(projected.links.len(), copy.links.len());
    let stats = projected.stats.unwrap();
    for (relative, file) in &copy.files {
        if let local::Source::File(path) = &file.source {
            let meta = std::fs::symlink_metadata(path).unwrap();
            assert_eq!(stats.get(relative), Some(&(meta.len(), mtime_ns(&meta))), "{relative}");
        }
    }
    assert!(stats.contains_key("d4/e1/f599.txt"));

    // In a git repository the same, by git's own listing.
    let copy = local::listed(&repo, Rules::Copy, None).unwrap().0;
    let projected = local::listed_stats(&repo).unwrap();
    assert_eq!(projected.files.keys().collect::<Vec<_>>(), copy.files.keys().collect::<Vec<_>>());
    assert!(projected.files.contains_key(".git/HEAD"));
}

/// How long listing a big folder for its manifest takes: the copy's listing, which opens every
/// file, then a stat of each again (before), against the parallel stat-only listing (after).
#[test]
#[ignore = "a bench: CMUX_LIST_BENCH_FILES=300000 cargo test --release -p cmux-tui --lib a_bench_of_listing -- --ignored --nocapture"]
fn a_bench_of_listing_a_folder_for_its_manifest() {
    let files: usize =
        std::env::var("CMUX_LIST_BENCH_FILES").ok().and_then(|n| n.parse().ok()).unwrap_or(300_000);
    let folder = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(folder.path()).unwrap();
    for index in 0..files {
        let path =
            root.join(format!("p{:03}/d{:03}/f{index:07}.rs", index / 10_000, (index / 100) % 100));
        if index % 100 == 0 {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        }
        std::fs::write(&path, b"x").unwrap();
    }
    let started = Instant::now();
    let copy = local::listed(&root, Rules::Copy, None).unwrap().0;
    let stated: usize = copy.files.values().filter(|file| stat(file).is_some()).count();
    let before = started.elapsed();
    let started = Instant::now();
    let projected = list(&root).unwrap();
    let after = started.elapsed();
    assert_eq!(stated, files);
    assert_eq!(projected.manifest.totals().0, files as u64);
    println!("| manifest listing, {files} files | time |\n|---|---|");
    println!(
        "| copy's listing (opens each) + a stat each, one thread (before) | {} ms |",
        before.as_millis()
    );
    println!("| stat-only, {} threads (after) | {} ms |", local_threads(), after.as_millis());
}

fn local_threads() -> usize {
    std::thread::available_parallelism().map_or(4, std::num::NonZero::get).clamp(2, 16)
}
