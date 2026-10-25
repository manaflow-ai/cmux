//! Panic mode is process-wide, so it gets its own test binary.
#![cfg(debug_assertions)]

use cmux_threads::blocking::{BlockingMode, set_mode, snapshot};
use cmux_threads::{checked, disallow_blocking};

#[test]
fn disallowed_checked_read_panics_with_the_caller_location() {
    set_mode(BlockingMode::Panic);
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
    let (line_tx, line_rx) = std::sync::mpsc::channel();
    let result = std::thread::Builder::new()
        .name("mux-conn-test".into())
        .spawn(move || {
            disallow_blocking();
            line_tx.send(line!() + 1).expect("send line");
            let _ = checked::fs::read(&manifest);
        })
        .expect("spawn")
        .join();
    let line = line_rx.recv().expect("line");
    let payload = result.expect_err("the checked read panics");
    let message = payload.downcast_ref::<String>().cloned().unwrap_or_default();
    assert!(message.contains(&format!("{}:{line}:", file!())), "{message}");
    assert!(message.contains("(fs)"), "{message}");
    assert!(message.contains("'mux-conn-test'"), "{message}");
    assert_eq!(snapshot().site(file!(), line).map(|site| site.count), Some(1));
}

#[test]
fn ordinary_thread_never_panics() {
    set_mode(BlockingMode::Panic);
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
    let line = line!() + 1;
    let bytes = checked::fs::read(&manifest).expect("read");
    assert!(!bytes.is_empty());
    assert_eq!(snapshot().site(file!(), line), None);
}
