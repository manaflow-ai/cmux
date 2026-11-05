//! The log test, alone in its binary: the process-wide subscriber it sets
//! sees every event, with no other test's callsites in the way.

mod common;

use std::sync::{Arc, Mutex};

use base64::Engine as _;

use common::*;

/// Logs carry the name and the host, never the value.
#[tokio::test]
async fn logs_name_the_secret_and_never_carry_its_value() {
    #[derive(Clone, Default)]
    struct Buf(Arc<Mutex<Vec<u8>>>);
    impl std::io::Write for Buf {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let buf = Buf::default();
    let writer = buf.clone();
    let subscriber = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::TRACE)
        .with_ansi(false)
        .with_writer(move || writer.clone())
        .finish();
    tracing::subscriber::set_global_default(subscriber).unwrap();

    let h = harness().await;
    let engine = base64::engine::general_purpose::STANDARD;
    let basic = format!("Basic {}", engine.encode("u:cmux-secret://TOKEN"));
    let stream = tunnel(h.proxy, "allowed.test").await.unwrap();
    let (_, body) = get(
        stream,
        "allowed.test",
        proxy_roots(&h),
        "allowed.test",
        &[("authorization", "Bearer cmux-secret://TOKEN"), ("x-api-key", &basic)],
    )
    .await
    .unwrap();
    assert!(body.contains(VALUE));

    let logs = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
    assert!(logs.contains("vault.egress_substituted"), "{logs}");
    assert!(logs.contains("TOKEN") && logs.contains("allowed.test"), "{logs}");
    assert!(!logs.contains(VALUE), "{logs}");
    assert!(!logs.contains(&engine.encode(format!("u:{VALUE}"))), "{logs}");
}
