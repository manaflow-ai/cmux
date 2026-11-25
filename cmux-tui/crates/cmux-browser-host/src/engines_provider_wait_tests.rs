use super::*;
use crate::host::{Caller, Host};
use serde_json::json;
use std::time::{Duration, Instant};

fn caller() -> Caller {
    Caller {
        actor: "uid:501".into(),
        on_behalf_of: None,
        origin: "cli".into(),
        locality: Default::default(),
    }
}

/// A host the daemon just started on an agent connect: a webkit session
/// opened before the app's provider link is up waits for it (bounded),
/// instead of failing at once with engine_unavailable.
#[test]
fn a_webkit_session_waits_for_the_app_to_connect() {
    let engines = Arc::new(HostEngines::new(crate::host::agent_bundle()));
    let host = Host::new(engines.clone(), "/tmp");
    let opened = std::thread::spawn(move || {
        host.dispatch(&caller(), "browser.repl.open", &json!({"session": "w", "engine": "webkit"}))
    });
    std::thread::sleep(Duration::from_millis(200));
    let (app, host_end) = std::os::unix::net::UnixStream::pair().unwrap();
    let driver = crate::provider_link::ProviderDriver::start(
        host_end.try_clone().unwrap(),
        host_end,
        crate::driver::discard_events(),
        Vec::new(),
    )
    .unwrap();
    *engines.provider_slot().lock().unwrap() = Some(driver);
    engines.provider_changed();
    let result = opened.join().unwrap();
    assert!(result.is_ok(), "the session opened once the app connected: {result:?}");
    drop(app);
}

#[test]
fn without_an_app_the_session_fails_after_the_wait() {
    let wait = Duration::from_millis(150);
    let engines = Arc::new(HostEngines::new(crate::host::agent_bundle()).with_provider_wait(wait));
    let host = Host::new(engines, "/tmp");
    let started = Instant::now();
    let error = host
        .dispatch(&caller(), "browser.repl.open", &json!({"session": "w", "engine": "webkit"}))
        .unwrap_err();
    assert!(started.elapsed() >= wait, "it waited");
    assert!(error.message.contains("engine_unavailable"), "{error:?}");
}
