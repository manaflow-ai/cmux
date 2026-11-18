use std::os::unix::fs::FileExt as _;

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
    std::os::unix::fs::symlink(outside.path().join("secret.txt"), root.join("absolute-out")).unwrap();
    std::os::unix::fs::symlink("../../../../../../etc/passwd", root.join("src/climbs-out")).unwrap();
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
