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
fn each_move_has_its_own_projection_and_its_name_is_one_the_machine_takes() {
    let one = chat_name(&move_key("/home/cmux/work/api"));
    std::thread::sleep(Duration::from_millis(1));
    // A later move of the same folder never mounts an earlier move's edits.
    assert_ne!(one, chat_name(&move_key("/home/cmux/work/api")));
    assert!(one.starts_with(&chat_name(&format!("move-{}", name_of("/home/cmux/work/api")))));
    // The daemon's rule (cmux-tui-core projection.rs): 1-64 letters, digits, - or _.
    assert!(one.len() <= 64);
    assert!(one.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte)));
}

#[test]
fn what_a_server_serves_reads_back_as_written() {
    let served = ServerRecord {
        machine: "m-7f3a".into(),
        chat: "move-p0123456789abcdef-1".into(),
        local: PathBuf::from("/Users/leo/Projects/with\nnewline"),
    };
    assert_eq!(ServerRecord::decode(&served.encode()), Some(served.clone()));
    assert_eq!(ServerRecord::decode(b"no separator"), None);
    assert_eq!(ServerRecord::decode(b"m\0\0/no/chat"), None);
    // A machine that answers no id is recorded as none, and matches only itself.
    let unnamed = ServerRecord { machine: String::new(), ..served };
    assert_eq!(ServerRecord::decode(&unnamed.encode()), Some(unnamed));
}

fn git_in(dir: &Path, args: &[&str]) {
    let status = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

/// RFD 0007, "Tracked files the skip rules keep home": in a folder of repositories, a secret a
/// repository tracks is listed with its real stat and why, and its bytes are refused; an untracked
/// secret is still not listed at all.
#[test]
fn a_tracked_secret_below_a_folder_of_repos_is_listed_with_its_stat_and_never_served() {
    let folder = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(folder.path()).unwrap();
    let repo = root.join("kubernetes");
    std::fs::create_dir_all(repo.join("test/fixtures")).unwrap();
    std::fs::create_dir_all(repo.join("web/node_modules/x")).unwrap();
    std::fs::write(repo.join("web/package.json"), "{}\n").unwrap();
    std::fs::write(repo.join("main.go"), "package main\n").unwrap();
    std::fs::write(repo.join("test/fixtures/server.key"), "PRIVATE KEY BYTES\n").unwrap();
    std::fs::write(repo.join("web/node_modules/x/index.js"), "x\n").unwrap();
    git_in(&repo, &["init", "-q"]);
    git_in(&repo, &["add", "-f", "."]);
    git_in(&repo, &["commit", "-qm", "init"]);
    std::fs::write(repo.join("untracked.pem"), "OTHER KEY\n").unwrap();

    let listed = list(&root).unwrap();
    let manifest = &listed.manifest;
    let key = manifest.resolve("kubernetes/test/fixtures/server.key").expect("the key is listed");
    let meta = std::fs::metadata(repo.join("test/fixtures/server.key")).unwrap();
    let entry = manifest.entry(key).unwrap();
    assert_eq!(entry.size, meta.len());
    assert_eq!(entry.mtime_ns, mtime_ns(&meta));
    assert_eq!(entry.mode, 0o644);
    assert_eq!(manifest.kept(key), Some("secret: key files are shared only on purpose"));
    let heavy = manifest.resolve("kubernetes/web/node_modules/x/index.js").unwrap();
    assert_eq!(manifest.kept(heavy), Some("a heavy folder rebuilt on the machine"));
    assert_eq!(manifest.kept_count(), 2);
    assert_eq!(manifest.resolve("kubernetes/untracked.pem"), None);
    let main = manifest.resolve("kubernetes/main.go").unwrap();
    assert_eq!(manifest.kept(main), None);

    // No byte of it is served, whole or by range.
    assert_eq!(Source::whole(&listed, key), Part::status(wire::REFUSED));
    assert_eq!(Source::read(&listed, key, 0, 4096), Part::status(wire::REFUSED));
    assert_eq!(Source::whole(&listed, main), Part::ok(b"package main\n".to_vec()));
    // And the wire carries the mark.
    let decoded = Manifest::decode(&manifest.encode().unwrap()).unwrap();
    assert_eq!(decoded.kept(key), manifest.kept(key));
}

/// A repository folder itself lists every tracked file with its bytes (tracked secrets were
/// committed on purpose): nothing is kept.
#[test]
fn a_repository_folder_keeps_nothing_home() {
    let folder = tempfile::tempdir().unwrap();
    let repo = std::fs::canonicalize(folder.path()).unwrap();
    std::fs::write(repo.join("server.key"), "TEST KEY\n").unwrap();
    git_in(&repo, &["init", "-q"]);
    git_in(&repo, &["add", "-f", "."]);
    git_in(&repo, &["commit", "-qm", "init"]);
    let listed = list(&repo).unwrap();
    let key = listed.manifest.resolve("server.key").unwrap();
    assert_eq!(listed.manifest.kept(key), None);
    assert_eq!(listed.manifest.kept_count(), 0);
}
