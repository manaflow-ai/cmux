use super::*;
use crate::tailnet::embedded::Controller;

const KEY: &str = "tskey-auth-kSECRETVALUE-0123456789";
const HS_KEY: &str = "hskeySECRETVALUE0123456789abcdef";

fn params(key: &str) -> JoinParams {
    JoinParams { v: JOIN_VERSION, key: Some(Secret::new(key)), ..JoinParams::default() }
}

/// Every file under `dir`, read whole, so a test can say the key is in none of them.
fn all_bytes(dir: &Path) -> Vec<u8> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() {
            out.extend(all_bytes(&path));
        } else if let Ok(bytes) = std::fs::read(&path) {
            out.extend(bytes);
        }
    }
    out
}

fn contains(haystack: &[u8], needle: &str) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle.as_bytes())
}

/// A temporary root that is 0700 whatever the umask (a lane VM's 002 makes it group-writable,
/// and the state folder checks refuse a writable ancestor).
fn private_tempdir() -> tempfile::TempDir {
    let temporary = tempfile::tempdir().unwrap();
    private_dir(temporary.path());
    temporary
}

fn private_dir(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

#[test]
fn the_key_never_shows_in_debug_or_serialization() {
    let p = params(KEY);
    let shown = format!("{p:?} {p:#?} {}", serde_json::to_string(&p).unwrap());
    assert!(!shown.contains("SECRETVALUE"), "{shown}");
    let plan = p.plan().unwrap();
    let shown = format!("{plan:?} {}", plan.profile.to_json());
    assert!(!shown.contains("SECRETVALUE"), "{shown}");
    assert_eq!(plan.key.expose(), KEY);
}

#[test]
fn a_refused_request_never_echoes_its_params() {
    let error = JoinParams::from_value(&json!({"key": KEY, "tags": "not-a-list"})).unwrap_err();
    assert!(!error.contains("SECRETVALUE"), "{error}");
    let mut p = params("tskey-auth-has space SECRETVALUE");
    p.hostname = Some("mac".into());
    let error = p.plan().unwrap_err();
    assert!(!error.contains("SECRETVALUE"), "{error}");
}

#[test]
fn a_join_checks_the_key_server_name_and_tags() {
    assert!(JoinParams::default().plan().unwrap_err().contains("key is required"));
    // A Headscale key needs its server; Tailscale's keys start with tskey-auth-.
    assert!(params(HS_KEY).plan().is_err());
    let mut p = params(HS_KEY);
    p.control_url = Some("https://hs.example.com/".into());
    p.hostname = Some("Leo-Mac".into());
    p.tags = vec!["cmux".into(), "tag:cmux".into(), "tag:mac".into()];
    let plan = p.plan().unwrap();
    assert_eq!(plan.profile.control_url.as_deref(), Some("https://hs.example.com"));
    assert_eq!(plan.profile.hostname.as_deref(), Some("leo-mac"));
    assert_eq!(plan.profile.tags, ["tag:cmux", "tag:mac"]);
    let mut p = params(KEY);
    p.tags = vec!["bad tag".into()];
    assert!(p.plan().is_err());
}

#[test]
fn plain_http_needs_the_persons_opt_in_whatever_the_address() {
    for url in ["http://10.0.0.5:8080", "http://headscale:8080", "http://localhost:8080"] {
        let mut p = params(HS_KEY);
        p.control_url = Some(url.into());
        let error = p.clone().plan().unwrap_err();
        assert!(error.contains("--allow-http"), "{url}: {error}");
        p.allow_http = true;
        assert!(p.plan().is_ok(), "{url}");
    }
}

/// Lockstep: an older client's params (no `v`, no newer fields) and a newer one's (unknown
/// fields) both read; what this build writes reads in an older or newer build's shape.
#[test]
fn join_params_and_profile_read_old_and_new_shapes_both_ways() {
    let old = json!({"key": KEY, "hostname": "mac"});
    let p = JoinParams::from_value(&old).unwrap();
    assert_eq!(
        (p.v, p.hostname.as_deref(), p.switch, p.allow_http),
        (0, Some("mac"), false, false)
    );
    let new = json!({"v": 2, "key": KEY, "tags": ["tag:a"], "futureField": {"x": 1}, "ssh": true});
    let p = JoinParams::from_value(&new).unwrap();
    assert_eq!((p.v, p.tags.as_slice()), (2, ["tag:a".to_owned()].as_slice()));

    let profile = JoinProfile {
        v: JOIN_VERSION,
        control_url: Some("https://hs.example.com".into()),
        hostname: Some("mac".into()),
        tags: vec!["tag:a".into()],
        ephemeral: false,
    };
    // This build's JSON, read by an older reader that knows only controlUrl.
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct OldReader {
        control_url: Option<String>,
    }
    let written = serde_json::to_value(&profile).unwrap();
    let old: OldReader = serde_json::from_value(written.clone()).unwrap();
    assert_eq!(old.control_url.as_deref(), Some("https://hs.example.com"));
    assert_eq!(serde_json::from_value::<JoinProfile>(written).unwrap(), profile);
    // A newer build's JSON (extra fields), and an older one's (fields missing), read here.
    let newer = json!({"v": 9, "controlUrl": "https://x", "tags": ["tag:a"], "routes": ["10/8"]});
    let read: JoinProfile = serde_json::from_value(newer).unwrap();
    assert_eq!((read.v, read.control_url.as_deref()), (9, Some("https://x")));
    let older: JoinProfile = serde_json::from_value(json!({})).unwrap();
    assert_eq!(older, JoinProfile::default());
    assert_eq!(profile.to_json()["v"], JOIN_VERSION);
}

#[test]
fn the_saved_profile_never_holds_the_key() {
    let temporary = private_tempdir();
    let dir = temporary.path().join("tailnet");
    let mut p = params(HS_KEY);
    p.control_url = Some("https://hs.example.com".into());
    let plan = p.plan().unwrap();
    write_profile(&dir, &plan.profile).unwrap();
    assert!(!contains(&all_bytes(&dir), "SECRETVALUE"));
    assert_eq!(read_profile(&dir).unwrap(), plan.profile);
}

#[test]
fn a_saved_login_is_a_current_profile_in_tsnets_store() {
    let temporary = private_tempdir();
    let dir = temporary.path();
    assert!(!has_saved_login(dir));
    std::fs::write(dir.join("tailscaled.state"), br#"{"_machinekey":"bWs="}"#).unwrap();
    assert!(!has_saved_login(dir), "a machine key alone is no login");
    std::fs::write(dir.join("tailscaled.state"), br#"{"_current-profile":"MWEyYg=="}"#).unwrap();
    assert!(has_saved_login(dir));
    let refusal = other_tailnet_refusal(Some(&JoinProfile {
        control_url: Some("https://hs.example.com".into()),
        ..JoinProfile::default()
    }));
    assert!(refusal.contains("hs.example.com") && refusal.contains("--switch"), "{refusal}");
}

#[test]
fn the_node_config_takes_the_profile_and_the_key_once() {
    let profile = JoinProfile {
        v: 1,
        control_url: Some("https://hs.example.com".into()),
        hostname: Some("leo-mac".into()),
        tags: vec!["tag:cmux".into()],
        ephemeral: true,
    };
    let config = crate::tailnet::embedded::node_config(
        "/tmp/x".into(),
        "machine".into(),
        Some(&profile),
        Some(Secret::new(KEY)),
    );
    assert_eq!(config.hostname, "leo-mac");
    assert_eq!(config.control_url.as_deref(), Some("https://hs.example.com"));
    assert_eq!(config.advertise_tags, ["tag:cmux"]);
    assert!(config.ephemeral);
    assert_eq!(config.auth_key.as_deref(), Some(KEY));
    assert!(!format!("{config:?}").contains("SECRETVALUE"));
    let plain =
        crate::tailnet::embedded::node_config("/tmp/x".into(), "machine".into(), None, None);
    assert_eq!((plain.hostname.as_str(), plain.auth_key.is_none()), ("machine", true));
    assert!(plain.control_url.is_none() && plain.advertise_tags.is_empty());
}

#[tokio::test]
async fn a_join_while_signed_in_is_refused_without_switch_and_changes_nothing() {
    let temporary = private_tempdir();
    let dir = temporary.path().join("tailnet");
    private_dir(&dir);
    let state = br#"{"_current-profile":"MWEyYg==","MWEyYg==":"e30="}"#;
    std::fs::write(dir.join("tailscaled.state"), state).unwrap();
    let controller = Controller::new(&dir, "test");
    let mut p = params(HS_KEY);
    p.control_url = Some("https://other.example.com".into());
    let error = controller.join(p.plan().unwrap()).await.unwrap_err();
    assert!(error.contains("already signed in") && error.contains("--switch"), "{error}");
    assert_eq!(std::fs::read(dir.join("tailscaled.state")).unwrap(), state);
    assert!(read_profile(&dir).is_none());
    assert!(controller.seen_config.lock().unwrap().is_none(), "no node was made");
}

#[tokio::test]
async fn a_join_signs_in_with_the_key_once_and_never_writes_it() {
    let temporary = private_tempdir();
    let dir = temporary.path().join("tailnet");
    let controller = Controller::new(&dir, "test");
    *controller.node_factory.lock().unwrap() = Some(Box::new(|| Err("no network in tests".into())));
    let mut p = params(HS_KEY);
    p.control_url = Some("https://hs.example.com".into());
    p.hostname = Some("leo-mac".into());
    p.tags = vec!["tag:cmux".into()];
    let error = controller.join(p.plan().unwrap()).await.unwrap_err();
    assert_eq!(error, "no network in tests");
    {
        let seen = controller.seen_config.lock().unwrap();
        let seen = seen.as_ref().expect("the start built a config");
        assert_eq!(seen.auth_key.as_deref(), Some(HS_KEY));
        assert_eq!(seen.control_url.as_deref(), Some("https://hs.example.com"));
        assert_eq!(seen.hostname, "leo-mac");
        assert_eq!(seen.advertise_tags, ["tag:cmux"]);
    }
    assert!(!contains(&all_bytes(&dir), "SECRETVALUE"), "the key reached the state folder");
    assert_eq!(controller.join_profile().unwrap().hostname.as_deref(), Some("leo-mac"));

    // The next start (a relaunch's resume) uses the saved server and name, with no key.
    *controller.node_factory.lock().unwrap() = Some(Box::new(|| Err("again".into())));
    assert_eq!(controller.start().await.unwrap_err(), "again");
    let seen = controller.seen_config.lock().unwrap().clone().unwrap();
    assert!(seen.auth_key.is_none(), "the key signs in once");
    assert_eq!(seen.control_url.as_deref(), Some("https://hs.example.com"));
    controller.shutdown().await.unwrap();
}

#[tokio::test]
async fn leave_clears_the_identity_and_the_join() {
    let temporary = private_tempdir();
    let dir = temporary.path().join("tailnet");
    private_dir(&dir);
    std::fs::write(dir.join("tailscaled.state"), br#"{"_current-profile":"MWEyYg=="}"#).unwrap();
    std::fs::write(dir.join("enabled"), b"1\n").unwrap();
    write_profile(&dir, &JoinProfile { hostname: Some("mac".into()), ..JoinProfile::default() })
        .unwrap();
    let controller = Controller::new(&dir, "test");
    let snapshot = controller.logout().await.unwrap();
    assert_eq!(snapshot.state, "stopped");
    for name in ["tailscaled.state", "enabled", PROFILE_FILE] {
        assert!(!dir.join(name).exists(), "{name} survived leave");
    }
    assert!(controller.join_profile().is_none());
    assert!(!has_saved_login(&dir));
}

/// Live join against a throwaway Headscale (never a real tailnet): `testing/live-embedded-join.sh`
/// in cmux-tailnet-join runs this inside the harness's docker network. The key is read from the
/// file `CMUX_LIVE_KEY_FILE`; the node stays up `CMUX_LIVE_HOLD_S` seconds so the harness client
/// can see and ping it, then leaves.
#[tokio::test]
#[ignore = "needs a throwaway headscale; run by testing/live-embedded-join.sh"]
async fn live_join_against_a_throwaway_headscale() {
    let key = std::fs::read_to_string(std::env::var("CMUX_LIVE_KEY_FILE").unwrap()).unwrap();
    let server = std::env::var("CMUX_LIVE_SERVER").unwrap();
    let hold: u64 =
        std::env::var("CMUX_LIVE_HOLD_S").ok().and_then(|s| s.parse().ok()).unwrap_or(30);
    let temporary = private_tempdir();
    let dir = temporary.path().join("tailnet");
    let controller = Controller::new(&dir, "fallback");
    let mut p = params(key.trim());
    p.control_url = Some(server);
    p.allow_http = true;
    p.hostname = Some("cmux-embedded-live".into());
    let mut changes = controller.subscribe();
    let watch = tokio::spawn(async move {
        while let Ok(change) = changes.recv().await {
            println!("LIVE change: {}", change.to_json(false));
        }
    });
    let started = std::time::Instant::now();
    let joined = controller.join(p.plan().unwrap()).await;
    let took = started.elapsed();
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    watch.abort();
    let snapshot = joined.unwrap_or_else(|error| {
        panic!("join failed: {error}; now {}", controller.snapshot().to_json(false))
    });
    println!(
        "LIVE joined in {:.2}s: state={} dns={:?} ips={:?}",
        took.as_secs_f64(),
        snapshot.state,
        snapshot.dns_name,
        snapshot.ips
    );
    assert_eq!(snapshot.state, "running");
    assert!(!contains(&all_bytes(&dir), key.trim()), "the key reached the state folder");
    // A second join without switch is refused while signed in.
    let mut again = params(key.trim());
    again.control_url = Some("https://other.example.com".into());
    let refusal = controller.join(again.plan().unwrap()).await.unwrap_err();
    println!("LIVE second join refused: {refusal}");
    println!("LIVE READY");
    tokio::time::sleep(std::time::Duration::from_secs(hold)).await;
    let left = controller.logout().await.unwrap();
    println!("LIVE left: state={}", left.state);
    assert!(!dir.join("tailscaled.state").exists() && !dir.join(PROFILE_FILE).exists());
    controller.shutdown().await.unwrap();
}
