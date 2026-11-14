use super::*;
use crate::provider::{Frame, PROVIDER_VERSION, ProviderSecret, read_frame, write_frame};

fn hello(secret: &str) -> Frame {
    Frame::Hello {
        version: PROVIDER_VERSION,
        provider_id: "app".into(),
        install_id: "install".into(),
        secret: ProviderSecret::new(secret),
        engines: vec!["cef".into()],
        tabs: Vec::new(),
    }
}

/// Sends hello and returns the stream when the host answered hello.ack.
fn dial(path: &Path, secret: &str) -> Option<UnixStream> {
    let mut stream = UnixStream::connect(path).unwrap();
    stream.set_read_timeout(Some(std::time::Duration::from_secs(10))).unwrap();
    write_frame(&mut stream, &hello(secret)).unwrap();
    match read_frame(&mut stream) {
        Ok(Some(Frame::HelloAck { .. })) => Some(stream),
        _ => None,
    }
}

#[test]
fn the_provider_listener_needs_the_secret_and_takes_one_provider_at_a_time() {
    let dir = std::env::temp_dir().join(format!("cmux-bh-provider-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("browser-host-provider.sock");
    let listener = bind(&path, true).unwrap();
    let slot: crate::engines::ProviderSlot = Arc::default();
    let secret = "s".repeat(40);
    let (thread_slot, thread_secret) = (slot.clone(), ProviderSecret::new(secret.clone()));
    std::thread::spawn(move || {
        serve_providers(listener, thread_secret, thread_slot, Arc::from("agent"))
    });
    assert!(dial(&path, "wrong-secret-wrong-secret-wrong-secret").is_none());
    assert!(slot.lock().unwrap().is_none());
    let first = dial(&path, &secret).expect("the right secret is accepted");
    // The slot is set right after hello.ack; wait for it without sleeping.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while slot.lock().unwrap().is_none() && std::time::Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(slot.lock().unwrap().is_some());
    assert!(dial(&path, &secret).is_none(), "a second provider is refused while the first is live");
    drop(first);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while slot.lock().unwrap().as_ref().is_some_and(|p| p.closed_reason().is_none())
        && std::time::Instant::now() < deadline
    {
        std::thread::yield_now();
    }
    assert!(dial(&path, &secret).is_some(), "a new provider replaces a closed one");
    let _ = std::fs::remove_dir_all(&dir);
}
