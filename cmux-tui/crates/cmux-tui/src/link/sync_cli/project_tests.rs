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

/// The paths, kinds, modes, sizes, times and link texts of a listing, by path.
fn shape(
    files: &[(String, Served)],
    links: &[Item],
) -> Vec<(String, u32, u64, i64, Option<String>)> {
    let mut shape: Vec<_> = files
        .iter()
        .map(|(path, served)| {
            (path.clone(), served.file.permissions, served.size, served.mtime_ns, None)
        })
        .chain(links.iter().map(|item| {
            (item.path.clone(), item.mode, item.size, item.mtime_ns, item.link.clone())
        }))
        .collect();
    shape.sort();
    shape
}

/// Outside git, the stat-only parallel walk lists exactly what the copy's own walk lists, with the
/// same stat and identity: secrets, credential and heavy folders, an outside symlink, a FIFO and a
/// `.DS_Store` stay out; an inside symlink and an unreadable file go.
#[test]
fn the_parallel_walk_lists_what_the_copy_lists() {
    use std::os::unix::fs::PermissionsExt as _;
    let folder = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(folder.path()).unwrap();
    for dir in 0..12 {
        let at = root.join(format!("pkg{dir}/src/deep"));
        std::fs::create_dir_all(&at).unwrap();
        for file in 0..9 {
            std::fs::write(at.join(format!("f{file}.rs")), vec![b'x'; file * dir]).unwrap();
        }
    }
    std::fs::write(root.join("pkg1/Cargo.toml"), "").unwrap();
    std::fs::create_dir_all(root.join("pkg1/target/debug")).unwrap();
    std::fs::write(root.join("pkg1/target/debug/out"), "o").unwrap();
    std::fs::create_dir_all(root.join("pkg2/target")).unwrap();
    std::fs::write(root.join("pkg2/target/kept"), "k").unwrap();
    std::fs::create_dir_all(root.join("web/node_modules/x")).unwrap();
    std::fs::write(root.join("web/node_modules/x/i.js"), "x").unwrap();
    std::fs::create_dir_all(root.join("home/.ssh")).unwrap();
    std::fs::write(root.join("home/.ssh/id_ed25519"), "k").unwrap();
    std::fs::write(root.join("pkg3/.env.local"), "T=1").unwrap();
    std::fs::write(root.join("pkg3/server.pem"), "p").unwrap();
    std::fs::write(root.join("pkg3/.netrc"), "n").unwrap();
    std::fs::write(root.join(".DS_Store"), "d").unwrap();
    std::fs::write(root.join("pkg4/.DS_Store"), "d").unwrap();
    std::fs::write(root.join("pkg5/run.sh"), "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(root.join("pkg5/run.sh"), std::fs::Permissions::from_mode(0o755))
        .unwrap();
    std::fs::write(root.join("pkg5/locked"), "l").unwrap();
    std::fs::set_permissions(root.join("pkg5/locked"), std::fs::Permissions::from_mode(0o000))
        .unwrap();
    std::os::unix::fs::symlink("pkg0/src", root.join("pkg6-src")).unwrap();
    std::os::unix::fs::symlink("/etc/hosts", root.join("hosts")).unwrap();
    let fifo = std::ffi::CString::new(root.join("pipe").as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: a valid C string.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o644) }, 0);

    let (copy_files, copy_links) = list_copy(&root).unwrap();
    let (walk_files, walk_links) = walk::plain(&root).unwrap();
    std::fs::set_permissions(root.join("pkg5/locked"), std::fs::Permissions::from_mode(0o644))
        .unwrap();
    let walked = shape(&walk_files, &walk_links);
    assert_eq!(walked, shape(&copy_files, &copy_links));
    let paths: Vec<&str> = walked.iter().map(|row| row.0.as_str()).collect();
    for kept in
        ["pkg0/src/deep/f0.rs", "pkg2/target/kept", "pkg5/run.sh", "pkg5/locked", "pkg6-src"]
    {
        assert!(paths.contains(&kept), "{kept} is listed");
    }
    for left in ["pkg1/target/debug/out", "web/node_modules/x/i.js", "home/.ssh/id_ed25519"] {
        assert!(!paths.contains(&left), "{left} stays here");
    }
    assert_eq!(walk_files.len(), 12 * 9 + 3);
    let ids = |files: &[(String, Served)]| {
        let mut ids: Vec<_> =
            files.iter().map(|(path, served)| (path.clone(), served.file.id)).collect();
        ids.sort();
        ids
    };
    assert_eq!(ids(&walk_files), ids(&copy_files), "the same identity a later read checks");
}

/// The Mac-side listing timed, the copy's walk against the stat-only parallel walk, on the folder
/// `CMUX_PROJECTION_BENCH_DIR` (outside git), `CMUX_PROJECTION_BENCH_RUNS` times each (3).
/// Prints one JSON line a run. `cargo test -p cmux-tui --bin cmux -- --ignored
/// projection_listing_bench --nocapture`.
#[test]
#[ignore = "a bench: needs CMUX_PROJECTION_BENCH_DIR"]
fn projection_listing_bench() {
    let Ok(dir) = std::env::var("CMUX_PROJECTION_BENCH_DIR") else { return };
    let root = std::fs::canonicalize(dir).unwrap();
    let runs: usize = std::env::var("CMUX_PROJECTION_BENCH_RUNS")
        .ok()
        .and_then(|runs| runs.parse().ok())
        .unwrap_or(3);
    for run in 0..runs {
        for how in ["copy", "walk"] {
            let started = Instant::now();
            let (files, links) =
                if how == "copy" { list_copy(&root).unwrap() } else { walk::plain(&root).unwrap() };
            let listed_ms = elapsed_ms(started);
            let mut items: Vec<Item> = files
                .iter()
                .map(|(path, served)| Item {
                    path: path.clone(),
                    kind: Kind::File,
                    mode: served.file.permissions,
                    size: served.size,
                    mtime_ns: served.mtime_ns,
                    link: None,
                })
                .collect();
            let entries = items.len() + links.len();
            items.extend(links);
            let bytes = Manifest::build(0, items).unwrap().encode().unwrap().len();
            println!(
                "{}",
                json!({"run": run, "how": how, "entries": entries, "listed_ms": listed_ms, "manifest_bytes": bytes})
            );
        }
    }
}
