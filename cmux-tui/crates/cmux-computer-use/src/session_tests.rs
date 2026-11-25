use super::*;

fn tmpdir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("cmux-cu-sessions-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn grants_survive_a_worker_restart() {
    let dir = tmpdir("restart");
    let first = Sessions::open(Some(&dir));
    first.grant("agent-1", "com.apple.Safari");
    first.update_saved(|s| s.set_always("org.mozilla.firefox"));
    drop(first);
    let second = Sessions::open(Some(&dir));
    assert!(second.has_grant("agent-1", "com.apple.safari"));
    assert!(!second.has_grant("agent-2", "com.apple.Safari"));
    assert!(second.saved().is_always("org.mozilla.firefox"));
    second.revoke_all(None);
    assert!(!Sessions::open(Some(&dir)).has_grant("agent-1", "com.apple.Safari"));
}

#[test]
fn a_retried_call_returns_the_first_result() {
    let s = Sessions::open(None);
    assert_eq!(s.prior("a", "c1"), Prior::New);
    s.begin("a", "c1");
    s.remember("a", "c1", "{\"ok\":1}".into());
    assert_eq!(s.prior("a", "c1"), Prior::Finished("{\"ok\":1}".into()));
    assert_eq!(s.prior("b", "c1"), Prior::New);
}

#[test]
fn finished_and_interrupted_calls_survive_a_worker_restart() {
    let dir = tmpdir("calls");
    let first = Sessions::open(Some(&dir));
    first.begin("remote:mini:s1", "done");
    first.remember("remote:mini:s1", "done", "r".into());
    // The worker stops after this one started acting, before it answered.
    first.begin("remote:mini:s1", "cut");
    drop(first);
    let second = Sessions::open(Some(&dir));
    assert_eq!(second.prior("remote:mini:s1", "done"), Prior::Finished("r".into()));
    assert_eq!(second.prior("remote:mini:s1", "cut"), Prior::Interrupted);
    second.revoke_all(None);
    // Revoking grants keeps the call records.
    assert_eq!(Sessions::open(Some(&dir)).prior("remote:mini:s1", "cut"), Prior::Interrupted);
}

#[test]
fn hostile_session_keys_stay_one_file_in_the_sessions_folder() {
    let dir = tmpdir("keys");
    let s = Sessions::open(Some(&dir));
    s.grant("../../etc/x", "a");
    assert!(!dir.join("etc").exists() && !dir.parent().unwrap().join("etc").exists());
    let files: Vec<_> = std::fs::read_dir(dir.join("sessions")).unwrap().flatten().collect();
    assert_eq!(files.len(), 1);
    assert!(!files[0].file_name().to_string_lossy().contains('/'));
    assert!(Sessions::open(Some(&dir)).has_grant("../../etc/x", "a"));
    assert_ne!(file_name("a:b"), file_name("a_b"));
}
