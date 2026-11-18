//! `project-pull` of a move: its origin, the only copy here of what was moved, stays whole until
//! every item at the new path landed on this Mac.

use super::*;

const CONFIG: [(&str, &[u8]); 2] = [("config/a.txt", b"a"), ("config/s/b.txt", b"b")];

/// This Mac's folder as a git working copy that ignores `*.bak`.
fn ignoring_bak(root: &Path) {
    let status = Command::new("git").arg("init").arg("-q").arg(root).status().unwrap();
    assert!(status.success());
    put(root, ".gitignore", b"*.bak\n");
}

/// `mv from to` on the machine, and the upper layer overlayfs keeps for it: a whiteout at the
/// origin and a redirect at the new path.
fn moved(f: &Fixture<'_>, from: &str, to: &str) {
    std::fs::rename(f.machine.join(from), f.machine.join(to)).unwrap();
    f.upper(&json!([
        change(from, "delete"),
        { "path": to, "kind": "redirect", "from": format!("/{from}") },
    ]));
}

fn config_whole(f: &Fixture<'_>) {
    assert_eq!(f.mac("config/a.txt").unwrap(), b"a");
    assert_eq!(f.mac("config/s/b.txt").unwrap(), b"b");
}

fn has(got: &[(String, String)], path: &str, reason: &str) -> bool {
    got.iter().any(|(p, r)| p == path && r == reason)
}

#[test]
fn a_move_onto_an_ignored_name_keeps_the_origin_and_names_why() {
    let daemon = Daemon::start();
    let f = Fixture::made(&daemon, &CONFIG, ignoring_bak);
    moved(&f, "config", "config.bak");
    let summary = f.pull();
    config_whole(&f);
    let got = refused(ok(&summary));
    assert!(has(&got, "config.bak", "ignored"), "{summary}");
    assert!(has(&got, "config.bak/a.txt", "ignored"), "{summary}");
    assert!(has(&got, "config", "origin_kept"), "{summary}");
    assert_eq!(summary["deleted"], 0, "{summary}");
    assert!(!f.root.join("config.bak").exists());
    // The move is not settled: the next pull decides the same again.
    let again = f.pull();
    assert_eq!(refused(ok(&again)), got, "{again}");
    config_whole(&f);
}

#[test]
fn a_move_onto_a_secret_name_keeps_the_origin() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("keys/id", b"key"), ("keys/notes.txt", b"notes")]);
    moved(&f, "keys", ".ssh");
    let summary = f.pull();
    assert_eq!(f.mac("keys/id").unwrap(), b"key");
    assert_eq!(f.mac("keys/notes.txt").unwrap(), b"notes");
    let got = refused(ok(&summary));
    assert!(has(&got, ".ssh", "secret"), "{summary}");
    assert!(has(&got, "keys", "origin_kept"), "{summary}");
    assert!(!f.root.join(".ssh").exists());
}

#[test]
fn a_moved_file_the_machine_cannot_read_keeps_the_origin_until_it_can() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &CONFIG);
    moved(&f, "config", "conf");
    let unreadable = f.machine.join("conf/s/b.txt").display().to_string();
    daemon.state().refusing.insert(unreadable);
    let summary = f.pull();
    config_whole(&f);
    let got = refused(ok(&summary));
    assert!(has(&got, "conf/s/b.txt", "machine_refused"), "{summary}");
    assert!(has(&got, "config", "origin_kept"), "{summary}");
    assert_eq!(f.mac("conf/a.txt").unwrap(), b"a", "what could be read landed");
    // The machine answers again: the move lands whole and then the origin goes.
    daemon.state().refusing.clear();
    let later = f.pull();
    assert_eq!(ok(&later)["refused"], json!([]), "{later}");
    assert_eq!(later["conflicts"], json!([]), "{later}");
    assert_eq!(f.mac("conf/s/b.txt").unwrap(), b"b");
    assert!(!f.root.join("config").exists(), "{later}");
    assert_eq!(ok(&f.pull())["applied"], 0, "settled");
}

#[test]
fn a_move_lands_once_the_ignore_rule_is_gone_and_then_deletes_the_origin() {
    let daemon = Daemon::start();
    let f = Fixture::made(&daemon, &CONFIG, ignoring_bak);
    moved(&f, "config", "config.bak");
    assert!(has(&refused(ok(&f.pull())), "config", "origin_kept"));
    config_whole(&f);
    put(&f.root, ".gitignore", b"");
    let later = f.pull();
    assert_eq!(ok(&later)["refused"], json!([]), "{later}");
    assert_eq!(f.mac("config.bak/a.txt").unwrap(), b"a");
    assert_eq!(f.mac("config.bak/s/b.txt").unwrap(), b"b");
    assert!(!f.root.join("config").exists(), "{later}");
}

#[test]
fn a_renamed_file_kept_as_a_redirect_keeps_its_origin_when_refused() {
    let daemon = Daemon::start();
    let f = Fixture::made(&daemon, &[("a.txt", b"only copy")], ignoring_bak);
    moved(&f, "a.txt", "a.bak");
    let got = refused(ok(&f.pull()));
    assert!(has(&got, "a.bak", "ignored"), "{got:?}");
    assert!(has(&got, "a.txt", "origin_kept"), "{got:?}");
    assert_eq!(f.mac("a.txt").unwrap(), b"only copy");
}
