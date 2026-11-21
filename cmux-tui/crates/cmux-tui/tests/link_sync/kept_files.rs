//! A second push to the same copy keeps what the machine changed since the last push,
//! and the record keeps the last push so a pull still names both sides' changes.
use super::*;

#[test]
fn a_second_push_keeps_the_files_the_machine_changed_since_the_first() {
    // A second Cloud chat from the same folder (cloud.startChat, Move to Cloud) pushes it again
    // to the same copy: what the first chat changed there is never written over.
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    std::fs::write(remote.join("notes.txt"), "notes\nfrom the machine\n").unwrap();
    std::fs::write(remote.join("src/a.txt"), "one\nfrom the machine\n").unwrap();
    std::fs::write(repo.join("other.txt"), "other\nfrom the mac\n").unwrap();
    std::fs::write(repo.join("src/a.txt"), "one\nfrom the mac\n").unwrap();

    let again = push(&socket, &repo, &remote);
    assert_eq!(
        std::fs::read_to_string(remote.join("notes.txt")).unwrap(),
        "notes\nfrom the machine\n",
        "the push wrote over a file only the machine changed: {again}"
    );
    assert_eq!(
        std::fs::read_to_string(remote.join("src/a.txt")).unwrap(),
        "one\nfrom the machine\n",
        "the push wrote over a file both sides changed: {again}"
    );
    assert_eq!(std::fs::read_to_string(remote.join("other.txt")).unwrap(), "other\nfrom the mac\n");
    assert_eq!(again["kept"], 2, "{again}");

    // The record still holds the first push for the kept files: a pull brings the machine-only
    // edit back and names the file both sides changed.
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    assert_eq!(answer["conflicts"], serde_json::json!(["src/a.txt"]), "{answer}");
}

#[test]
fn a_file_deleted_here_but_changed_on_the_machine_stays_a_conflict_after_a_push() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    std::fs::write(remote.join("notes.txt"), "notes\nfrom the machine\n").unwrap();
    std::fs::remove_file(repo.join("notes.txt")).unwrap();

    let again = push(&socket, &repo, &remote);
    assert_eq!(
        std::fs::read_to_string(remote.join("notes.txt")).unwrap(),
        "notes\nfrom the machine\n",
        "the push deleted a file the machine changed: {again}"
    );
    assert_eq!(again["kept"], 1, "{again}");

    // The record still holds the last push for it: a pull names the delete here against the
    // edit there, and never quietly brings the machine's file back.
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    assert_eq!(answer["conflicts"], serde_json::json!(["notes.txt"]), "{answer}");
    assert!(!repo.join("notes.txt").exists(), "the pull brought the machine's file back");
}
