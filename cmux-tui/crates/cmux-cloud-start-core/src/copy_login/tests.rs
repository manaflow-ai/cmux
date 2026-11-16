//! The login copy's cases, one test each, against the app's `CloudCredentialTransfer` (its
//! `CloudCredentialTransferTests` cases), `CloudCredentialInstaller`, `CloudCredentialLogin` and
//! `CloudLoginCopyGate`. A fake app answers each effect the way the case needs.

use super::*;

const TOKEN: &[u8] = b"sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789";
const STAGING: &str = "7C0F6B2E-1F4B-4E8E-9A54-2A8C3D1E5F60";
const PATH: &str = "/home/cmux/.cmux/credential-transfer/7C0F6B2E-1F4B-4E8E-9A54-2A8C3D1E5F60.json";

fn copy(provider: Provider) -> Request {
    Request {
        provider,
        machine_id: "vm-1".into(),
        team_id: Some("team-1".into()),
        user_id: "user-1".into(),
        confirmed: true,
        refresh: false,
        creator_team_guest: false,
        guest_checked: None,
        staging_id: STAGING.into(),
    }
}

fn scope() -> Scope {
    Scope { team_id: Some("team-1".into()), user_id: Some("user-1".into()) }
}

fn codex_auth() -> Vec<u8> {
    br#"{"OPENAI_API_KEY":null,"tokens":{"access_token":"a","refresh_token":"r","id_token":"i"}}"#
        .to_vec()
}

/// A fake app: answers each effect with `answer`, advancing its clock by `cost` per effect, until
/// the copy finishes. Records every effect it ran.
struct App {
    state: State,
    now: u64,
    scope: Scope,
    ran: Vec<Effect>,
}

impl App {
    fn new() -> Self {
        App { state: State::default(), now: 1_000, scope: scope(), ran: Vec::new() }
    }

    fn send(&mut self, event: Event) -> Vec<Effect> {
        let answer = step(std::mem::take(&mut self.state), event, self.now, &self.scope);
        self.state = answer.state;
        self.ran.extend(answer.effects.iter().cloned());
        answer.effects
    }

    /// Runs `copy` to its end; `answer` gives each asking effect's event (None: the app sends
    /// nothing more and the test goes on by hand).
    fn run(
        &mut self,
        copy: Request,
        mut answer: impl FnMut(&mut App, &Effect) -> Option<Event>,
    ) -> Option<End> {
        let mut pending = self.send(Event::Begin { copy });
        loop {
            let mut next = None;
            for effect in pending.drain(..) {
                if let Effect::Finish { end, .. } = &effect {
                    return Some(end.clone());
                }
                if matches!(effect, Effect::Mark { .. }) {
                    continue;
                }
                next = answer(self, &effect);
            }
            let event = next?;
            pending = self.send(event);
        }
    }

    fn execs(&self) -> Vec<String> {
        self.ran
            .iter()
            .filter_map(|e| match e {
                Effect::Exec { command, .. } => Some(command.clone()),
                _ => None,
            })
            .collect()
    }

    fn marks(&self) -> Vec<String> {
        self.ran
            .iter()
            .filter_map(|e| match e {
                Effect::Mark { name } => Some(name.clone()),
                _ => None,
            })
            .collect()
    }

    fn did(&self, pred: impl Fn(&Effect) -> bool) -> bool {
        self.ran.iter().any(pred)
    }
}

/// The happy app: owns the machine, a bound owner guest, a cached Claude login, allowed, written,
/// installed.
fn happy(app: &mut App, effect: &Effect) -> Option<Event> {
    app.now += 10;
    Some(match effect {
        Effect::CallerOwns => Event::Owns { owns: true },
        Effect::Exec { .. } => Event::Exec { exit: 0 },
        Effect::Pause { .. } => Event::Paused,
        Effect::Load { .. } => Event::Loaded { credential: Some(TOKEN.to_vec()) },
        Effect::Acquire { provider: Provider::Claude, .. } => {
            Event::Acquired { credential: TOKEN.to_vec() }
        }
        Effect::Acquire { provider: Provider::Codex, .. } => {
            Event::Acquired { credential: codex_auth() }
        }
        Effect::Store { .. } => Event::Stored,
        Effect::StillAllowed => Event::Allowed { allowed: true },
        Effect::Write { .. } => Event::Written,
        Effect::Mark { .. } | Effect::Finish { .. } => return None,
    })
}

fn failed(failure: Failure) -> Option<End> {
    Some(End::Failed { failure })
}

// Preflight ---------------------------------------------------------------------------------

#[test]
fn preflight_a_cached_login_is_checked_written_and_installed_in_the_apps_order() {
    let mut app = App::new();
    assert_eq!(app.run(copy(Provider::Claude), happy), Some(End::Installed));
    let order: Vec<&str> = app
        .ran
        .iter()
        .map(|e| match e {
            Effect::CallerOwns => "owns",
            Effect::Exec { command, .. } if command == scripts::PREFLIGHT => "preflight",
            Effect::Exec { command, .. } if command.contains("CMUX_CREDENTIAL_INSTALL") => {
                "install"
            }
            Effect::Exec { .. } => "exec",
            Effect::Load { .. } => "load",
            Effect::StillAllowed => "allowed",
            Effect::Write { .. } => "write",
            Effect::Mark { .. } => "mark",
            Effect::Finish { .. } => "finish",
            _ => "other",
        })
        .filter(|s| *s != "mark")
        .collect();
    // A cached login read at once is delivered on the first guest check: no second preflight.
    assert_eq!(
        order,
        ["owns", "preflight", "load", "owns", "allowed", "write", "install", "finish"]
    );
    assert_eq!(
        app.marks(),
        [
            "transfer.guest",
            "transfer.load",
            "transfer.recheck",
            "transfer.write",
            "transfer.install"
        ]
    );
}

#[test]
fn preflight_the_starts_own_recent_guest_check_stands_in_for_the_first() {
    let mut app = App::new();
    let mut c = copy(Provider::Claude);
    c.guest_checked =
        Some(GuestCheck { machine_id: "vm-1".into(), team_id: Some("team-1".into()), at: 900 });
    assert_eq!(app.run(c, happy), Some(End::Installed));
    assert!(!app.execs().iter().any(|e| e == scripts::PREFLIGHT), "{:?}", app.execs());
}

#[test]
fn preflight_another_machines_team_or_an_old_check_is_checked_again() {
    for (machine, team, at) in [
        ("vm-2", Some("team-1"), 2_990),
        ("vm-1", Some("team-2"), 2_990),
        ("vm-1", None, 2_990),
        ("vm-1", Some("team-1"), 0),
    ] {
        let mut app = App::new();
        app.now = 3_000;
        let mut c = copy(Provider::Claude);
        c.guest_checked =
            Some(GuestCheck { machine_id: machine.into(), team_id: team.map(Into::into), at });
        assert_eq!(app.run(c, happy), Some(End::Installed));
        assert_eq!(
            app.execs().iter().filter(|e| *e == scripts::PREFLIGHT).count(),
            1,
            "{machine} {team:?} {at}"
        );
    }
}

#[test]
fn preflight_the_creator_allowance_never_takes_the_starts_check_and_runs_its_own_preflight() {
    let mut app = App::new();
    let mut c = copy(Provider::Claude);
    c.creator_team_guest = true;
    c.guest_checked =
        Some(GuestCheck { machine_id: "vm-1".into(), team_id: Some("team-1".into()), at: 1_000 });
    assert_eq!(app.run(c, happy), Some(End::Installed));
    let execs = app.execs();
    assert_eq!(execs[0], scripts::CREATOR_TEAM_PREFLIGHT);
    assert!(
        execs
            .iter()
            .any(|e| e.contains("python3 - 'claude' '") && e.contains(" owner,team 'user-1' <<"))
    );
}

#[test]
fn preflight_a_machine_the_platform_says_is_not_the_callers_gets_nothing() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::CallerOwns => Some(Event::Owns { owns: false }),
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::SharedMachine));
    assert!(app.execs().is_empty() && !app.did(|e| matches!(e, Effect::Load { .. })));
}

#[test]
fn preflight_ownership_lost_before_the_write_stops_the_copy() {
    let mut app = App::new();
    let mut asked = 0;
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::CallerOwns => {
            asked += 1;
            Some(Event::Owns { owns: asked == 1 })
        }
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::SharedMachine));
    assert!(!app.did(|e| matches!(e, Effect::Write { .. })));
}

#[test]
fn preflight_a_team_guest_or_old_image_is_refused_at_once() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        // The preflight fails and the kind record exists: the guest's answer.
        Effect::Exec { .. } => Some(Event::Exec { exit: 1 }),
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::SharedMachine));
    assert_eq!(app.execs(), [scripts::PREFLIGHT.to_owned(), KIND_MISSING.to_owned()]);
}

#[test]
fn preflight_an_unbound_guest_is_checked_again_until_it_binds() {
    let mut app = App::new();
    let mut preflights = 0;
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::Exec { command, cutoff_ms, .. }
            if command == scripts::PREFLIGHT && cutoff_ms.is_some() =>
        {
            preflights += 1;
            app.now += 500;
            Some(Event::Exec { exit: if preflights < 4 { 1 } else { 0 } })
        }
        Effect::Exec { command, .. } if command == KIND_MISSING => Some(Event::Exec { exit: 0 }),
        Effect::Pause { min_ms, max_ms, .. } => {
            assert_eq!((*min_ms, *max_ms), (2_400, 3_000));
            app.now += 3_000;
            Some(Event::Paused)
        }
        _ => happy(app, e),
    });
    assert_eq!(end, Some(End::Installed));
    assert_eq!(preflights, 4);
    assert_eq!(app.ran.iter().filter(|e| matches!(e, Effect::Pause { .. })).count(), 3);
}

// Timeouts -----------------------------------------------------------------------------------

#[test]
fn timeouts_a_guest_that_never_binds_is_not_ready_after_thirty_tries() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::Exec { command, .. } if command == scripts::PREFLIGHT => {
            Some(Event::Exec { exit: 1 })
        }
        Effect::Exec { .. } => Some(Event::Exec { exit: 0 }),
        Effect::Pause { .. } => Some(Event::Paused),
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::MachineNotReady));
    assert_eq!(app.execs().iter().filter(|e| *e == scripts::PREFLIGHT).count(), 30);
    // No pause after the last try.
    assert_eq!(app.ran.iter().filter(|e| matches!(e, Effect::Pause { .. })).count(), 29);
}

#[test]
fn timeouts_the_guest_wait_stops_at_its_90_second_budget_slow_execs_included() {
    let mut app = App::new();
    let mut cut = false;
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::Exec { command, cutoff_ms, timeout_ms } => {
            assert_eq!(*timeout_ms, 20_000);
            let cutoff = cutoff_ms.expect("every guest exec carries the budget left");
            assert!(cutoff <= 90_000);
            // Each exec takes 20 s: one runs into the budget and is cut off.
            if cutoff < 20_000 {
                cut = true;
                app.now += cutoff;
                return Some(Event::Cutoff);
            }
            app.now += 20_000;
            Some(Event::Exec { exit: if command == scripts::PREFLIGHT { 1 } else { 0 } })
        }
        Effect::Pause { cutoff_ms, .. } => {
            if *cutoff_ms < 3_000 {
                cut = true;
                app.now += cutoff_ms;
                return Some(Event::Cutoff);
            }
            app.now += 3_000;
            Some(Event::Paused)
        }
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::MachineNotReady));
    assert!(cut);
    // Well before thirty tries: the budget, not the count, ended it.
    assert!(app.execs().iter().filter(|e| *e == scripts::PREFLIGHT).count() < 5);
}

#[test]
fn timeouts_a_pause_cut_by_the_budget_ends_the_wait() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::Exec { command, .. } if command == scripts::PREFLIGHT => {
            app.now += 44_000;
            Some(Event::Exec { exit: 1 })
        }
        Effect::Exec { .. } => {
            app.now += 44_000;
            Some(Event::Exec { exit: 0 })
        }
        Effect::Pause { cutoff_ms, .. } => {
            assert_eq!(*cutoff_ms, 2_000);
            Some(Event::Cutoff)
        }
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::MachineNotReady));
}

#[test]
fn timeouts_every_effect_carries_the_apps_bounds() {
    let mut app = App::new();
    let mut c = copy(Provider::Claude);
    c.refresh = true;
    app.run(c, happy);
    assert!(app.did(|e| matches!(e, Effect::Acquire { timeout_ms: 300_000, .. })));
    assert!(app.did(|e| matches!(e, Effect::Store { timeout_ms: 70_000 })));
    let mut app = App::new();
    app.run(copy(Provider::Claude), happy);
    assert!(app.did(|e| matches!(e, Effect::Load { timeout_ms: 30_000, .. })));
    assert!(
        app.ran
            .iter()
            .all(|e| !matches!(e, Effect::Exec { timeout_ms, .. } if *timeout_ms != 20_000))
    );
    assert_eq!(
        (GUEST_CHECK_TRIES, GUEST_CHECK_BUDGET_MS, crate::sequence::RECHECK_AFTER_MS),
        (30, 90_000, 2_000)
    );
}

#[test]
fn timeouts_a_slow_keychain_read_checks_the_guest_again_before_the_write() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::Load { .. } => {
            app.now += 2_001;
            Some(Event::Loaded { credential: Some(TOKEN.to_vec()) })
        }
        _ => happy(app, e),
    });
    assert_eq!(end, Some(End::Installed));
    assert_eq!(app.execs().iter().filter(|e| *e == scripts::PREFLIGHT).count(), 2);
}

#[test]
fn timeouts_a_failed_recheck_is_the_guests_refusal() {
    let mut app = App::new();
    let mut preflights = 0;
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::Load { .. } => {
            app.now += 5_000;
            Some(Event::Loaded { credential: Some(TOKEN.to_vec()) })
        }
        Effect::Exec { command, .. } if command == scripts::PREFLIGHT => {
            preflights += 1;
            Some(Event::Exec { exit: if preflights == 1 { 0 } else { 1 } })
        }
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::SharedMachine));
    assert!(!app.did(|e| matches!(e, Effect::Write { .. })));
}

// Consent ------------------------------------------------------------------------------------

#[test]
fn consent_an_unconfirmed_copy_does_nothing() {
    let mut app = App::new();
    let mut c = copy(Provider::Claude);
    c.confirmed = false;
    assert_eq!(app.run(c, happy), failed(Failure::ConsentRequired));
    assert_eq!(app.ran.len(), 1);
}

#[test]
fn consent_taken_back_or_the_switch_turned_off_before_the_write_stops_the_copy() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::StillAllowed => Some(Event::Allowed { allowed: false }),
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::CopyTurnedOff));
    assert!(!app.did(|e| matches!(e, Effect::Write { .. })));
}

#[test]
fn consent_the_release_gate_reads_the_switch_and_the_kept_answer() {
    use gate::*;
    assert!(still_allowed(true, None, None));
    assert!(still_allowed(false, Some(true), Some(true)));
    for (switch, consent) in [
        (None, Some(true)),
        (Some(false), Some(true)),
        (Some(true), None),
        (Some(true), Some(false)),
    ] {
        assert!(!still_allowed(false, switch, consent), "{switch:?} {consent:?}");
    }
    assert_eq!(copy_allowed(true, None, None), Verdict::Allowed);
    assert_eq!(copy_allowed(false, Some(false), Some(true)), Verdict::Refused);
    assert_eq!(copy_allowed(false, Some(true), None), Verdict::Ask);
    assert_eq!(copy_allowed(false, Some(true), Some(false)), Verdict::Refused);
    assert_eq!(copy_allowed(false, Some(true), Some(true)), Verdict::Allowed);
    assert_eq!(recovery_allowed(true, false, true, None, None), Verdict::Allowed);
    assert_eq!(recovery_allowed(false, false, false, Some(true), Some(true)), Verdict::Refused);
    assert_eq!(recovery_allowed(false, true, true, Some(true), None), Verdict::Refused);
    assert_eq!(recovery_allowed(false, true, true, Some(true), Some(true)), Verdict::Allowed);
    assert_eq!(recovery_allowed(false, true, false, Some(true), None), Verdict::Ask);
    assert!(offers_login_copy(false, false, None) && !offers_login_copy(false, true, Some(false)));
    assert!(offers_login_copy(true, true, Some(false)) && !offers_login_copy(true, false, None));
    assert!(dogfood_only(true, true) && !dogfood_only(false, true) && !dogfood_only(true, false));
}

// fs/write -----------------------------------------------------------------------------------

#[test]
fn fs_write_the_login_is_staged_0644_in_cmuxs_own_folder_under_the_apps_random_name() {
    let mut app = App::new();
    app.run(copy(Provider::Claude), happy);
    assert!(app.did(|e| *e == Effect::Write { path: PATH.into(), mode: 0o644 }));
    let install = app.execs().into_iter().find(|e| e.contains("CMUX_CREDENTIAL_INSTALL")).unwrap();
    assert_eq!(install, install_command(Provider::Claude, PATH, false, "user-1"));
    assert!(install.starts_with(
        "set -e\n. /etc/cmux/agent-auth.sh\ncmux_agent_drop_model_plane_env\npython3 - 'claude' '"
    ));
    assert!(install.ends_with("\nCMUX_CREDENTIAL_INSTALL"));
}

#[test]
fn fs_write_no_effect_or_state_carries_the_login() {
    let mut app = App::new();
    app.run(copy(Provider::Claude), happy);
    let text = serde_json::to_string(&(&app.ran, &app.state)).unwrap();
    assert!(!text.contains("sk-ant-oat01"), "{text}");
    assert!(!text.contains("115,107,45,97,110,116"), "{text}");
}

#[test]
fn fs_write_a_failed_write_removes_the_staged_file() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::Write { .. } => Some(Event::Threw { failure: None }),
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::DeliveryFailed));
    assert_eq!(app.execs().last().unwrap(), &format!("rm -f -- '{PATH}'"));
}

#[test]
fn fs_write_a_bad_staging_id_never_builds_a_path() {
    for id in ["", "../etc/passwd", "a b", "x;rm"] {
        let mut app = App::new();
        let mut c = copy(Provider::Claude);
        c.staging_id = id.into();
        assert_eq!(app.run(c, happy), failed(Failure::DeliveryFailed), "{id}");
        assert_eq!(app.ran.len(), 1);
    }
}

#[test]
fn fs_write_the_machine_scripts_quote_every_word() {
    assert_eq!(quote("it's"), r"'it'\''s'");
    assert_eq!(cleanup_command("/a b"), "rm -f -- '/a b'");
    assert!(
        install_command(Provider::Codex, "/p", false, "o'k")
            .contains("python3 - 'codex' '/p' owner 'o'\\''k' <<")
    );
    assert_eq!(
        restart_guest_check(false),
        r#"case "$(cat /etc/cmux/vm-kind 2>/dev/null)" in owner) ;; *) exit 1 ;; esac"#
    );
    assert_eq!(
        restart_guest_check(true),
        r#"case "$(cat /etc/cmux/vm-kind 2>/dev/null)" in owner|team) ;; *) exit 1 ;; esac"#
    );
    assert_eq!(preflight(false), scripts::PREFLIGHT);
    assert_eq!(preflight(true), scripts::CREATOR_TEAM_PREFLIGHT);
}

/// The scripts the copy runs on the machine are the app's byte for byte, while the app keeps its
/// own copy. A sparse checkout without the app's sources skips this; a full one fails on a drift.
#[test]
fn fs_write_the_machine_scripts_are_the_apps_byte_for_byte() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Packages");
    if !root.is_dir() {
        eprintln!("skipped: no Packages/ in this checkout");
        return;
    }
    let swift =
        root.join("macOS/CmuxNext/Sources/CmuxNextCloudCredentials/CloudCredentialInstaller.swift");
    let Ok(source) = std::fs::read_to_string(&swift) else {
        // The app's copy is gone: it calls these now.
        return;
    };
    let grab = |name: &str| -> String {
        let open = format!("static let {name} = #\"\"\"\n");
        let start =
            source.find(&open).unwrap_or_else(|| panic!("{name} not in {}", swift.display()))
                + open.len();
        let body = &source[start..];
        let close = body.find("\"\"\"#").unwrap();
        let (body, indent) = body[..close].rsplit_once('\n').unwrap();
        body.split('\n')
            .map(|line| line.strip_prefix(indent).unwrap_or(line))
            .collect::<Vec<_>>()
            .join("\n")
    };
    assert_eq!(grab("preflight"), scripts::PREFLIGHT);
    assert_eq!(grab("creatorTeamPreflight"), scripts::CREATOR_TEAM_PREFLIGHT);
    assert_eq!(grab("script"), scripts::install_script());
}

// Codex vs Claude --------------------------------------------------------------------------

#[test]
fn codex_never_reads_or_keeps_a_cached_login_and_signs_in_every_time() {
    let mut app = App::new();
    assert_eq!(app.run(copy(Provider::Codex), happy), Some(End::Installed));
    assert!(!app.did(|e| matches!(e, Effect::Load { .. } | Effect::Store { .. })));
    assert!(app.did(|e| matches!(e, Effect::Acquire { provider: Provider::Codex, .. })));
    // A sign-in is never delivered on the first check: the guest is checked again.
    assert_eq!(app.execs().iter().filter(|e| *e == scripts::PREFLIGHT).count(), 2);
    assert!(app.execs().iter().any(|e| e.contains("python3 - 'codex' '")));
}

#[test]
fn claude_with_no_cached_login_signs_in_keeps_it_and_checks_the_guest_again() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::Load { .. } => Some(Event::Loaded { credential: None }),
        _ => happy(app, e),
    });
    assert_eq!(end, Some(End::Installed));
    assert!(app.did(|e| matches!(e, Effect::Store { .. })));
    assert_eq!(app.execs().iter().filter(|e| *e == scripts::PREFLIGHT).count(), 2);
}

#[test]
fn claude_refresh_skips_the_cache_and_signs_in_again() {
    let mut app = App::new();
    let mut c = copy(Provider::Claude);
    c.refresh = true;
    assert_eq!(app.run(c, happy), Some(End::Installed));
    assert!(!app.did(|e| matches!(e, Effect::Load { .. })));
    assert!(app.did(|e| matches!(e, Effect::Store { .. })));
}

#[test]
fn an_invalid_login_is_refused_before_it_is_kept_or_written() {
    for (provider, bad) in [
        (Provider::Claude, b"sk-ant-oat01-short".to_vec()),
        (Provider::Claude, b"sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123".to_vec()),
        (Provider::Codex, br#"{"OPENAI_API_KEY":"k","tokens":{"access_token":"a","refresh_token":"r","id_token":"i"}}"#.to_vec()),
    ] {
        let mut app = App::new();
        let end = app.run(copy(provider), |app, e| match e {
            Effect::Acquire { .. } => Some(Event::Acquired { credential: bad.clone() }),
            Effect::Load { .. } => Some(Event::Loaded { credential: None }),
            _ => happy(app, e),
        });
        assert_eq!(end, failed(Failure::InvalidCredential));
        assert!(!app.did(|e| matches!(e, Effect::Store { .. } | Effect::Write { .. })));
    }
}

#[test]
fn validate_is_the_apps() {
    assert!(validate(TOKEN, Provider::Claude));
    assert!(!validate(b"sk-ant-oat01-abcdefghijklmnopqr", Provider::Claude)); // 31 bytes
    assert!(validate(b"sk-ant-oat01-abcdefghijklmnopqrs", Provider::Claude)); // 32
    assert!(!validate(b"sk-ant-oat01-abcdefghij klmnopqrstuvwxyz", Provider::Claude));
    assert!(!validate(&[b"sk-ant-oat01-".as_slice(), &[b'a'; 12_000]].concat(), Provider::Claude));
    assert!(validate(&codex_auth(), Provider::Codex));
    assert!(validate(
        br#"{"tokens":{"access_token":"a","refresh_token":"r","id_token":"i"}}"#,
        Provider::Codex
    ));
    assert!(!validate(
        br#"{"tokens":{"access_token":"a","refresh_token":"","id_token":"i"}}"#,
        Provider::Codex
    ));
    assert!(!validate(br#"{"tokens":{"access_token":"a","refresh_token":"r"}}"#, Provider::Codex));
    assert!(!validate(b"[]", Provider::Codex));
}

#[test]
fn claude_token_takes_the_one_token_setup_token_printed() {
    let token = "sk-ant-oat01-ABCDEFGHIJ_klmnopqr-stu";
    let out = format!("Opening...\n\x1b[32m{token}\x1b[0m\nStore it.\n{token}\n");
    assert_eq!(claude_token(out.as_bytes()).as_deref(), Some(token.as_bytes()));
    assert_eq!(claude_token(b"no token here"), None);
    assert_eq!(claude_token(b"sk-ant-oat01-short"), None);
    let two = format!("{token} sk-ant-oat01-ZZZZZZZZZZZZZZZZZZZZZZZZ");
    assert_eq!(claude_token(two.as_bytes()), None);
    assert_eq!(claude_token(&vec![b' '; 262_145]), None);
}

// Refusal codes ----------------------------------------------------------------------------

#[test]
fn refusal_codes_every_installer_refusal_is_a_failed_delivery_with_the_file_removed() {
    for code in [70, 71, 72, 1, 127] {
        let mut app = App::new();
        let end = app.run(copy(Provider::Claude), |app, e| match e {
            Effect::Exec { command, .. } if command.contains("CMUX_CREDENTIAL_INSTALL") => {
                Some(Event::Exec { exit: code })
            }
            _ => happy(app, e),
        });
        assert_eq!(end, failed(Failure::DeliveryFailed), "{code}");
        assert_eq!(app.execs().last().unwrap(), &format!("rm -f -- '{PATH}'"));
    }
}

#[test]
fn refusal_codes_a_copys_own_failure_is_kept_anything_else_is_the_deliverys() {
    for (failure, expect) in [
        (Some(Failure::StoreFailed), Failure::StoreFailed),
        (Some(Failure::LoginFailed), Failure::LoginFailed),
        (Some(Failure::LocalLoginUnavailable), Failure::LocalLoginUnavailable),
        (None, Failure::DeliveryFailed),
    ] {
        let mut app = App::new();
        let end = app.run(copy(Provider::Claude), |app, e| match e {
            Effect::Load { .. } => Some(Event::Loaded { credential: None }),
            Effect::Acquire { .. } => Some(Event::Threw { failure }),
            _ => happy(app, e),
        });
        assert_eq!(end, failed(expect));
    }
    // A platform refusal of the ownership read or an exec is the delivery's.
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |_, e| match e {
        Effect::CallerOwns => Some(Event::Threw { failure: None }),
        _ => None,
    });
    assert_eq!(end, failed(Failure::DeliveryFailed));
}

#[test]
fn refusal_codes_failures_carry_the_apps_fixed_words() {
    assert_eq!(Failure::ALL.len(), 11);
    assert_eq!(serde_json::to_value(Failure::MachineNotReady).unwrap(), "machine_not_ready");
    assert_eq!(
        Failure::MachineNotReady.message(),
        "The Cloud machine is still setting up, so cmux can't confirm it's yours yet. Try again in a minute."
    );
    assert_eq!(outcome(&End::Installed), "installed");
    assert_eq!(outcome(&End::Cancelled), "cancelled");
    assert_eq!(
        outcome(&End::Failed { failure: Failure::DeliveryFailed }),
        "failed: The credential was not installed on the machine; retry setup in cmux."
    );
    assert_eq!(OUTCOME_DECLINED, "declined");
}

#[test]
fn refusal_codes_an_answer_the_copy_did_not_ask_for_fails_closed() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::StillAllowed => Some(Event::Written),
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::DeliveryFailed));
    assert!(!app.did(|e| matches!(e, Effect::Write { .. })));
}

// Rotation during the copy ------------------------------------------------------------------

#[test]
fn rotation_an_account_or_team_switch_before_the_write_is_scope_changed() {
    // Each point the app checks its scope before the write.
    for at in ["begin", "guest", "load", "store", "recheck"] {
        let mut app = App::new();
        if at == "begin" {
            app.scope.team_id = Some("team-2".into());
        }
        let mut c = copy(Provider::Claude);
        c.refresh = at == "store";
        let end = app.run(c, |app, e| {
            let event = happy(app, e);
            let switch = match (at, e) {
                ("guest", Effect::Exec { command, .. }) => command == scripts::PREFLIGHT,
                ("load", Effect::Load { .. }) => true,
                ("store", Effect::Store { .. }) => true,
                ("recheck", Effect::StillAllowed) => true,
                _ => false,
            };
            if switch {
                app.scope.user_id = Some("user-2".into());
            }
            event
        });
        assert_eq!(end, failed(Failure::ScopeChanged), "{at}");
        assert!(!app.did(|e| matches!(e, Effect::Write { .. })), "{at}");
    }
}

#[test]
fn rotation_a_switch_during_a_guest_pause_is_scope_changed() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| match e {
        Effect::Exec { command, .. } if command == scripts::PREFLIGHT => {
            Some(Event::Exec { exit: 1 })
        }
        Effect::Exec { .. } => Some(Event::Exec { exit: 0 }),
        Effect::Pause { .. } => {
            app.scope.team_id = None;
            Some(Event::Paused)
        }
        _ => happy(app, e),
    });
    assert_eq!(end, failed(Failure::ScopeChanged));
}

#[test]
fn rotation_a_switch_during_the_write_removes_the_staged_file_and_fails_the_delivery() {
    let mut app = App::new();
    let end = app.run(copy(Provider::Claude), |app, e| {
        if matches!(e, Effect::Write { .. }) {
            app.scope.user_id = None;
        }
        happy(app, e)
    });
    assert_eq!(end, failed(Failure::DeliveryFailed));
    let execs = app.execs();
    assert!(!execs.iter().any(|e| e.contains("CMUX_CREDENTIAL_INSTALL")));
    assert_eq!(execs.last().unwrap(), &format!("rm -f -- '{PATH}'"));
}

#[test]
fn rotation_an_empty_machine_or_account_is_never_in_scope() {
    let mut app = App::new();
    let mut c = copy(Provider::Claude);
    c.machine_id.clear();
    assert_eq!(app.run(c, happy), failed(Failure::ScopeChanged));
    let mut app = App::new();
    app.scope.user_id = Some(String::new());
    let mut c = copy(Provider::Claude);
    c.user_id.clear();
    assert_eq!(app.run(c, happy), failed(Failure::ScopeChanged));
}

#[test]
fn rotation_the_personal_scope_is_its_own_scope() {
    let mut app = App::new();
    app.scope.team_id = None;
    let mut c = copy(Provider::Claude);
    c.team_id = None;
    assert_eq!(app.run(c, happy), Some(End::Installed));
}

// Abandoned copy ----------------------------------------------------------------------------

#[test]
fn abandoned_a_cancelled_copy_before_the_write_just_ends() {
    let mut app = App::new();
    let mut effects = app.send(Event::Begin { copy: copy(Provider::Claude) });
    assert_eq!(effects, [Effect::CallerOwns]);
    effects = app.send(Event::Cancelled);
    assert!(
        matches!(effects.as_slice(), [Effect::Finish { end: End::Cancelled, outcome }] if outcome == "cancelled")
    );
    assert!(app.execs().is_empty());
}

#[test]
fn abandoned_a_cancelled_write_or_install_still_removes_the_staged_file() {
    for during in ["write", "install"] {
        let mut app = App::new();
        let end = app.run(copy(Provider::Claude), |app, e| match (during, e) {
            ("write", Effect::Write { .. }) => None,
            ("install", Effect::Exec { command, .. })
                if command.contains("CMUX_CREDENTIAL_INSTALL") =>
            {
                None
            }
            _ => happy(app, e),
        });
        assert_eq!(end, None);
        let cleanup = app.send(Event::Cancelled);
        assert_eq!(
            cleanup,
            [Effect::Exec {
                command: format!("rm -f -- '{PATH}'"),
                timeout_ms: 20_000,
                cutoff_ms: None
            }]
        );
        // A second cancel while it removes keeps it cancelled.
        assert!(app.send(Event::Cancelled).is_empty());
        let done = app.send(Event::Threw { failure: None });
        assert!(
            matches!(done.as_slice(), [Effect::Finish { end: End::Cancelled, .. }]),
            "{during}: {done:?}"
        );
    }
}

#[test]
fn abandoned_an_ended_copy_ignores_every_later_event() {
    let mut app = App::new();
    app.run(copy(Provider::Claude), happy);
    for event in [Event::Cancelled, Event::Written, Event::Begin { copy: copy(Provider::Claude) }] {
        assert!(app.send(event).is_empty());
    }
}

#[test]
fn abandoned_a_warm_whose_account_or_team_switched_reports_abandoned() {
    for result in [WarmEnd::Finished, WarmEnd::Installed, WarmEnd::Verified] {
        assert_eq!(warm_end(result, true), result);
        assert_eq!(warm_end(result, false), WarmEnd::Abandoned);
    }
}

// Receipts and the cache --------------------------------------------------------------------

#[test]
fn receipts_the_cache_reads_the_selected_team_first_then_the_others_once() {
    let others = vec![Some("team-2".into()), Some("team-1".into()), None];
    assert_eq!(
        login_scopes(Provider::Claude, Some("team-1"), &others),
        [Some("team-1".into()), Some("team-2".into()), None]
    );
    assert_eq!(login_scopes(Provider::Codex, Some("team-1"), &others), [Some("team-1".into())]);
}

#[test]
fn receipts_an_unreadable_entry_never_hides_a_good_one() {
    let unreadable = ScopeRead::Failed { failure: Failure::StoreFailed };
    assert_eq!(
        pick_cached(&[unreadable.clone(), ScopeRead::Found { index: 1 }]),
        ScopeRead::Found { index: 1 }
    );
    assert_eq!(pick_cached(&[ScopeRead::Empty, unreadable.clone()]), ScopeRead::Empty);
    assert_eq!(pick_cached(&[unreadable.clone(), ScopeRead::Empty]), unreadable);
    assert_eq!(pick_cached(&[]), ScopeRead::Empty);
    assert_eq!(cached_login(&unreadable), CachedLogin::Unreadable);
    assert_eq!(CachedLogin::Cached.start_outcome(), None);
    assert_eq!(
        CachedLogin::None.start_outcome(),
        Some("no cached login: the chat's Sign in to Claude card")
    );
    assert_eq!(
        CachedLogin::Unreadable.start_outcome(),
        Some(
            "cached login unreadable (the Keychain did not answer): the chat's Sign in to Claude card"
        )
    );
}

#[test]
fn receipts_the_keychain_item_is_the_apps() {
    use sha2::{Digest as _, Sha256};
    let hex = |s: &str| {
        Sha256::digest(s.as_bytes()).iter().take(12).map(|b| format!("{b:02x}")).collect::<String>()
    };
    assert_eq!(
        keychain_name(Provider::Claude, Some("t"), "u", Some("vm")),
        format!("CLAUDE_TRANSFER_{}", hex("u:t:"))
    );
    assert_eq!(
        keychain_name(Provider::Claude, None, "u", None),
        format!("CLAUDE_TRANSFER_{}", hex("u:personal:"))
    );
    assert_eq!(
        keychain_name(Provider::Codex, None, "u", Some("vm")),
        format!("CODEX_TRANSFER_{}", hex("u:personal:vm"))
    );
    assert_eq!((KEYCHAIN_SERVICE, KEYCHAIN_ITEM_NOT_FOUND), ("cmux-cloud-secret", 44));
}

#[test]
fn receipts_the_stored_envelope_is_read_as_the_app_reads_it() {
    assert_eq!(
        envelope(b"{\"created\":1700000000.5,\"credential\":\"aGVsbG8=\"}\r\n").as_deref(),
        Some(b"hello".as_slice())
    );
    assert_eq!(
        envelope(b"{\"created\":1,\"credential\":\"aGk=\"}").as_deref(),
        Some(b"hi".as_slice())
    );
    assert_eq!(envelope(b"{\"created\":0,\"credential\":\"aGk=\"}"), None);
    assert_eq!(envelope(b"{\"credential\":\"aGk=\"}"), None);
    assert_eq!(envelope(b"{\"created\":1,\"credential\":\"aGk\"}"), None);
    assert_eq!(envelope(b"{\"created\":1,\"credential\":\"a=Gk\"}"), None);
    assert_eq!(envelope(b"not json"), None);
    assert!(envelope_fits(&[0; 16_384]) && !envelope_fits(&[0; 16_385]));
}
