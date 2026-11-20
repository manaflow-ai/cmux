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
    // An edit since is answered as the file is now (RFD 0007 hard case 7): what it is, then its
    // bytes. A whole file that grew past its listed size sends only what it is.
    std::fs::write(root.join("src/main.rs"), "fn main() { edited(); }\n").unwrap();
    let grown = Source::whole(&listed, main);
    let (now, bytes) = grown.changed_to().expect("the edit is answered as the file is now");
    assert_eq!((now.size, now.mode, bytes), (24, 0o644, b"".as_slice()));
    let part = Source::read(&listed, main, 3, 4);
    assert_eq!(part.changed_to().map(|(_, bytes)| bytes.to_vec()), Some(b"main".to_vec()));
    // An editor's save puts a new file in its place: found again under the folder.
    std::fs::write(root.join("src/main.rs.tmp"), "fn x() {}\n").unwrap();
    std::fs::rename(root.join("src/main.rs.tmp"), root.join("src/main.rs")).unwrap();
    let saved = Source::whole(&listed, main);
    let (now, bytes) = saved.changed_to().expect("the replaced file is answered as it is now");
    assert_eq!((now.size, bytes), (10, b"fn x() {}\n".as_slice()));
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
