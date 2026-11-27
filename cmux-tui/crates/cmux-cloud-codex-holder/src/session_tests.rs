//! The private pipe to one holder process. Ported from CloudCodexBrokerSessionTests.swift; each
//! test starts a python3 holder that answers by method.

use super::*;

const HOLDER: &str = r#"
import json, os, signal, sys, time
root = sys.argv[sys.argv.index('--home') + 1]
def terminated(*_):
    # An owned child may still be releasing its credential lock after SIGTERM.
    time.sleep(0.1)
    open(os.path.join(root, 'exited'), 'w').close()
    sys.exit(0)
signal.signal(signal.SIGTERM, terminated)
pending = {}
barrier = None
def reply(id, account='ok', error=None):
    value = {'id': id, 'error': error} if error else {'id': id, 'result': {'chatgptAccountId': account}}
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    method, id = request['method'], request['id']
    if method in ('cancel-me', 'survivor'): pending[method] = id
    elif method == 'barrier': barrier = id
    elif method == 'release':
        for key, value in pending.items(): reply(value, 'survived')
        pending.clear()
        reply(id)
    elif method == 'timeout':
        reply(id, error='codex_auth_timeout')
        sys.exit(0)
    elif method == 'account': reply(id, error='codex_auth_account_changed')
    elif method == 'ignore-term':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        reply(id, str(os.getpid()))
    elif method == 'environment':
        reply(id, json.dumps({k: os.environ[k] for k in ('TMPDIR', 'SSL_CERT_FILE', 'SSL_CERT_DIR', 'UNRELATED_SECRET') if k in os.environ}))
    elif method == 'huge':
        print('x' * (70 * 1024), flush=True)
    else: reply(id)
    if barrier is not None and len(pending) == 2:
        reply(barrier)
        barrier = None
"#;

fn session(root: &Path) -> Arc<Session> {
    let script = root.join("holder.py");
    std::fs::write(&script, HOLDER).unwrap();
    let mut environment: HashMap<String, String> = std::env::vars().collect();
    environment.insert("TMPDIR".into(), root.display().to_string());
    environment.insert("SSL_CERT_FILE".into(), root.join("ca.pem").display().to_string());
    environment.insert("SSL_CERT_DIR".into(), root.join("certs").display().to_string());
    environment.insert("UNRELATED_SECRET".into(), "must-not-inherit".into());
    Session::spawn(
        Path::new("/usr/bin/env"),
        &["python3".into(), script.display().to_string()],
        Path::new("/unused"),
        root,
        &environment,
        root,
    )
    .unwrap()
}

fn account(reply: &Value) -> &str {
    reply["chatgptAccountId"].as_str().unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn typed_errors() {
    let root = tempfile::tempdir().unwrap();
    let session = session(root.path());
    let cx = Cx::new();
    assert_eq!(
        session.request(&cx, "account", None, None).await,
        Err(SessionError::AccountChanged)
    );
    assert_eq!(session.request(&cx, "timeout", None, None).await, Err(SessionError::TimedOut));
    session.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn cancellation_only_settles_its_caller() {
    let root = tempfile::tempdir().unwrap();
    let session = session(root.path());
    let first_cx = Cx::new();
    let first = {
        let (session, cx) = (session.clone(), first_cx.clone());
        tokio::spawn(async move { session.request(&cx, "cancel-me", None, None).await })
    };
    let survivor = {
        let session = session.clone();
        tokio::spawn(async move { session.request(&Cx::new(), "survivor", None, None).await })
    };
    // The fixture replies only after both requests are pending.
    session.request(&Cx::new(), "barrier", None, None).await.unwrap();
    first_cx.cancel();
    assert_eq!(first.await.unwrap(), Err(SessionError::Cancelled));
    session.request(&Cx::new(), "release", None, None).await.unwrap();
    assert_eq!(account(&survivor.await.unwrap().unwrap()), "survived");
    session.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn shutdown_waits_for_child_exit() {
    let root = tempfile::tempdir().unwrap();
    let session = session(root.path());
    session.request(&Cx::new(), "ready", None, None).await.unwrap();
    session.shutdown().await;
    assert!(root.path().join("exited").exists());
    assert_eq!(
        session.request(&Cx::new(), "ready", None, None).await,
        Err(SessionError::InvalidReply),
        "a stopped session takes no request"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn shutdown_escalates_only_the_owned_holder_that_ignores_term() {
    let root = tempfile::tempdir().unwrap();
    let session = session(root.path());
    let reply = session.request(&Cx::new(), "ignore-term", None, None).await.unwrap();
    let pid: i32 = account(&reply).parse().unwrap();
    // Both shutdowns returning with the holder gone proves the SIGKILL escalation.
    tokio::join!(session.shutdown(), session.shutdown());
    // SAFETY: signal 0 only probes the pid.
    let alive = unsafe { libc::kill(pid, 0) };
    assert_eq!(alive, -1);
    assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
}

#[tokio::test(flavor = "multi_thread")]
async fn child_keeps_tls_and_temporary_directory_environment() {
    let root = tempfile::tempdir().unwrap();
    let session = session(root.path());
    let reply = session.request(&Cx::new(), "environment", None, None).await.unwrap();
    let values: HashMap<String, String> = serde_json::from_str(account(&reply)).unwrap();
    assert_eq!(values["TMPDIR"], root.path().display().to_string());
    assert_eq!(values["SSL_CERT_FILE"], root.path().join("ca.pem").display().to_string());
    assert_eq!(values["SSL_CERT_DIR"], root.path().join("certs").display().to_string());
    assert!(!values.contains_key("UNRELATED_SECRET"));
    session.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_line_past_its_bound_fails_the_request_and_stops_the_holder() {
    let root = tempfile::tempdir().unwrap();
    let session = session(root.path());
    assert_eq!(
        session.request(&Cx::new(), "huge", None, None).await,
        Err(SessionError::InvalidReply)
    );
    session.shutdown().await;
}
