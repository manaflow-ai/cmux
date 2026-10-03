//! `git.commit` edges: lost replies and timeouts, the op-wide deadline,
//! sessions without durable state, path forms and the journal's bounds.

use std::fs;
use std::os::unix::fs::symlink;
use std::time::{Duration, Instant, SystemTime};

use serde_json::json;

use super::super::commit::seams::LOSE_REPLY;
use super::super::journal::{MAX_AGE, MAX_ENTRIES, prune};
use super::super::user_run::seams::DEADLINE;
use super::{
    alive, commit, commit_all, committed_files, error_code, executable, git, ok, refused,
    repository, session, temporary, write,
};
use crate::{Mux, SurfaceOptions};

#[test]
fn a_timed_out_attempt_never_claims_a_terminal_commit_and_leaves_no_lock() {
    let repository = repository("timeout");
    write(&repository, "a.txt", "a\n");
    let base = commit_all(&repository, "base");
    let pid_file = repository.join(".git/sleep.pid");
    let hook = format!("#!/bin/sh\nsleep 30 &\necho $! > '{}'\nwait\n", pid_file.display());
    executable(&repository.join(".git/hooks/pre-commit"), &hook);
    write(&repository, "a.txt", "a2\n");
    let mux = session("timeout");
    let fields = json!({"message": "Same message", "all": true, "expected_head": base});
    DEADLINE.with(|deadline| deadline.set(Some(Duration::from_secs(1))));
    let started = Instant::now();
    let (reason, extra) = refused(&commit(&mux, &repository, fields.clone(), "k-timeout"));
    DEADLINE.with(|deadline| deadline.set(None));
    assert_eq!(reason, "timed_out", "{extra}");
    assert!(started.elapsed() < Duration::from_secs(20), "{:?}", started.elapsed());
    assert!(!repository.join(".git/index.lock").exists(), "git left its index lock");
    let pid: i32 = fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    let gone = Instant::now() + Duration::from_secs(5);
    while alive(pid) && Instant::now() < gone {
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(!alive(pid), "the hook's child outlived the deadline");
    assert_eq!(git(&repository, &["rev-parse", "HEAD"]), base);

    // The same subject on the same parent, made in a terminal.
    fs::remove_file(repository.join(".git/hooks/pre-commit")).unwrap();
    commit_all(&repository, "Same message");
    assert_eq!(refused(&commit(&mux, &repository, fields, "k-timeout")).0, "head_moved");
}

#[test]
fn a_lost_reply_is_recovered_once_when_a_hook_rewrites_the_subject() {
    let repository = repository("rewrite");
    write(&repository, "a.txt", "a\n");
    let base = commit_all(&repository, "base");
    let hook = "#!/bin/sh\nprintf '[TICKET-1] %s\\n' \"$(cat \"$1\")\" > \"$1.new\" && mv \"$1.new\" \"$1\"\n";
    executable(&repository.join(".git/hooks/commit-msg"), hook);
    write(&repository, "a.txt", "a2\n");
    git(&repository, &["add", "a.txt"]);
    let mux = session("rewrite");
    let fields = json!({"message": "Fix it"});
    LOSE_REPLY.with(|lose| lose.set(true));
    assert_eq!(refused(&commit(&mux, &repository, fields.clone(), "k-rewrite")).0, "store_failed");
    let made = git(&repository, &["rev-parse", "HEAD"]);
    assert_eq!(git(&repository, &["log", "-1", "--format=%s"]), "[TICKET-1] Fix it");
    let retry = ok(&commit(&mux, &repository, fields.clone(), "k-rewrite"));
    assert_eq!(
        (retry["replayed"].as_bool(), retry["value"]["commit"].as_str()),
        (Some(true), Some(made.as_str()))
    );
    assert_eq!(git(&repository, &["rev-parse", "HEAD^"]), base);
}

#[test]
fn a_session_without_state_still_recovers_a_lost_reply() {
    let repository = repository("memory");
    write(&repository, "a.txt", "a\n");
    let base = commit_all(&repository, "base");
    write(&repository, "a.txt", "a2\n");
    git(&repository, &["add", "a.txt"]);
    let mux = Mux::new_for_test("gitw-memory", SurfaceOptions::default());
    let fields = json!({"message": "In memory", "expected_head": base});
    LOSE_REPLY.with(|lose| lose.set(true));
    assert_eq!(refused(&commit(&mux, &repository, fields.clone(), "k-memory")).0, "store_failed");
    let made = git(&repository, &["rev-parse", "HEAD"]);
    let retry = ok(&commit(&mux, &repository, fields, "k-memory"));
    assert_eq!(retry["value"]["commit"], made.as_str());
    assert_eq!(git(&repository, &["rev-parse", "HEAD^"]), base);
}

#[test]
fn paths_may_be_absolute_inside_the_root_and_hostile_ones_are_refused() {
    let repository = repository("abs");
    write(&repository, "sub/a.txt", "a\n");
    commit_all(&repository, "base");
    write(&repository, "sub/a.txt", "a2\n");
    write(&repository, "sub/-x", "dash\n");
    write(&repository, "star*.txt", "star\n");
    write(&repository, "starry.txt", "never globbed\n");
    let mux = session("abs");
    let sub = repository.join("sub");
    let paths = [sub.join("a.txt"), sub.join("-x"), repository.join("star*.txt")]
        .map(|path| path.to_string_lossy().into_owned());
    // The target is the subdirectory, as a CLI run there sends it.
    let envelope = super::call(
        &mux,
        "git.commit",
        &sub,
        json!({"message": "Absolute", "paths": paths}),
        "k-abs",
    );
    ok(&envelope);
    assert_eq!(committed_files(&repository, "HEAD"), ["star*.txt", "sub/-x", "sub/a.txt"]);
    let outside = temporary("abs-outside").join("f.txt").to_string_lossy().into_owned();
    for path in [outside.as_str(), "a/../b", ".git/config", ".GIT/config", "sub/./a.txt"] {
        let fields = json!({"message": "m", "paths": [path]});
        assert_eq!(
            error_code(&commit(&mux, &repository, fields, "k-hostile")),
            "validation.invalid",
            "{path}"
        );
    }
    let glob = json!({"message": "m", "paths": [":(glob)*"]});
    assert_eq!(refused(&commit(&mux, &repository, glob, "k-glob")).0, "path_not_found");
    assert_eq!(git(&repository, &["ls-files", "--others"]), "starry.txt");
}

#[test]
fn a_key_reused_after_the_target_moved_to_another_repository_is_refused() {
    let first = repository("moved-a");
    write(&first, "a.txt", "a\n");
    commit_all(&first, "base");
    write(&first, "a.txt", "a2\n");
    git(&first, &["add", "a.txt"]);
    let second = repository("moved-b");
    let link = temporary("moved-link").join("repo");
    symlink(&first, &link).unwrap();
    let mux = session("moved");
    ok(&commit(&mux, &link, json!({"message": "m"}), "k-moved"));
    fs::remove_file(&link).unwrap();
    symlink(&second, &link).unwrap();
    let envelope = commit(&mux, &link, json!({"message": "m"}), "k-moved");
    assert_eq!(refused(&envelope).0, "repository_changed");
}

#[test]
fn the_attempt_journal_drops_old_entries_and_keeps_at_most_its_cap() {
    let directory = temporary("journal-prune");
    let now = SystemTime::now();
    let old = now - MAX_AGE - Duration::from_secs(60);
    for index in 0..(MAX_ENTRIES + 40) {
        let path = directory.join(format!("{index:04}.json"));
        fs::write(&path, "{}").unwrap();
        let age = if index < 10 { old } else { now - Duration::from_secs((1000 - index) as u64) };
        fs::File::options().write(true).open(&path).unwrap().set_modified(age).unwrap();
    }
    fs::write(directory.join("other.txt"), "kept").unwrap();
    prune(&directory, now);
    let left: Vec<String> = fs::read_dir(&directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(left.iter().filter(|name| name.ends_with(".json")).count(), MAX_ENTRIES);
    assert!(left.contains(&"other.txt".to_string()));
    assert!(!left.contains(&"0009.json".to_string()), "an expired entry stayed");
    let newest = format!("{:04}.json", MAX_ENTRIES + 39);
    assert!(left.contains(&newest), "the newest entry went");
}
