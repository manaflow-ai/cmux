use cmux_process::Command;
use std::path::Path;

use super::{
    LocalFile, LocalSet, Rules, Skips, below, borrowed_object, borrowed_skipped, collect, entry_in,
    git_text, open_listed, place, unquote, walk_plain,
};

fn write(top: &Path, relative: &str) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, "x\n").unwrap();
}

/// A file is read only as the file listed: once a folder above it is swapped for a symlink that
/// leads out of the folder copied, the same path names another file, and the read refuses it.
#[test]
fn a_read_refuses_a_file_found_through_a_folder_swapped_since_it_was_listed() {
    let root = tempfile::tempdir().unwrap();
    let (top, outside) = (root.path().join("top"), root.path().join("outside"));
    write(&top, "sub/notes.txt");
    write(&outside, "notes.txt");
    let path = top.join("sub/notes.txt");
    let listed = LocalFile::listed(&path, &std::fs::symlink_metadata(&path).unwrap());
    assert!(open_listed(&path, listed.id).is_ok());
    std::fs::rename(top.join("sub"), top.join("sub-old")).unwrap();
    std::os::unix::fs::symlink(&outside, top.join("sub")).unwrap();
    assert!(open_listed(&path, listed.id).is_err());
    assert!(open_listed(&path, None).is_ok(), "no listing: only the last name is checked");
}

/// A chat's copy of a plain folder never takes a credential folder's or
/// file's contents at any depth (gh's `hosts.yml` OAuth tokens, Cargo's
/// `credentials.toml`, cloud and cluster logins, `.netrc`-style files),
/// by the same folder list the App refuses a selected folder by; the
/// project's own files beside them go.
#[test]
fn a_plain_copy_leaves_credential_folders_and_files_here() {
    let top = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(top.path()).unwrap();
    let secrets = [
        ".config/gh/hosts.yml",
        "home/.config/gh/hosts.yml",
        ".config/gcloud/credentials.db",
        ".config/hub",
        ".cargo/credentials.toml",
        ".cargo/credentials",
        ".aws/credentials",
        ".ssh/config",
        ".gnupg/pubring.kbx",
        ".docker/config.json",
        ".kube/config",
        ".azure/accessTokens.json",
        ".netrc",
        "deep/.npmrc",
        ".pypirc",
        ".git-credentials",
        ".gem/credentials",
        ".terraform.d/credentials.tfrc.json",
        ".secrets/token",
        "deep/.docker/daemon.json",
        ".docker/buildx/instances/x",
        "app/Library/Keychains/login.keychain-db",
        "deep/.config/gcloud/application_default_credentials.json",
        ".cargo/config.toml",
    ];
    for relative in secrets {
        write(&top, relative);
    }
    let kept = ["src/main.rs", ".config/app.toml", "gh/notes.md", "Library/notes.md"];
    for relative in kept {
        write(&top, relative);
    }
    let set = collect(&top, Rules::Copy, None).unwrap();
    for relative in secrets {
        assert!(!set.files.contains_key(relative), "{relative} went: {:?}", set.files.keys());
    }
    for relative in kept {
        assert!(set.files.contains_key(relative), "{relative} stayed: {:?}", set.files.keys());
    }
}

/// A folder swapped for a symlink after its parent was listed is never
/// walked through: the walk opens each folder by name, relative to its
/// parent, without following a symlink, so it lists nothing outside the
/// selected folder (the race between the listing and the descent).
#[test]
fn a_folder_swapped_for_a_symlink_is_never_walked_through() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let (top, outside) = (root.join("top"), root.join("outside"));
    write(&outside, "secret.txt");
    write(&top, "a/kept.txt");
    std::os::unix::fs::symlink(&outside, top.join("swapped")).unwrap();
    std::os::unix::fs::symlink(&outside, top.join("a/swapped")).unwrap();
    for dir in [top.join("swapped"), top.join("a/swapped")] {
        let mut set = LocalSet {
            files: Default::default(),
            links: Default::default(),
            skipped: 0,
            skips: Skips::new(&top),
            git: false,
            cap: None,
        };
        // As the walk descends into a name it listed as a folder.
        let _ = walk_plain(&mut set, Rules::Copy, &|_| true, &top, &dir);
        assert!(
            set.files.keys().all(|relative| !relative.ends_with("secret.txt")),
            "walked outside through {}: {:?}",
            dir.display(),
            set.files.keys()
        );
    }
}

/// An entry of a folder the walk holds open is read through that folder's descriptor, never its
/// path: with the folder swapped for a symlink to elsewhere after it was opened, its symlink
/// entry never becomes the regular file found at the same name outside.
#[test]
fn an_entry_of_an_open_folder_swapped_away_is_read_through_its_descriptor() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let (top, outside) = (root.join("top"), root.join("outside"));
    write(&top, "a/kept.txt");
    write(&outside, "link");
    std::os::unix::fs::symlink("kept.txt", top.join("a/link")).unwrap();
    let handle = place::Dir::open(&top.join("a")).unwrap();
    std::fs::rename(top.join("a"), top.join("a-old")).unwrap();
    std::os::unix::fs::symlink(&outside, top.join("a")).unwrap();
    let mut set = LocalSet {
        files: Default::default(),
        links: Default::default(),
        skipped: 0,
        skips: Skips::new(&top),
        git: false,
        cap: None,
    };
    let path = top.join("a/link");
    entry_in(&mut set, Rules::Copy, "a/link", &path, &handle, "link", place::Entry::Link).unwrap();
    assert!(set.files.is_empty(), "took a file from outside: {:?}", set.files.keys());
}

/// Only a plain path below the folder is one of its files: a crafted
/// git index naming a root, `..` or an empty part names none.
#[test]
fn only_a_plain_path_is_below_the_folder() {
    for kept in ["a.txt", "docs/guide.md", "a/.b/c"] {
        assert!(below(kept), "{kept}");
    }
    for refused in ["", "/etc/passwd", "../x", "a/../../x", "a//b", "./a", "a/."] {
        assert!(!below(refused), "{refused}");
    }
}

#[test]
fn only_git_object_files_of_a_borrowed_store_go() {
    let loose = format!("ab/{}", "c".repeat(38));
    let loose_sha256 = format!("ab/{}", "c".repeat(62));
    for goes in [
        loose.as_str(),
        loose_sha256.as_str(),
        "pack/pack-0123abcd.pack",
        "pack/pack-0123abcd.idx",
        "pack/pack-0123abcd.rev",
        "pack/pack-0123abcd.promisor",
        "pack/pack-0123abcd.bitmap",
        "pack/pack-0123abcd.mtimes",
        "pack/pack-0123abcd.keep",
        "info/commit-graph",
        "info/commit-graphs/commit-graph-chain",
        "info/commit-graphs/graph-0123abcd.graph",
    ] {
        assert!(borrowed_object(goes), "{goes}");
    }
    for stays in [
        ".env",
        "ab/.env",
        "ab/cdef",
        "AB/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
        "zz/cccccccccccccccccccccccccccccccccccccc",
        "pack/.env",
        "pack/pack-0123abcd.pack.lock",
        "pack/pack-.pack",
        "pack/notes.txt",
        "info/exclude",
        "info/commit-graphs/secret.txt",
        "deep/er/file",
    ] {
        assert!(!borrowed_object(stays), "{stays}");
    }
}

fn git(dir: &Path, args: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

/// A symlinked git config (`config -> config.actual`) goes as the file it
/// names, read through the git folder's descriptor, never as an empty one.
#[test]
fn a_symlinked_git_config_goes_as_the_file_it_names() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let repo = root.join("repo");
    std::fs::create_dir(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["config", "remote.origin.url", "https://example.invalid/r.git"]);
    std::fs::write(repo.join("a.txt"), "a\n").unwrap();
    let (config, real) = (repo.join(".git/config"), root.join("dotfiles-config"));
    std::fs::rename(&config, &real).unwrap();
    let config_text =
        |repo: &Path| match collect(repo, Rules::Copy, None).unwrap().files.remove(".git/config") {
            Some(LocalFile { source: super::Source::Bytes(bytes), .. }) => {
                String::from_utf8(bytes).unwrap()
            }
            other => panic!("no config: {other:?}"),
        };
    // A sibling, a chain through a sibling, and a file outside the folder.
    for (link, to) in
        [("config.actual", "../../dotfiles-config"), ("config.middle", "config.actual")]
    {
        std::os::unix::fs::symlink(to, repo.join(".git").join(link)).unwrap();
    }
    for to in ["config.actual", "config.middle", real.to_str().unwrap()] {
        let _ = std::fs::remove_file(&config);
        std::os::unix::fs::symlink(to, &config).unwrap();
        let text = config_text(&repo);
        assert!(
            text.contains("repositoryformatversion") && text.contains("example.invalid"),
            "{to}: {text}"
        );
    }
    // Unreadable fails the sync, never an empty config in its place
    // (git itself refuses such a folder, so read it directly); gone, it
    // stays out.
    let git_dir = place::Dir::open(&repo.join(".git")).unwrap();
    let read = |path: &Path| git_text(&git_dir, "config", &place::Entry::Link, path);
    std::fs::remove_file(&real).unwrap();
    assert!(read(&config).unwrap().is_none());
    std::fs::create_dir(&real).unwrap();
    assert!(read(&config).is_err());
}

/// A stray file in a borrowed object folder (a `.env`, a note) never
/// goes; its loose objects and packs do.
#[test]
fn a_stray_file_in_a_borrowed_store_stays_here() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let base = root.join("base");
    std::fs::create_dir(&base).unwrap();
    git(&base, &["init", "-q"]);
    std::fs::write(base.join("a.txt"), "a\n").unwrap();
    git(&base, &["add", "a.txt"]);
    git(&base, &["commit", "-q", "-m", "packed"]);
    git(&base, &["repack", "-q", "-a", "-d"]);
    std::fs::write(base.join("b.txt"), "b\n").unwrap();
    git(&base, &["add", "b.txt"]);
    git(&base, &["commit", "-q", "-m", "loose"]);
    let objects = base.join(".git/objects");
    std::fs::write(objects.join(".env"), "TOKEN=x\n").unwrap();
    std::fs::write(objects.join("pack/notes.txt"), "x\n").unwrap();
    std::fs::create_dir(objects.join("stray")).unwrap();
    std::fs::write(objects.join("stray/id_rsa"), "x\n").unwrap();
    git(&root, &["clone", "-q", "--shared", "base", "copy"]);
    let copy = root.join("copy");

    let set = collect(&copy, Rules::Copy, None).unwrap();
    let borrowed: Vec<&str> =
        set.files.keys().filter_map(|path| path.strip_prefix(".git/objects/")).collect();
    assert!(
        borrowed.iter().any(|path| path.starts_with("pack/pack-") && path.ends_with(".pack")),
        "no pack went: {borrowed:?}"
    );
    assert!(
        borrowed.iter().any(|path| path.len() == 41 && path.as_bytes()[2] == b'/'),
        "no loose object went: {borrowed:?}"
    );
    for stray in [".env", "pack/notes.txt", "stray/id_rsa", "info/alternates"] {
        assert!(!borrowed.contains(&stray), "{stray} went: {borrowed:?}");
    }
    assert!(set.skipped >= 3, "the stray files were not counted: {}", set.skipped);
}

#[test]
fn an_alternates_line_is_a_path_plain_or_c_quoted() {
    assert_eq!(unquote(b"/a/b/objects"), b"/a/b/objects");
    assert_eq!(unquote(br#""/a b/\"q\"/\\/x\tz/\303\251""#), b"/a b/\"q\"/\\/x\tz/\xc3\xa9");
    assert_eq!(unquote(b"\"unterminated"), b"\"unterminated");
}

#[test]
fn a_borrowed_store_keeps_its_own_alternates_and_indexes() {
    for kept_here in [
        "info/alternates",
        "info/commit-graphs/commit-graph-chain",
        "pack/multi-pack-index",
        "pack/tmp_pack_x",
        "pack/pack-1.idx.lock",
    ] {
        assert!(borrowed_skipped(kept_here), "{kept_here}");
    }
    for goes in ["pack/pack-1.pack", "pack/pack-1.idx", "pack/pack-1.promisor", "ab/cdef"] {
        assert!(!borrowed_skipped(goes), "{goes}");
    }
}
