use super::*;

fn temp() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-disk-writer-{}-{}",
        std::process::id(),
        crate::store::now_ms()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(format!("f-{:?}", std::thread::current().id()).replace(['(', ')'], ""))
}

#[test]
fn a_file_changed_while_the_disk_is_slow_is_written_once_with_its_newest_bytes() {
    let path = temp();
    let _slow = crate::config::startup_seams::slow_syncs(
        path.parent().unwrap(),
        Duration::from_millis(200),
    );
    // A first write holds the writer in the slow sync; the 999 that follow wait and fold.
    let started = Instant::now();
    for n in 0..1000 {
        write_later(&path, format!("{n}").into_bytes());
    }
    assert!(started.elapsed() < Duration::from_millis(150), "a caller waited on the disk");
    assert!(flush(Duration::from_secs(10)));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "999");
    // A direct write after a later one is never overwritten by it.
    write_later(&path, b"queued".to_vec());
    crate::config::write_atomic(&path, b"direct").unwrap();
    assert!(flush(Duration::from_secs(10)));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "direct");
}

#[test]
fn a_job_waits_once_per_key() {
    let ran = std::sync::Arc::new(AtomicU64::new(0));
    let (hold, held) = std::sync::mpsc::channel::<()>();
    // Holds the writer, so the jobs below wait together.
    run_later("hold", move || {
        let _ = held.recv_timeout(Duration::from_secs(5));
    });
    for _ in 0..100 {
        let ran = ran.clone();
        run_later("save", move || {
            ran.fetch_add(1, Relaxed);
        });
    }
    drop(hold);
    assert!(flush(Duration::from_secs(10)));
    assert_eq!(ran.load(Relaxed), 1);
}
