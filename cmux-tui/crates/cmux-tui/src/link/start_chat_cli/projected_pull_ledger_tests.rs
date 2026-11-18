//! `project-pull`'s ledger across a pull cut short, and one pull of a mount at a time.

use std::collections::BTreeMap;

use crate::link::sync_cli::back::Left;

use super::*;

const BASE: [(&str, &[u8]); 5] =
    [("a.txt", b"a"), ("b.txt", b"b"), ("c.txt", b"c"), ("d/x.txt", b"dx"), ("d/e/y.txt", b"dy")];

/// Two replaces, a delete, a folder delete and a new folder with two files.
fn machine_edits(f: &Fixture<'_>) {
    f.machine_write("a.txt", b"a from the machine");
    f.machine_write("b.txt", b"b from the machine");
    f.machine_write("n/x.txt", b"new x");
    f.machine_write("n/y.txt", b"new y");
    std::fs::remove_file(f.machine.join("c.txt")).unwrap();
    std::fs::remove_dir_all(f.machine.join("d")).unwrap();
    f.upper(&json!([
        change("a.txt", "file"),
        change("b.txt", "file"),
        change("c.txt", "delete"),
        change("d", "delete"),
        change("n", "dir"),
        change("n/x.txt", "file"),
        change("n/y.txt", "file"),
    ]));
}

/// Every name in `root` with its bytes (None for a folder).
fn contents(root: &Path) -> BTreeMap<String, Option<Vec<u8>>> {
    tree(root).into_iter().map(|path| (path.clone(), std::fs::read(root.join(path)).ok())).collect()
}

#[test]
fn a_pull_stopped_after_any_item_and_run_again_ends_as_one_that_was_not() {
    let daemon = Daemon::start();
    let whole = Fixture::new(&daemon, &BASE);
    machine_edits(&whole);
    let first = whole.pull();
    assert_eq!(ok(&first)["conflicts"], json!([]), "{first}");
    let want = contents(&whole.root);
    let mut stopped = 0;
    for stop in 0..32 {
        let f = Fixture::new(&daemon, &BASE);
        machine_edits(&f);
        let cut = run_until(&f.kept, None, false, Some(stop));
        let finished = cut["ok"] == true;
        if !finished {
            assert_eq!(cut["code"], "stopped", "{cut}");
            stopped += 1;
        }
        let again = f.pull();
        assert_eq!(ok(&again)["conflicts"], json!([]), "stopped after {stop}: {again}");
        assert_eq!(contents(&f.root), want, "stopped after {stop}: {again}");
        let ledger = ledger::load(&f.kept).unwrap();
        let stuck: Vec<&String> =
            ledger.paths.iter().filter(|(_, p)| p.mac == Left::Conflict).map(|(p, _)| p).collect();
        assert!(stuck.is_empty(), "stopped after {stop}: {stuck:?}");
        assert!(!ledger::has_journal(&f.kept), "the journal is folded in");
        // A third pull has nothing left to do.
        assert_eq!(ok(&f.pull())["applied"], 0, "stopped after {stop}");
        if finished {
            break;
        }
    }
    assert!(stopped >= 7, "every item was a place to stop: {stopped}");
}

#[test]
fn a_journal_line_cut_short_is_not_a_settled_path() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    f.machine_write("a.txt", b"edited");
    f.machine_write("b.txt", b"made");
    f.upper(&json!([change("a.txt", "file"), change("b.txt", "file")]));
    assert_eq!(run_until(&f.kept, None, false, Some(1))["code"], "stopped");
    let mut journal = std::fs::read(f.kept.join(ledger::JOURNAL)).unwrap();
    assert!(journal.ends_with(b"\n"), "one whole line per settled path");
    journal.extend_from_slice(b"{\"path\":\"b.txt\",\"pul");
    std::fs::write(f.kept.join(ledger::JOURNAL), &journal).unwrap();
    let ledger = ledger::load(&f.kept).unwrap();
    assert_eq!(ledger.paths.keys().collect::<Vec<_>>(), ["a.txt"]);
    let summary = f.pull();
    assert_eq!(ok(&summary)["applied"], 1, "{summary}");
    assert_eq!(summary["conflicts"], json!([]));
    assert_eq!(f.mac("b.txt").unwrap(), b"made");
}

#[test]
fn a_second_pull_while_one_holds_the_lock_is_busy_and_changes_nothing() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    f.machine_write("a.txt", b"edited");
    f.upper(&json!([change("a.txt", "file")]));
    let Ok(held) = ledger::lock(&f.kept) else { panic!("the lock is free") };
    let before = contents(&f.root);
    for busy in [f.pull(), f.dry()] {
        assert_eq!(busy["ok"], false, "{busy}");
        assert_eq!(busy["code"], "busy", "{busy}");
    }
    assert_eq!(contents(&f.root), before);
    assert!(!f.kept.join(PULLED).exists());
    assert!(!ledger::has_journal(&f.kept));
    drop(held);
    assert_eq!(ok(&f.pull())["applied"], 1);
    assert_eq!(f.mac("a.txt").unwrap(), b"edited");
}
