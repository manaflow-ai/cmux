//! The metadata writer's order and hand-back (`meta_save.rs`, fuzz row g finding g2), without a
//! hub: `write` copies a shared value and records the copy, as `session.json` would hold it.

use super::{MetaWriter, Wait};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

/// The value the "metadata" holds now, and every copy written, in order.
#[derive(Default)]
struct Disk {
    value: Mutex<u32>,
    written: Mutex<Vec<u32>>,
}

impl Disk {
    fn set(&self, v: u32) {
        *self.value.lock().unwrap() = v;
    }
    fn write(&self) -> anyhow::Result<()> {
        let copy = *self.value.lock().unwrap();
        self.written.lock().unwrap().push(copy);
        Ok(())
    }
    fn written(&self) -> Vec<u32> {
        self.written.lock().unwrap().clone()
    }
}

fn requested(writer: &MetaWriter) -> u64 {
    writer.state.lock().unwrap().requested
}

/// A change made while a commit of an older copy runs is answered only after a commit whose copy
/// holds it, and the older copy is never written after it.
#[test]
fn a_change_that_races_a_running_commit_is_answered_after_a_commit_that_holds_it() {
    let writer = Arc::new(MetaWriter::default());
    let disk = Arc::new(Disk::default());
    let (copied_tx, copied) = mpsc::channel::<()>();
    let (release, release_rx) = mpsc::channel::<()>();
    // A: changes the value to 1 and commits; its first write copies, then waits for the release.
    let a = {
        let (writer, disk) = (writer.clone(), disk.clone());
        std::thread::spawn(move || {
            let held = AtomicBool::new(true);
            disk.set(1);
            writer.commit(Wait::Durable, &|| {
                let copy = *disk.value.lock().unwrap();
                if held.swap(false, Ordering::SeqCst) {
                    copied_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                }
                disk.written.lock().unwrap().push(copy);
                Ok(())
            })
        })
    };
    copied.recv().unwrap();
    // B: changes the value to 2 while A's copy (1) waits to be written, and commits.
    let b = {
        let (writer, disk) = (writer.clone(), disk.clone());
        std::thread::spawn(move || {
            disk.set(2);
            writer.commit(Wait::Durable, &|| disk.write()).unwrap();
            // What the disk held when B was answered.
            disk.written()
        })
    };
    // B took its version while A's commit runs.
    while requested(&writer) < 2 {
        std::thread::yield_now();
    }
    release.send(()).unwrap();
    a.join().unwrap().unwrap();
    let at_answer = b.join().unwrap();
    assert_eq!(at_answer.last(), Some(&2), "B was answered before a commit held its change");
    assert_eq!(disk.written(), vec![1, 2], "the copies were not written in version order");
    let state = writer.state.lock().unwrap();
    assert_eq!((state.durable, state.writing), (2, false));
}

/// A writer that panics hands the role back: its waiters fail, and the next change becomes the
/// writer and commits.
#[test]
fn a_writer_that_panics_hands_the_role_back() {
    let writer = MetaWriter::default();
    let disk = Disk::default();
    disk.set(1);
    let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        writer.commit(Wait::Durable, &|| panic!("write panics"))
    }));
    assert!(panicked.is_err());
    assert!(!writer.state.lock().unwrap().writing, "the panicked writer kept the role");
    disk.set(2);
    writer.commit(Wait::Durable, &|| disk.write()).expect("the next change commits");
    assert_eq!(disk.written(), vec![2]);
}

/// A commit that fails fails the requests it covered, with its error, and leaves no writer; the
/// next change commits again.
#[test]
fn a_failed_commit_fails_its_request_and_the_next_change_commits() {
    let writer = MetaWriter::default();
    let disk = Disk::default();
    disk.set(1);
    let failed = writer.commit(Wait::Durable, &|| anyhow::bail!("disk full"));
    assert!(failed.unwrap_err().to_string().contains("disk full"));
    assert!(!writer.state.lock().unwrap().writing);
    disk.set(2);
    writer.commit(Wait::Durable, &|| disk.write()).expect("the next change commits");
    assert_eq!(disk.written(), vec![2]);
    assert!(writer.state.lock().unwrap().failed.is_none());
}

/// A change no request waits for returns while another writer works, and that writer commits it.
#[test]
fn a_change_nobody_waits_for_is_committed_by_the_writer_at_work() {
    let writer = Arc::new(MetaWriter::default());
    let disk = Arc::new(Disk::default());
    let (copied_tx, copied) = mpsc::channel::<()>();
    let (release, release_rx) = mpsc::channel::<()>();
    let a = {
        let (writer, disk) = (writer.clone(), disk.clone());
        std::thread::spawn(move || {
            let held = AtomicBool::new(true);
            disk.set(1);
            writer.commit(Wait::Durable, &|| {
                let copy = *disk.value.lock().unwrap();
                if held.swap(false, Ordering::SeqCst) {
                    copied_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                }
                disk.written.lock().unwrap().push(copy);
                Ok(())
            })
        })
    };
    copied.recv().unwrap();
    disk.set(2);
    // Returns at once: A is the writer.
    writer.commit(Wait::No, &|| panic!("only the writer at work writes")).unwrap();
    release.send(()).unwrap();
    a.join().unwrap().unwrap();
    assert_eq!(disk.written(), vec![1, 2]);
}
