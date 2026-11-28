use super::*;

#[test]
fn slope_is_the_growth_per_sample() {
    assert!((slope(&[1.0, 2.0, 3.0, 4.0]) - 1.0).abs() < 1e-9);
    assert!(slope(&[5.0, 5.0, 5.0]).abs() < 1e-9);
    assert!(slope(&[4.0, 3.0, 2.0]) < 0.0);
    // One step (a pool grown once) is not growth; a steady climb is.
    assert!(slope(&[10.0, 20.0, 20.0, 20.0, 20.0, 20.0]).abs() < 1e-9);
    assert!((slope(&[10.0, 11.0, 12.0, 13.0, 14.0, 15.0]) - 1.0).abs() < 1e-9);
}

#[test]
fn io_field_reads_wchar() {
    let text = "rchar: 10\nwchar: 2048\nsyscr: 1\n";
    assert_eq!(io_field(text, "wchar"), Some(2048));
    assert_eq!(io_field(text, "rchar"), Some(10));
}

#[test]
#[cfg(target_os = "linux")]
fn thread_written_counts_this_threads_writes_only() {
    let dir = tempfile::tempdir().unwrap();
    let before = thread_written().unwrap();
    // Another thread's writes are not this thread's.
    let p = dir.path().join("other");
    std::thread::spawn(move || std::fs::write(p, vec![0u8; 1 << 20]).unwrap()).join().unwrap();
    let mid = thread_written().unwrap();
    std::fs::write(dir.path().join("mine"), vec![0u8; 4096]).unwrap();
    let after = thread_written().unwrap();
    assert!(mid - before < 4096, "{before} {mid}");
    assert!(after - mid >= 4096, "{mid} {after}");
}
