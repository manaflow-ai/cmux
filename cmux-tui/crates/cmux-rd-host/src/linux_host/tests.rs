use super::*;
use cmux_hub_host::b64;

/// `remove-device` sends one signed `DELETE /v1/devices/ID` for another device, and
/// refuses this host's own id and anything that is not an id, sending nothing for them.
#[test]
fn remove_device_deletes_another_device_only() {
    let (origin, seen) = stack_login::tests::stub(|_, request| match request.path.as_str() {
        "/v1/auth/device/anchor" => (200, serde_json::json!({ "anchoredUntil": now_ms() + 1_000 })),
        "/v1/auth/device" => {
            (200, serde_json::json!({ "session": "a", "expiresAt": now_ms() + 3_600_000 }))
        }
        _ => (200, serde_json::json!({})),
    });
    let device = Device::generate("host").unwrap();
    let own = device.id.clone();
    let hub = Hub::new(&origin, device, Some("p:a".into())).unwrap();
    let old = "19e85a2b-50c2-4a2a-ae16-f02a5b14a8e9";
    let deletes = || {
        seen.lock()
            .unwrap()
            .iter()
            .filter(|s| s.method == "DELETE")
            .map(|s| s.path.clone())
            .collect::<Vec<_>>()
    };
    for bad in [own.as_str(), &own.to_uppercase(), "", "../relays/x", "a/b", "a b"] {
        assert!(remove_device_on(&hub, bad).is_err(), "{bad:?}");
    }
    assert!(deletes().is_empty());
    remove_device_on(&hub, old).unwrap();
    assert_eq!(deletes(), vec![format!("/v1/devices/{old}")]);
    let signed = seen
        .lock()
        .unwrap()
        .iter()
        .any(|s| s.method == "DELETE" && s.headers.iter().any(|(k, _)| k == "authorization"));
    assert!(signed, "the remove carries the host's hub session");
    assert_eq!(run_cli(&["remove-device".into()]), 2);
}

#[test]
fn args_take_positionals_flags_and_values() {
    let a = Args::parse(&[
        "approve".into(),
        "s1".into(),
        "--always".into(),
        "--scope".into(),
        "view".into(),
    ])
    .unwrap();
    assert_eq!(a.positional, vec!["approve", "s1"]);
    assert!(a.flag("always"));
    assert_eq!(a.get("scope"), Some("view"));
    assert!(a.only(&["always", "scope"]).is_ok());
    assert!(a.only(&["always"]).is_err());
    assert!(Args::parse(&["--scope".into()]).is_err());
}

#[test]
fn enable_consents_to_control_unless_view_only() {
    // A desktop joined to the person's own account: their devices control it with no prompt here.
    let enable = |extra: &[&str]| {
        let words: Vec<String> =
            std::iter::once("enable").chain(extra.iter().copied()).map(String::from).collect();
        let args = Args::parse(&words).unwrap();
        assert!(args
            .only(&[
                "stack-token-file",
                "hub",
                "name",
                "allow-control",
                "view-only",
                "non-interactive"
            ])
            .is_ok());
        enable_consent(&args)
    };
    assert_eq!(enable(&[]), LocalConsent { view: true, full: true });
    assert_eq!(enable(&["--allow-control"]), LocalConsent { view: true, full: true });
    assert_eq!(enable(&["--view-only"]), LocalConsent { view: true, full: false });
}

/// A person's own `enable` on a joined machine would make the host theirs until the next
/// daemon start signs them out again: refused before any token is read, the join kept.
#[test]
fn a_person_cannot_sign_in_over_a_join() {
    let dir = consent_dir("person-over-join");
    let home = dir.join("acpmux-home");
    identity::private_dir(&home).unwrap();
    identity::write_private(
        &home.join(machine::CREDENTIAL_FILE),
        br#"{"credential":"cmm_b","name":"lane-vm"}"#,
    )
    .unwrap();
    Device::generate("lane-vm").unwrap().save(&dir).unwrap();
    Account { hub: DEFAULT_HUB.into(), user_id: "p:b".into(), anchored_until: 0 }
        .save(&dir)
        .unwrap();
    machine::Joined { acpmux_home: home.clone(), ..Default::default() }.save(&dir).unwrap();
    let token = dir.join("token");
    identity::write_private(&token, b"person-token").unwrap();
    let args =
        Args::parse(&["enable".into(), "--stack-token-file".into(), token.display().to_string()])
            .unwrap();
    let Err(e) = sign_in_and_register(&args, &dir) else { panic!("signed in over the join") };
    assert_eq!(e.to_string(), "this machine is joined to p:b; run `acpmux machine leave` first");
    assert_eq!(
        machine::Joined::load(&dir).unwrap(),
        Some(machine::Joined { acpmux_home: home.clone(), ..Default::default() })
    );
    assert_eq!(Account::load(&dir).unwrap().unwrap().user_id, "p:b");
    // After `acpmux machine leave` (the credential gone) a person may enable it again.
    std::fs::remove_file(home.join(machine::CREDENTIAL_FILE)).unwrap();
    assert_eq!(serving::join_owner(&dir).unwrap(), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_join_takes_no_account_token() {
    // No person's credential lands on a joined machine: a token on any flag is refused before
    // anything is read or written, and the join's command is otherwise never a failure.
    for path in ["-", "/tmp/token"] {
        let args = Args::parse(&[
            "enable".into(),
            "--non-interactive".into(),
            "--stack-token-file".into(),
            path.into(),
        ])
        .unwrap();
        let Err(e) = enable_for_join(&args) else { panic!("took a token") };
        assert!(e.to_string().contains("no account token"), "{e}");
    }
    assert!(NOT_INSTALLED.starts_with("not_installed: "));
}

#[test]
fn status_takes_json_and_never_fails() {
    // Whatever this machine has set up, `status --json` maps it to a state.
    assert_eq!(run_cli(&["status".into(), "--json".into()]), 0);
    assert_eq!(run_cli(&["status".into(), "--always".into()]), 1);
}

#[test]
fn unknown_commands_are_usage_errors() {
    assert_eq!(run_cli(&["frobnicate".into()]), 2);
    assert_eq!(run_cli(&[]), 2);
}

const UNIT: &str = include_str!("../../systemd/cmux-screen-host.service");

/// `[Service]` lines of the unit as (key, value), comments and blanks skipped.
fn unit_directives() -> Vec<(String, String)> {
    UNIT.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#') && !l.starts_with(';'))
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned()))
        .collect()
}

#[test]
fn user_unit_needs_no_user_namespace() {
    // In a user unit each of these makes systemd set up a user namespace (PrivateUsers),
    // which Ubuntu 24.04+ forbids unprivileged processes through AppArmor: the unit would
    // not start. PrivateTmp also hides an XAUTHORITY or X socket kept in /tmp.
    const NEEDS_USERNS: &[&str] = &[
        "PrivateUsers",
        "PrivateTmp",
        "PrivateDevices",
        "PrivateNetwork",
        "PrivateIPC",
        "PrivateMounts",
        "PrivatePIDs",
        "ProtectSystem",
        "ProtectHome",
        "ProtectKernelTunables",
        "ProtectKernelModules",
        "ProtectKernelLogs",
        "ProtectControlGroups",
        "ProtectClock",
        "ProtectHostname",
        "ProtectProc",
        "ProcSubset",
        "ReadOnlyPaths",
        "ReadWritePaths",
        "InaccessiblePaths",
        "ExecPaths",
        "NoExecPaths",
        "TemporaryFileSystem",
        "BindPaths",
        "BindReadOnlyPaths",
        "MountAPIVFS",
        "RootDirectory",
        "RootImage",
        "NetworkNamespacePath",
        "IPCNamespacePath",
    ];
    let directives = unit_directives();
    assert!(directives.iter().any(|(k, _)| k == "ExecStart"), "unit not parsed");
    for (key, value) in &directives {
        assert!(
            !NEEDS_USERNS.contains(&key.as_str()),
            "{key}={value} needs a user namespace in a user unit"
        );
    }
}

#[test]
fn fatal_hub_errors_stop_the_unit_with_a_next_step() {
    for (code, next) in [
        ("device_removed", "cmux-rd linux-host enable"),
        ("device_key_mismatch", "cmux-rd linux-host enable"),
        ("not_anchored", "cmux-rd linux-host share on"),
    ] {
        let e: Box<dyn std::error::Error + Send + Sync> =
            HubError { status: 403, code: code.into(), message: "m".into() }.into();
        let fatal = Fatal::from_hub(&*e).unwrap_or_else(|| panic!("{code} is not fatal"));
        assert!(fatal.to_string().contains(next), "{code}: {fatal}");
        let boxed: Box<dyn std::error::Error + Send + Sync> = fatal.into();
        assert_eq!(exit_code(&*boxed), EXIT_NEEDS_SETUP);
    }
    let transient: Box<dyn std::error::Error + Send + Sync> =
        HubError { status: 503, code: "unavailable".into(), message: "m".into() }.into();
    assert!(Fatal::from_hub(&*transient).is_none());
    assert_eq!(exit_code(&*transient), 1);
    assert_ne!(EXIT_NEEDS_SETUP, 1);
    assert_ne!(EXIT_NEEDS_SETUP, 2);
    // systemd must not restart it: the code is in RestartPreventExitStatus=.
    let prevented: Vec<String> = unit_directives()
        .into_iter()
        .filter(|(k, _)| k == "RestartPreventExitStatus")
        .flat_map(|(_, v)| v.split_whitespace().map(str::to_owned).collect::<Vec<_>>())
        .collect();
    assert!(
        prevented.contains(&EXIT_NEEDS_SETUP.to_string()),
        "RestartPreventExitStatus= lacks {EXIT_NEEDS_SETUP}: {prevented:?}"
    );
}

fn request(name: &str, fingerprint: Option<&str>) -> consent::Request {
    consent::Request {
        id: "s1".into(),
        viewer_id: "v1".into(),
        viewer_name: name.into(),
        viewer_key_fingerprint: fingerprint.map(str::to_owned),
        scope: "view".into(),
        received_ms: 0,
    }
}

#[test]
fn request_lines_are_printed_without_control_characters() {
    use cmux_hub_host::text::is_bidi_control;
    let hostile = "\u{1b}[2J\u{202e}Mallory\nlinux-host: approved";
    for line in [request_line(&request(hostile, None)), ask_line(&request(hostile, None))] {
        assert!(!line.chars().any(|c| c.is_control() || is_bidi_control(c)), "{line:?}");
        assert!(line.contains("Mallorylinux-host: approved"), "{line:?}");
    }
}

/// A `Current` serving session `s1` with `scope`, and its stop flag.
fn serving(scope: &str) -> (Current, Arc<AtomicBool>) {
    let stop = Arc::new(AtomicBool::new(false));
    let served = Served { id: "s1".into(), scope: scope.into(), stop: stop.clone() };
    (Arc::new(Mutex::new(Some(served))), stop)
}

fn is_empty(current: &Current) -> bool {
    current.lock().unwrap().is_none()
}

#[test]
fn a_dropped_hub_link_stops_the_session_it_served() {
    // Revocations sent while the link is down are never replayed: fail closed.
    let (current, stop) = serving("full");
    let held = stop.clone();
    let (result, stopped) = hold_link(&current, || {
        assert!(!held.load(Ordering::SeqCst), "stopped while the link was up");
        Err("socket closed (1006 connection closed)".into())
    });
    assert!(result.is_err());
    assert_eq!(stopped.as_deref(), Some("s1"));
    assert!(stop.load(Ordering::SeqCst));
    assert!(is_empty(&current));
    // A link the hub closed cleanly too.
    let (current, stop) = serving("view");
    let (result, stopped) = hold_link(&current, || Ok(()));
    assert!(result.is_ok());
    assert_eq!(stopped.as_deref(), Some("s1"));
    assert!(stop.load(Ordering::SeqCst));
    // Nothing served, nothing stopped.
    let current: Current = Arc::new(Mutex::new(None));
    assert_eq!(hold_link(&current, || Ok(())).1, None);
}

fn consent_dir(tag: &str) -> std::path::PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-screen-host-consent-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

/// `enable` finds the encoder a session needs: an installed copy is used as it is, with no
/// download. The directory is passed in, not set as `XDG_DATA_HOME`: `set_var` would race
/// the other tests' reads of the environment.
#[cfg(feature = "openh264")]
#[test]
fn enable_finds_an_installed_openh264() {
    let platform = cmux_encode::openh264::Platform::current().unwrap();
    let data = consent_dir("openh264");
    let dir = cmux_encode::cisco::dir_from("linux", |key| {
        (key == "XDG_DATA_HOME").then(|| data.clone().into_os_string())
    })
    .unwrap();
    std::fs::create_dir_all(&dir).unwrap();
    let lib = cmux_encode::cisco::library_path(&dir, platform);
    std::fs::write(&lib, b"stand-in").unwrap();
    assert_eq!(openh264_line_in(Some(dir)), format!("OpenH264 is at {}", lib.display()));
    std::fs::remove_dir_all(&data).unwrap();
}

#[test]
fn consent_is_read_again_for_each_ticket() {
    let dir = consent_dir("admit");
    LocalConsent { view: true, full: true }.save(&dir).unwrap();
    assert_eq!(admit(&dir, "full", true), Some(false));
    // `enable --view-only`, the host still running.
    LocalConsent { view: true, full: false }.save(&dir).unwrap();
    assert_eq!(admit(&dir, "full", true), None);
    assert_eq!(admit(&dir, "view", true), Some(true));
    // A consent file it cannot trust admits nothing.
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(dir.join("consent.json"), std::fs::Permissions::from_mode(0o644))
        .unwrap();
    assert_eq!(admit(&dir, "view", true), None);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn withdrawn_consent_stops_the_session_it_no_longer_allows() {
    let both = LocalConsent { view: true, full: true };
    let view_only = LocalConsent { view: true, full: false };
    let (current, stop) = serving("full");
    assert_eq!(withdraw_unconsented(&current, Ok(both), true), None);
    assert!(!stop.load(Ordering::SeqCst));
    assert_eq!(withdraw_unconsented(&current, Ok(view_only), true).as_deref(), Some("s1"));
    assert!(stop.load(Ordering::SeqCst));
    assert!(is_empty(&current));
    // A view session goes on under view-only consent.
    let (current, stop) = serving("view");
    assert_eq!(withdraw_unconsented(&current, Ok(view_only), true), None);
    assert!(!stop.load(Ordering::SeqCst));
    // An unreadable consent file stops it.
    assert_eq!(
        withdraw_unconsented(&current, Err("consent.json: bad mode".into()), true).as_deref(),
        Some("s1")
    );
    assert!(stop.load(Ordering::SeqCst));
    let current: Current = Arc::new(Mutex::new(None));
    assert_eq!(withdraw_unconsented(&current, Ok(view_only), true), None);
}

#[test]
fn fingerprints_are_cut_on_a_character_boundary() {
    // 15 ASCII bytes then a 3-byte character across the 16-byte mark.
    let fp = "0123456789abcde\u{20ac}\u{20ac}tail";
    let line = request_line(&request("Ann", Some(fp)));
    assert!(line.contains("(key 0123456789abcde\u{20ac})"), "{line}");
    let line = request_line(&request("Ann", Some("\u{1b}[31m\u{e9}")));
    assert!(line.contains("(key \u{e9})"), "{line}");
    assert!(request_line(&request("Ann", None)).contains("(key -)"));
}

#[test]
fn a_deleted_consent_file_admits_nothing_and_stops_the_view_session() {
    let dir = consent_dir("deleted");
    LocalConsent { view: true, full: false }.save(&dir).unwrap();
    let (current, stop) = serving("view");
    assert_eq!(withdraw_unconsented(&current, LocalConsent::load(&dir), true), None);
    std::fs::remove_file(dir.join("consent.json")).unwrap();
    assert_eq!(admit(&dir, "view", true), None);
    assert_eq!(
        withdraw_unconsented(&current, LocalConsent::load(&dir), true).as_deref(),
        Some("s1")
    );
    assert!(stop.load(Ordering::SeqCst));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_portal_host_serves_view_only_and_says_so() {
    let dir = consent_dir("portal");
    LocalConsent { view: true, full: true }.save(&dir).unwrap();
    // The portal capture applies no input: a control ticket is served view only.
    assert_eq!(admit(&dir, "full", false), Some(true));
    assert_eq!(admit(&dir, "full", true), Some(false));
    let all = LocalConsent::load(&dir);
    assert_eq!(shares_line(&all, true), "view and control");
    let line = shares_line(&all, false);
    assert!(line.starts_with("view only") && line.contains("portal"), "{line}");
    std::fs::remove_dir_all(&dir).unwrap();
}

fn hub_refusal(code: &str) -> Box<dyn std::error::Error + Send + Sync> {
    HubError { status: 403, code: code.into(), message: "m".into() }.into()
}

#[test]
fn enable_mints_a_new_identity_when_the_hub_refuses_this_one() {
    // The hub never registers a removed id again: `enable` must not reuse it.
    for code in ["device_removed", "device_key_mismatch"] {
        let old = Device::generate("desk").unwrap();
        let old_id = old.id.clone();
        let mut tried = Vec::new();
        let (device, ()) = with_fresh_identity(old, |d| {
            tried.push(d.id.clone());
            if d.id == old_id {
                Err(hub_refusal(code))
            } else {
                Ok(())
            }
        })
        .unwrap_or_else(|e| panic!("{code}: {e}"));
        assert_ne!(device.id, old_id, "{code}");
        assert_eq!(device.name, "desk");
        assert_eq!(tried, vec![old_id, device.id.clone()], "{code}");
    }
    // Any other error is returned as it is, with no new identity.
    let mut tries = 0;
    let result = with_fresh_identity(Device::generate("desk").unwrap(), |_| -> Res<()> {
        tries += 1;
        Err(hub_refusal("unavailable"))
    });
    assert!(result.is_err());
    assert_eq!(tries, 1);
    // A new identity refused too is not replaced again.
    let mut tries = 0;
    let result = with_fresh_identity(Device::generate("desk").unwrap(), |_| -> Res<()> {
        tries += 1;
        Err(hub_refusal("device_removed"))
    });
    assert!(result.is_err());
    assert_eq!(tries, 2);
}

#[test]
fn a_joined_machine_signs_itself_in_registers_and_turns_sharing_on() {
    use super::stack_login::tests::stub;
    let (origin, seen) = stub(|_, request| match request.path.as_str() {
        "/v1/auth/machine" => (
            200,
            serde_json::json!({ "session": "s", "userId": "p:u", "expiresAt": now_ms() + 3_600_000 }),
        ),
        _ => (200, serde_json::json!({ "ok": true })),
    });
    let dir = consent_dir("machine-sign-in");
    identity::private_dir(&dir).unwrap();
    let credential: machine::MachineCredential =
        serde_json::from_str(r#"{"credential":"cmm_x","name":"lane-vm"}"#).unwrap();
    let join = machine::Join::at(std::path::Path::new("/acpmux-home"), credential, &origin);
    let (hub, account) = sign_in_machine(&dir, &join, None).unwrap();
    assert_eq!(hub.device.name, "lane-vm", "named as the join named the machine");
    assert_eq!(account, Account { hub: origin.clone(), user_id: "p:u".into(), anchored_until: 0 });
    assert_eq!(Account::load(&dir).unwrap(), Some(account));
    assert_eq!(
        machine::Joined::load(&dir).unwrap(),
        Some(machine::Joined {
            acpmux_home: "/acpmux-home".into(),
            consent_tracked: true,
            ..Default::default()
        }),
        "a first sign-in by this build tracks its join's consent"
    );
    machine::Joined::clear(&dir).unwrap();
    assert_eq!(machine::Joined::load(&dir).unwrap(), None);
    machine::Joined::clear(&dir).unwrap();
    assert_eq!(Device::load(&dir).unwrap().unwrap().id, hub.device.id);
    let seen = seen.lock().unwrap().clone();
    let calls: Vec<(String, String)> =
        seen.iter().map(|s| (s.method.clone(), s.path.clone())).collect();
    let screen = format!("/v1/devices/{}/mac-screen", hub.device.id);
    assert_eq!(
        calls,
        [
            ("POST".to_owned(), "/v1/auth/machine".to_owned()),
            ("POST".to_owned(), "/v1/devices".to_owned()),
            ("PUT".to_owned(), screen),
        ]
    );
    // Registered as a Linux desktop, and joining is the consent: sharing on.
    assert_eq!(serde_json::from_str::<Value>(&seen[1].body).unwrap()["platform"], "linux");
    assert_eq!(serde_json::from_str::<Value>(&seen[2].body).unwrap()["shared"], true);
    let _ = std::fs::remove_dir_all(&dir);
}

/// With no join, a person's anchored sign-in is the host's, and nothing is not signed in.
#[test]
fn without_a_join_an_anchored_account_stays() {
    let dir = consent_dir("no-join");
    identity::private_dir(&dir).unwrap();
    assert!(join_device(&dir, Some("http://127.0.0.1:1"), None, &NoUnit).unwrap().is_none());
    let old = Device::generate("desk").unwrap();
    old.save(&dir).unwrap();
    let hub = "http://127.0.0.1:1".to_owned();
    Account { hub, user_id: "p:a".into(), anchored_until: now_ms() + 60_000 }.save(&dir).unwrap();
    let kept = join_device(&dir, Some("http://127.0.0.1:1"), None, &NoUnit).unwrap().unwrap();
    assert_eq!(kept.id, old.id);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review F2 of #45480: the machine left and joined again under another deployment while
/// the acpmux daemon kept the first join's device hub. The credential on disk is the new
/// deployment's, so it is never sent to the earlier deployment's hub, and nothing is set
/// up for it there.
#[test]
fn a_rejoin_under_another_deployment_never_signs_in_at_the_earlier_hub() {
    use super::stack_login::tests::stub;
    let (earlier_hub, seen) = stub(|_, _| {
        (
            200,
            serde_json::json!({ "session": "s", "userId": "p:u", "expiresAt": now_ms() + 3_600_000 }),
        )
    });
    let dir = consent_dir("rejoin-other-deployment");
    identity::private_dir(&dir).unwrap();
    let credential: machine::MachineCredential = serde_json::from_str(
        r#"{"credential":"cmm_new","name":"vm","machine_id":"m-new","credential_generation":1,"hub_origin":"https://cmux-platform-production.debussy.workers.dev"}"#,
    )
    .unwrap();
    let home = dir.join("acpmux-home");
    let got = join_device(&dir, Some(&earlier_hub), Some((home, credential)), &NoUnit);
    assert!(got.is_err(), "a hub that is not the credential's own deployment's is refused");
    let calls: Vec<String> = seen.lock().unwrap().iter().map(|s| s.path.clone()).collect();
    assert!(calls.is_empty(), "the earlier deployment's hub saw {calls:?}");
    assert_eq!(Account::load(&dir).unwrap(), None, "nothing is signed in");
    assert_eq!(machine::Joined::load(&dir).unwrap(), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_virtual_display_stops_only_after_ten_idle_minutes() {
    let start = Instant::now();
    let mut last_busy = start;
    assert!(!display_idle(false, &mut last_busy, start + Duration::from_secs(9 * 60)));
    // A share or an app on it keeps it up, and the idle time starts again.
    assert!(!display_idle(true, &mut last_busy, start + Duration::from_secs(9 * 60)));
    assert!(!display_idle(false, &mut last_busy, start + Duration::from_secs(18 * 60)));
    assert!(display_idle(false, &mut last_busy, start + Duration::from_secs(19 * 60)));
}

fn ticket_push(sid_in_jws: &str) -> Value {
    let claims = serde_json::json!({"sid": sid_in_jws, "role": "host", "peerKey": "KEY"});
    let payload = b64::encode(claims.to_string().as_bytes())
        .trim_end_matches('=')
        .replace('+', "-")
        .replace('/', "_");
    serde_json::json!({
        "type": "session.ticket", "sessionId": "s1", "role": "host", "scope": "full",
        "ticket": format!("eyJhbGciOiJFUzI1NiJ9.{payload}.c2ln"),
        "signalURL": "wss://hub.example/v1/sessions/s1/ws", "ice": [],
        "peer": {"id": "v1", "name": "Mac", "signingKey": "KEY"}
    })
}

#[test]
fn a_refused_host_ticket_ends_its_session() {
    assert!(matches!(on_ticket(&ticket_push("s1"), |_| Some(true)), OnTicket::Serve(_, true)));
    assert!(matches!(
        on_ticket(&ticket_push("s1"), |_| None),
        OnTicket::End(id, "consent_required", _) if id == "s1"
    ));
    // A ticket that does not agree with its JWS is ended too, as the Mac host does: the
    // approved session would otherwise stay open on the hub.
    let mut malformed = ticket_push("s2");
    assert!(matches!(
        on_ticket(&malformed, |_| Some(true)),
        OnTicket::End(id, "failed", _) if id == "s1"
    ));
    malformed["ticket"] = "not a jws".into();
    assert!(matches!(
        on_ticket(&malformed, |_| Some(true)),
        OnTicket::End(id, "failed", _) if id == "s1"
    ));
    // With no session id there is nothing to end.
    malformed["sessionId"] = Value::Null;
    assert!(matches!(on_ticket(&malformed, |_| Some(true)), OnTicket::Drop(_)));
}

/// The person's own device (`ownerKind: "user"`) gets the screen on a desktop enabled
/// `--view-only`: its control ticket serves view only, watched as a `view` session, where
/// another device's is ended `consent_required`. Nothing serves what the desktop refuses.
#[test]
fn an_own_device_control_ticket_serves_view_only_on_a_view_only_desktop() {
    let view_only = LocalConsent { view: true, full: false };
    let admit = |scope: &str| view_only.serve(scope, true);
    let mut own = ticket_push("s1");
    own["ownerKind"] = "user".into();
    match on_ticket(&own, admit) {
        OnTicket::Serve(ticket, true) => {
            assert_eq!(ticket.scope, "view");
            let current: Current = Arc::new(Mutex::new(Some(Served {
                id: ticket.session_id,
                scope: ticket.scope,
                stop: Arc::new(AtomicBool::new(false)),
            })));
            // The view-only consent it was served under does not withdraw it a second later.
            assert_eq!(withdraw_unconsented(&current, Ok(view_only), true), None);
        }
        other => panic!("own device not served view only: {other:?}"),
    }
    for kind in [Value::Null, "team".into(), "shared".into()] {
        let mut push = ticket_push("s1");
        push["ownerKind"] = kind;
        assert!(matches!(
            on_ticket(&push, admit),
            OnTicket::End(id, "consent_required", _) if id == "s1"
        ));
    }
    // A desktop that allows control serves it as asked; one whose consent is unreadable
    // (`admit` None for every scope) serves nothing, own device or not.
    let both = LocalConsent { view: true, full: true };
    assert!(matches!(
        on_ticket(&own, |s| both.serve(s, true)),
        OnTicket::Serve(t, false) if t.scope == "full"
    ));
    assert!(matches!(on_ticket(&own, |_| None), OnTicket::End(_, "consent_required", _)));
}

#[test]
fn approve_and_status_read_the_capture_the_host_recorded() {
    let dir = consent_dir("capture");
    identity::write_private(&dir.join("capture"), CaptureBackend::Portal.name().as_bytes())
        .unwrap();
    assert_eq!(host_capture(Some(&dir)), CaptureBackend::Portal);
    assert!(!host_capture(Some(&dir)).applies_input_with(false));
    identity::write_private(&dir.join("capture"), b"x11").unwrap();
    assert_eq!(host_capture(Some(&dir)), CaptureBackend::X11);
    std::fs::remove_dir_all(&dir).unwrap();
}

/// On GNOME the join's grant step asks nothing and says shares need no grant; elsewhere
/// the portal grant runs as before.
#[test]
fn a_gnome_join_asks_nothing_and_says_shares_need_no_grant() {
    use crate::capture_backend::WaylandCapture;
    assert_eq!(mutter_line(WaylandCapture::Portal, true, true), None);
    let line = mutter_line(WaylandCapture::Mutter, true, true).unwrap();
    assert!(line.starts_with(MUTTER_LINE_START));
    assert!(line.contains("view and control"));
    assert!(line.contains("needs no approval") && line.contains("no dialog appears"));
    assert!(!line.contains("mutter"));
    let view = mutter_line(WaylandCapture::Mutter, false, true).unwrap();
    assert!(view.contains("view only") && !view.contains("mutter"));
    let plain = mutter_line(WaylandCapture::Mutter, false, false).unwrap();
    assert!(plain.starts_with(&format!("{MUTTER_LINE_START}:")));
}
