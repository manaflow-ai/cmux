use std::process::Command;

use super::*;

fn paths(since: Since) -> Vec<String> {
    match since {
        Since::All => panic!("expected paths, got everything"),
        Since::Paths(paths) => paths,
    }
}

#[test]
fn the_journal_answers_what_changed_since_a_token() {
    let journal = Journal::new(7);
    journal.note("before/any/token");
    let first = journal.token();
    journal.note("repo/a.rs");
    journal.note("repo/b.rs");
    // Changed again before anyone asked: already new to every token, so it keeps its place.
    journal.note("repo/a.rs");
    let (since, second) = journal.since(&first);
    assert_eq!(paths(since), ["repo/a.rs", "repo/b.rs"]);
    assert_eq!(paths(journal.since(&second).0), Vec::<String>::new());
    // A path noted again after a query is new to that query's token.
    journal.note("repo/b.rs");
    let (since, _) = journal.since(&second);
    assert_eq!(paths(since), ["repo/b.rs"]);
    // The first token still sees every change since it.
    assert_eq!(paths(journal.since(&first).0), ["repo/a.rs", "repo/b.rs"]);
}

#[test]
fn a_token_the_journal_does_not_know_is_everything() {
    let journal = Journal::new(7);
    let other = Journal::new(8);
    let token = journal.token();
    assert_eq!(journal.since("").0, Since::All);
    assert_eq!(journal.since("watchman:c:123").0, Since::All);
    assert_eq!(journal.since(&other.token()).0, Since::All);
    assert_eq!(journal.since(&format!("{token}9")).0, Since::All);
    assert_eq!(journal.since(&token).0, Since::Paths(Vec::new()));
}

#[test]
fn past_its_cap_the_journal_forgets_and_old_tokens_are_everything() {
    let journal = Journal::new(1);
    let old = journal.token();
    for at in 0..=MAX_PATHS {
        journal.note(&format!("f{at}"));
    }
    assert_eq!(journal.since(&old).0, Since::All);
    let fresh = journal.token();
    journal.note("after");
    assert_eq!(paths(journal.since(&fresh).0), ["after"]);
}

#[test]
fn the_answer_holds_the_worktrees_paths_relative_to_it_and_never_its_git_folder() {
    let since = Since::Paths(
        ["repo/a.rs", "repo/.git/index", "repo/.git", "other/b.rs", "repo/src/", "repo"]
            .map(String::from)
            .to_vec(),
    );
    assert_eq!(answer(&since, "t", "repo"), b"t\0a.rs\0src/\0");
    assert_eq!(
        answer(&since, "t", ""),
        b"t\0repo/a.rs\0repo/.git/index\0repo/.git\0other/b.rs\0repo/src/\0repo\0"
    );
    assert_eq!(answer(&Since::All, "t", "repo"), b"t\0/\0");
}

#[test]
fn the_socket_serves_the_hook() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("fsmonitor.sock");
    let journal = std::sync::Arc::new(Journal::new(3));
    let token = journal.token();
    journal.note("mnt-repo/x.txt");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let served = journal.clone();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        serve_one(&served, &mut stream).unwrap();
    });
    let mount = Path::new("/m");
    let out = hook(&socket, mount, &mount.join("mnt-repo"), "2", &token).unwrap();
    server.join().unwrap();
    let (now, rest) = out.split_at(out.iter().position(|b| *b == 0).unwrap());
    assert!(String::from_utf8_lossy(now).starts_with("cmux-projection:"));
    assert_eq!(rest, b"\0x.txt\0");
    assert!(hook(&socket, mount, Path::new("/elsewhere"), "2", &token).is_err());
    assert!(hook(&socket, mount, mount, "1", &token).is_err());
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git").current_dir(dir).args(args).output().unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap()
}

fn have_git() -> bool {
    Command::new("git").arg("--version").output().is_ok_and(|out| out.status.success())
}

/// A repo of three committed files, with `extra` git config, its files a minute older than its
/// index (so none is racy).
fn repo(dir: &Path, init: &[&str]) {
    git(dir, &[&["init", "-q"], init].concat());
    for (name, body) in [("a.txt", "a\n"), ("b.txt", "b\n"), ("sub/c.txt", "c\n")] {
        let path = dir.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, body).unwrap();
        let past = std::time::SystemTime::now() - std::time::Duration::from_secs(60);
        std::fs::File::options().write(true).open(&path).unwrap().set_modified(past).unwrap();
    }
    git(dir, &["add", "."]);
    git(dir, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "c"]);
}

#[test]
fn a_primed_index_reads_in_git_with_the_judged_entries_clean() {
    if !have_git() {
        println!("skipping: no git");
        return;
    }
    let cases: [(&str, &[&str], Option<&str>); 4] = [
        ("v2", &[], Some("2")),
        ("v4", &[], Some("4")),
        ("sha256", &["--object-format=sha256"], None),
        ("skiphash", &[], None),
    ];
    for (name, init, version) in cases {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        repo(root, init);
        if let Some(version) = version {
            git(root, &["update-index", "--index-version", version]);
        }
        if name == "skiphash" {
            git(root, &["config", "index.skipHash", "true"]);
            git(root, &["update-index", "--force-write-index"]);
        }
        let index = std::fs::read(root.join(".git/index")).unwrap();
        let mut judged = Vec::new();
        let primed = prime(&index, "tok-1", |entry| {
            judged.push((String::from_utf8_lossy(entry.path).into_owned(), entry.size));
            entry.path != b"b.txt"
        })
        .unwrap_or_else(|| panic!("{name}: not primed"));
        assert_eq!(
            judged,
            [("a.txt".into(), 2), ("b.txt".into(), 2), ("sub/c.txt".into(), 2)],
            "{name}"
        );
        std::fs::write(root.join(".git/index"), &primed).unwrap();
        // A hook that says nothing changed: git keeps the bitmap as primed.
        let hook = root.join(".git/hook.sh");
        std::fs::write(&hook, "#!/bin/sh\nprintf 'tok-2\\0'\n").unwrap();
        std::fs::set_permissions(&hook, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        let fsmonitor = format!("core.fsmonitor={}", hook.display());
        let listed = git(root, &["-c", &fsmonitor, "ls-files", "-f"]);
        assert_eq!(listed, "h a.txt\nH b.txt\nh sub/c.txt\n", "{name}");
        // Priming again replaces the FSMN extension git wrote back.
        let again =
            prime(&std::fs::read(root.join(".git/index")).unwrap(), "tok-3", |_| true).unwrap();
        std::fs::write(root.join(".git/index"), &again).unwrap();
        assert_eq!(
            git(root, &["-c", &fsmonitor, "ls-files", "-f"]),
            "h a.txt\nh b.txt\nh sub/c.txt\n",
            "{name}"
        );
        assert_eq!(git(root, &["-c", &fsmonitor, "status", "--porcelain"]), "", "{name}");
    }
}

#[test]
fn an_index_this_cannot_rewrite_is_left_alone() {
    assert!(prime(b"", "t", |_| true).is_none());
    assert!(prime(b"DIRC\0\0\0\x05\0\0\0\0", "t", |_| true).is_none());
    if !have_git() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    repo(dir.path(), &[]);
    let mut index = std::fs::read(dir.path().join(".git/index")).unwrap();
    let last = index.len() - 1;
    index[last] ^= 1;
    assert!(prime(&index, "t", |_| true).is_none(), "a bad checksum");
}
