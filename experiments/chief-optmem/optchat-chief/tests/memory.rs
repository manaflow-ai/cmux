//! Moving the Chief's memory to another brain host (brains/DESIGN-cmux-lawrence.md
//! section 5): export a home's OptChat memory as one archive, import it into
//! a fresh home, and seal the old home so its host never starts again.

use optchat_chief::memory::{export, import, sealed};
use optchat_chief::paths::Paths;
use optchat_host::Kind;

fn home_with_messages(dir: &std::path::Path, n: usize) -> Paths {
    let paths = Paths::new(dir);
    paths.create().unwrap();
    let items: Vec<optchat_chief::browse::Imported> = (0..n)
        .map(|i| optchat_chief::browse::Imported { kind: Kind::Note, text: format!("note {i}") })
        .collect();
    optchat_chief::browse::import(&paths.chat, &items).unwrap();
    optchat_chief::persist::snapshot(&paths.chat, "turn:test").unwrap();
    std::fs::write(&paths.instructions, "Be brief.\n").unwrap();
    std::fs::write(&paths.state, "{\"outbox\":[]}").unwrap();
    paths
}

fn messages(paths: &Paths) -> u64 {
    let chat = optchat_chief::browse::open_offline(&paths.chat).unwrap();
    let n = chat.status().messages;
    chat.shutdown();
    n
}

#[test]
fn export_then_import_moves_the_whole_memory_but_not_the_host_state() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    let out = tempfile::tempdir().unwrap();
    let from = home_with_messages(src.path(), 3);
    let archive = out.path().join("chief-memory.tar");
    let report = export(&from, &archive, false).unwrap();
    assert_eq!(report.messages, 3);
    assert!(!sealed(&from), "export without --seal leaves the home usable");

    let to = Paths::new(dst.path());
    let report = import(&to, &archive).unwrap();
    assert_eq!(report.messages, 3);
    assert_eq!(messages(&to), 3);
    assert_eq!(std::fs::read_to_string(&to.instructions).unwrap(), "Be brief.\n");
    // host.json holds the old home's outbox and cursor of its own conversation.
    assert!(!to.state.exists());
    // The memory stays a git repository with its history.
    assert!(to.chat.join(".git").exists());
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(&to.root).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o700);
}

#[test]
fn import_refuses_a_home_that_already_has_a_memory() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    let out = tempfile::tempdir().unwrap();
    let from = home_with_messages(src.path(), 2);
    let to = home_with_messages(dst.path(), 1);
    let archive = out.path().join("m.tar");
    export(&from, &archive, false).unwrap();
    let err = import(&to, &archive).unwrap_err();
    assert!(err.contains("already"), "{err}");
    assert_eq!(messages(&to), 1, "the existing memory is untouched");
}

#[test]
fn a_sealed_home_says_where_its_memory_went() {
    let src = tempfile::tempdir().unwrap();
    let out = tempfile::tempdir().unwrap();
    let from = home_with_messages(src.path(), 1);
    export(&from, &out.path().join("m.tar"), true).unwrap();
    assert!(sealed(&from));
}
