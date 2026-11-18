use super::codex_trust::*;
use super::*;

pub(super) fn context(root: &Path) -> Context {
    let home = root.join("home");
    let data_home = root.join("data");
    fs::create_dir_all(&home).unwrap();
    let helper = root.join("cmux-tui-hook");
    atomic_write(&helper, b"#!/bin/sh\nexit 0\n", Some(0o755)).unwrap();
    Context {
        home,
        data_home,
        helper_source: Some(helper),
        helper_launcher: None,
        path: None,
        environment: BTreeMap::new(),
    }
}

#[cfg(unix)]
#[test]
fn hermes_command_obeys_its_execution_deadline() {
    let started = Instant::now();
    let error = run_hermes_command_with_timeout(
        Path::new("/bin/sleep"),
        &["30"],
        Duration::from_millis(100),
    )
    .unwrap_err();
    assert!(error.to_string().contains("timed out"));
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[cfg(unix)]
#[test]
fn hermes_command_reaps_child_when_reaper_spawn_fails() {
    let root = tempfile::tempdir().unwrap();
    let pid_path = root.path().join("hermes.pid");
    let script = format!(
        // `exec` keeps the long-running process at the shell's PID and
        // avoids a second fork. Hosted macOS runners may deny that fork
        // while still allowing the process under test to run.
        "printf '%s' $$ > {}; exec /bin/sleep 30",
        shell_quote(pid_path.to_string_lossy().as_ref()),
    );
    let (result_sender, result_receiver) = std::sync::mpsc::sync_channel(1);
    let started = Instant::now();
    let worker = std::thread::spawn(move || {
        FORCE_HERMES_REAPER_SPAWN_FAILURE.with(|failure| failure.set(true));
        let result = run_hermes_command_with_timeout(
            Path::new("/bin/sh"),
            &["-c", &script],
            Duration::from_secs(2),
        );
        result_sender.send(result).unwrap();
    });

    let startup_deadline = Instant::now() + Duration::from_secs(1);
    let pid = loop {
        if let Ok(contents) = fs::read_to_string(&pid_path)
            && let Ok(pid) = contents.trim().parse::<libc::pid_t>()
        {
            break pid;
        }
        assert!(Instant::now() < startup_deadline, "Hermes child did not complete startup");
        std::thread::sleep(Duration::from_millis(5));
    };
    let error = result_receiver
        .recv_timeout(Duration::from_secs(4))
        .expect("Hermes timeout worker did not return")
        .unwrap_err();
    worker.join().unwrap();
    assert!(error.to_string().contains("timed out"));
    assert!(started.elapsed() < Duration::from_secs(4));

    let reap_deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let mut status = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
        // SAFETY: `pid` was written by the direct child started above, and
        // WNOWAIT keeps this assertion from consuming its exit status.
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                pid as libc::id_t,
                status.as_mut_ptr(),
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ECHILD) {
                break;
            }
            panic!("waitid failed while checking Hermes reaper: {error}");
        }
        assert!(
            Instant::now() < reap_deadline,
            "Hermes child was not reaped after timeout returned"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(unix)]
#[test]
fn hermes_reaper_spawn_failure_does_not_wait_for_a_live_child() {
    struct ReaperFailureGuard;

    impl Drop for ReaperFailureGuard {
        fn drop(&mut self) {
            FORCE_HERMES_REAPER_SPAWN_FAILURE.with(|failure| failure.set(false));
        }
    }

    struct ChildGuard(libc::pid_t);

    impl Drop for ChildGuard {
        fn drop(&mut self) {
            // SAFETY: this is the direct child created by the test.
            unsafe {
                libc::kill(self.0, libc::SIGKILL);
                let mut status = 0;
                libc::waitpid(self.0, &mut status, 0);
            }
        }
    }

    let child = std::process::Command::new("/bin/sleep").arg("30").spawn().unwrap();
    let pid = libc::pid_t::try_from(child.id()).unwrap();
    let _child_guard = ChildGuard(pid);
    let child_exit = UnixChildExitSignal::observe(child.id()).unwrap();
    let state = Arc::new(HermesReapState::new(child, Some(child_exit)));
    FORCE_HERMES_REAPER_SPAWN_FAILURE.with(|failure| failure.set(true));
    let _failure_guard = ReaperFailureGuard;

    let started = Instant::now();
    assert!(spawn_hermes_reaper(Arc::clone(&state)).is_err());
    state.handoff_reap();
    assert!(
        started.elapsed() < Duration::from_millis(200),
        "reaper fallback waited for a live child"
    );

    // The handoff deliberately leaves the live child to make the
    // nonblocking property observable. The guard terminates it after the
    // assertion and consumes any status the detached observer did not yet
    // consume.
}

#[cfg(not(unix))]
#[test]
fn public_hook_operations_are_rejected_on_unsupported_platforms() {
    let result = run(&Plan { action: Action::Status, providers: Vec::new() });
    assert!(result.failed);
    assert!(result.value["errors"][0].as_str().unwrap().contains("unsupported"));
    assert!(runtime_helper_path().is_none());
}

#[test]
fn nested_install_is_idempotent_and_migrates_the_legacy_tee() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let config = context.home.join(".codex/hooks.json");
    atomic_write(
        &config,
        br#"{"custom":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"custom-hook"}]},{"hooks":[{"type":"command","command":"'/tmp/cmux-tui-cmux-irc' hook emit --adapter codex --native-event Stop"}]}]}}"#,
        Some(0o600),
    )
    .unwrap();
    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let first = run_with_context(&plan, &context);
    assert!(!first.failed, "{}", first.value);
    assert_eq!(first.value["activation"], ACTIVATION_NOTE);
    let installed_once = fs::read(&config).unwrap();
    let second = run_with_context(&plan, &context);
    assert!(!second.failed, "{}", second.value);
    assert_eq!(fs::read(&config).unwrap(), installed_once);

    let text = String::from_utf8(installed_once).unwrap();
    assert!(text.contains("custom-hook"));
    assert!(text.contains("/tmp/cmux-irc"));
    assert!(!text.contains("cmux-tui-cmux-irc"));
    assert_eq!(text.matches(COMMAND_MARKER).count(), CODEX_EVENTS.len());
    assert!(!text.contains("CMUX_TUI_SOCKET"));
    assert!(text.contains("CMUX_TUI_HOOK"));
    assert!(!text.contains(&context.installed_helper().to_string_lossy().to_string()));
    let parsed: Value = serde_json::from_str(&text).unwrap();
    assert!(visit_strings(&parsed, &mut |value| value.contains("echo {};")));

    let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
    let result = run_with_context(&uninstall, &context);
    assert!(!result.failed, "{}", result.value);
    let text = fs::read_to_string(&config).unwrap();
    assert!(text.contains("custom-hook"));
    assert!(text.contains("/tmp/cmux-irc"));
    assert!(!text.contains(COMMAND_MARKER));
}

/// Trust hashes of the current `hook_command`, from the same identity hash
/// that reproduces `LEGACY_CODEX_TRUSTED_HASHES` below.
const CODEX_TRUSTED_HASHES: &[(&str, &str)] = &[
    ("session_start", "sha256:62dec7fda2eedda09e521ed25f5a3e56fdf259e2cf6e09c61caf6fde04cf9169"),
    (
        "user_prompt_submit",
        "sha256:91bfad4b3a61a1ebf6a96ac16455b6556ae57fd5dacb87b18c52bdc6910d8d97",
    ),
    ("stop", "sha256:7d79bd0e1f09b6202b1244fce48947903d0bb62db620e7747bb46bc5e7bbdcbf"),
    (
        "permission_request",
        "sha256:6a6d12a917dfc12fdfc3e0796f4c5f43d31db0a9dd1f7372cce0f6635cd32b24",
    ),
    ("pre_tool_use", "sha256:9a8c6ae67a0cc5583e8202f37bd62bc9c75b549b04338144ee5b97cbd3553239"),
    ("post_tool_use", "sha256:7eae35124685878835e8f7a4bc73214600f6732c8bddafc27370e4e89757d1a4"),
    ("pre_compact", "sha256:e957b79dd72144e1e738feeeaade51816e2ae07fcaa31c9638fa40b895b2d580"),
    ("post_compact", "sha256:adbb48bf6be51c36f594b09dc5b9b008d2de4b7e72bf20c7e897459beb295d6c"),
    ("subagent_start", "sha256:25a7790bb05c595170f35ce823c0e64080c31ec43e5c65003875466ace055dbd"),
    ("subagent_stop", "sha256:46e1ebc2d41d01b8f4c7ec6ee657e2cfc66ed0b0531fef08cfe52f7fd8f1a479"),
    ("session_end", "sha256:b8231b7c25e8a4c9ecfbfa026269958f32763c359db6b16d4c7579416f5f3097"),
];

/// Trust hashes of `legacy_hook_command`, verified against the real codex 0.150.1 binary: with these
/// exact `hooks.state` values in `config.toml`, codex executes the installed
/// hooks.json commands; without them it parses hooks.json (it even warns
/// about clamping the SessionEnd timeout) and silently skips every handler,
/// so codex sessions never reach the cmux-tui agents view
/// (https://github.com/manaflow-ai/cmux/issues/11040).
const LEGACY_CODEX_TRUSTED_HASHES: &[(&str, &str)] = &[
    ("session_start", "sha256:397d7ce9e0c6367e34771a4293777ff95415b595bf77e2aa420425adc75d70ae"),
    (
        "user_prompt_submit",
        "sha256:07ddfc92c131019a0f7099cf68bfbcd34749f112ce56105f544c9a826070db37",
    ),
    ("stop", "sha256:8150babcaace7dd374a53671af15022040cb1f48fea365beacdecff744161348"),
    (
        "permission_request",
        "sha256:def8faccd7926451435a173f6b392150e425fd369e221674a6b7741d69158c5c",
    ),
    ("pre_tool_use", "sha256:2f90e5824bf1d244ed7fd88f0f545dd3bc896050df56efc12dab3d021efe3d8f"),
    ("post_tool_use", "sha256:a10109f22d9a6ca69c88a0989d208d1323e2894eea3965a42883d5167457e8b4"),
    ("pre_compact", "sha256:a5939da92131e5397df18219e069c0fa59494d832f77ec37d985286aeacca1ec"),
    ("post_compact", "sha256:609234714e7a0ddf9fbc32c049f2651e732c2f27f12cca21954907df0434e1e8"),
    ("subagent_start", "sha256:fb16a1107f5a630d93d50e448ad1b20bf677d94d0ade1a5ec3216cb2b8bf53dc"),
    ("subagent_stop", "sha256:37436a4778c90ed5ab0e207b2922d3e1151dedfa26c33489c9faef7c990e8866"),
    // SessionEnd is installed at codex's 3s cap; the hash is identical to
    // the one codex computed for a clamped 5s, so older installs stay trusted.
    ("session_end", "sha256:8366ef19df8ee745ecc7acbd8f72f7109478a583dfd5d06b61537b8e8d19e088"),
];

fn codex_state_table(context: &Context) -> toml::value::Table {
    let text = fs::read_to_string(context.home.join(".codex/config.toml"))
        .expect("codex trust state must be written to $CODEX_HOME/config.toml");
    let config: toml::Value = toml::from_str(&text).expect("config.toml must stay valid TOML");
    config
        .get("hooks")
        .and_then(|hooks| hooks.get("state"))
        .and_then(toml::Value::as_table)
        .cloned()
        .expect("config.toml must contain a hooks.state table")
}

/// One provider's unreadable config made the whole read-only `agent hook
/// status` fail (bench round 3: `~/.copilot/config.json is not valid
/// JSON`). It is that provider's row now; the others still answer.
#[test]
fn w4j_status_reports_an_unreadable_config_on_its_own_row() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let copilot = context.home.join(".copilot/config.json");
    fs::create_dir_all(copilot.parent().unwrap()).unwrap();
    fs::write(&copilot, b"{ not json").unwrap();
    let plan = Plan { action: Action::Status, providers: vec!["copilot".into(), "claude".into()] };
    let result = run_with_context(&plan, &context);
    assert!(!result.failed, "{}", result.value);
    let rows = result.value["providers"].as_array().unwrap();
    let row = |id: &str| rows.iter().find(|row| row["provider"] == id).unwrap();
    assert_eq!(row("copilot")["state"], "unavailable", "{}", result.value);
    assert_eq!(row("copilot")["reason"], "unreadable", "{}", result.value);
    assert!(row("copilot")["detail"].as_str().is_some_and(|detail| !detail.is_empty()));
    assert_ne!(row("claude")["state"], "unavailable", "{}", result.value);
    assert_eq!(result.value["errors"], json!([]));
}

#[test]
fn codex_install_writes_matching_trust_state_into_config_toml() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let result = run_with_context(&plan, &context);
    assert!(!result.failed, "{}", result.value);
    let hooks_path = context.home.join(".codex/hooks.json");
    let state = codex_state_table(&context);
    for (event, hash) in CODEX_TRUSTED_HASHES {
        let key = format!("{}:{event}:0:0", hooks_path.display());
        let entry = state.get(&key).unwrap_or_else(|| panic!("missing hooks.state entry {key}"));
        assert_eq!(entry.get("trusted_hash").and_then(toml::Value::as_str), Some(*hash), "{key}");
    }
    assert_eq!(state.len(), CODEX_EVENTS.len());
}

#[cfg(unix)]
#[test]
fn codex_session_flags_preserve_current_trust_for_disabled_hooks() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&plan, &context).failed);

    let hooks_path = context.home.join(".codex/hooks.json");
    let hooks_root = read_json_object(&hooks_path).unwrap();
    let key_path = codex_state_key_hooks_path(&hooks_path, false);
    let expected = codex_expected_trust_entries(&key_path, &hooks_root).unwrap();
    let settings = codex_session_hook_settings_with_context(
        Path::new("/tmp/cmux-tui.sock"),
        "term_test",
        Path::new("/tmp/cmux-tui"),
        &context,
    )
    .unwrap();
    let state_line = settings.iter().find(|line| line.starts_with("hooks.state=")).unwrap();
    let parsed: toml::Value = toml::from_str(state_line).unwrap();
    let state = parsed["hooks"]["state"].as_table().unwrap();
    for (key, hash) in &expected {
        let entry = state[key].as_table().unwrap();
        assert_eq!(entry.get("enabled").and_then(toml::Value::as_bool), Some(false));
        assert_eq!(entry.get("trusted_hash").and_then(toml::Value::as_str), Some(hash.as_str()));
    }

    // A stale persisted hash must not be copied into the session override:
    // changing a command keeps Codex's review gate intact.
    let config_path = context.home.join(".codex/config.toml");
    let original = fs::read_to_string(&config_path).unwrap();
    let (changed_key, changed_hash) = expected.iter().next().unwrap();
    let stale = original.replacen(changed_hash, "sha256:stale", 1);
    assert_ne!(stale, original);
    atomic_write(&config_path, stale.as_bytes(), Some(0o600)).unwrap();
    let settings = codex_session_hook_settings_with_context(
        Path::new("/tmp/cmux-tui.sock"),
        "term_test",
        Path::new("/tmp/cmux-tui"),
        &context,
    )
    .unwrap();
    let state_line = settings.iter().find(|line| line.starts_with("hooks.state=")).unwrap();
    let parsed: toml::Value = toml::from_str(state_line).unwrap();
    let entry = parsed["hooks"]["state"][changed_key].as_table().unwrap();
    assert_eq!(entry.get("enabled").and_then(toml::Value::as_bool), Some(false));
    assert!(entry.get("trusted_hash").is_none());
}

#[cfg(unix)]
#[test]
fn codex_session_flags_still_inject_when_install_is_partial() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&plan, &context).failed);
    let hooks_path = context.home.join(".codex/hooks.json");
    let mut hooks = read_json_object(&hooks_path).unwrap();
    let key_path = codex_state_key_hooks_path(&hooks_path, false);
    let expected = codex_expected_trust_entries(&key_path, &hooks).unwrap();
    let (existing_key, existing_hash) =
        expected.iter().find(|(key, _)| key.contains(":post_tool_use:")).unwrap();
    hooks.get_mut("hooks").and_then(Value::as_object_mut).unwrap().remove("Stop");
    atomic_write(
        &hooks_path,
        serde_json::to_vec(&Value::Object(hooks)).unwrap().as_slice(),
        Some(0o600),
    )
    .unwrap();
    let settings = codex_session_hook_settings_with_context(
        Path::new("/tmp/cmux-tui.sock"),
        "term_test",
        Path::new("/tmp/cmux-tui"),
        &context,
    )
    .unwrap();
    assert!(settings.iter().any(|line| line.starts_with("hooks.Stop=")));
    let state_line = settings.iter().find(|line| line.starts_with("hooks.state=")).unwrap();
    let parsed: toml::Value = toml::from_str(state_line).unwrap();
    let entry = parsed["hooks"]["state"][existing_key].as_table().unwrap();
    assert_eq!(entry.get("enabled").and_then(toml::Value::as_bool), Some(false));
    assert_eq!(
        entry.get("trusted_hash").and_then(toml::Value::as_str),
        Some(existing_hash.as_str())
    );
}

#[test]
fn codex_trust_hash_reproduces_the_hashes_codex_verified() {
    let owned = codex_owned_trust_hashes().unwrap();
    for (event, (label, hash)) in CODEX_EVENTS.iter().zip(LEGACY_CODEX_TRUSTED_HASHES) {
        let legacy = codex_trust_hash(
            label,
            &legacy_hook_command("codex", event),
            if *event == "SessionEnd" { 3 } else { 5 },
        );
        assert_eq!(legacy, *hash, "{event}");
        assert!(owned.contains(*hash), "{event}: an upgrade must replace the old entry");
    }
}

#[test]
fn codex_session_end_hook_timeout_stays_within_the_codex_cap() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let result = run_with_context(&plan, &context);
    assert!(!result.failed, "{}", result.value);
    let hooks: Value =
        serde_json::from_slice(&fs::read(context.home.join(".codex/hooks.json")).unwrap()).unwrap();
    for event in CODEX_EVENTS {
        let timeout = hooks["hooks"][*event][0]["hooks"][0]["timeout"].as_u64().unwrap();
        let label = codex_event_state_label(event).unwrap();
        assert_eq!(
            timeout,
            codex_normalized_timeout(label, Some(timeout)),
            "{event}: codex must not clamp or floor the installed timeout"
        );
        if *event == "SessionEnd" {
            assert_eq!(timeout, CODEX_SESSION_END_TIMEOUT_SECONDS);
        } else if *event == "PreToolUse" {
            assert_eq!(timeout, 90);
        } else {
            assert_eq!(timeout, COMMAND_HOOK_TIMEOUT_SECONDS, "{event}");
        }
    }
    // A pre-existing install written with the generic 5s stays owned: codex
    // hashed the clamped value, which is what the installer now writes.
    assert_eq!(
        codex_trust_hash("session_end", &hook_command("codex", "SessionEnd"), 5),
        codex_trust_hash("session_end", &hook_command("codex", "SessionEnd"), 3),
    );
}

#[test]
fn codex_trust_keys_use_the_installed_group_position() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let hooks_path = context.home.join(".codex/hooks.json");
    atomic_write(
        &hooks_path,
        br#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"custom-hook"}]}]}}"#,
        Some(0o600),
    )
    .unwrap();
    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let result = run_with_context(&plan, &context);
    assert!(!result.failed, "{}", result.value);
    let state = codex_state_table(&context);
    // The custom Stop group keeps position 0, so the cmux-owned handler is
    // group 1 and its trust key must say so; codex keys trust by position.
    let stop_key = format!("{}:stop:1:0", hooks_path.display());
    let stop_hash =
        CODEX_TRUSTED_HASHES.iter().find(|(event, _)| *event == "stop").map(|(_, hash)| *hash);
    assert_eq!(
        state
            .get(&stop_key)
            .and_then(|entry| entry.get("trusted_hash"))
            .and_then(toml::Value::as_str),
        stop_hash,
        "{stop_key}"
    );
    assert!(!state.contains_key(&format!("{}:stop:0:0", hooks_path.display())));
}

#[test]
fn codex_trust_keys_use_the_owned_hook_index_within_a_group() {
    // Unit: a foreign hook before ours in the same group shifts the
    // handler index; codex keys trust by group AND handler position.
    let owned = hook_command("codex", "Stop");
    let mixed = json!({"hooks": {"Stop": [{"hooks": [
        {"type": "command", "command": "foreign-first", "timeout": 5},
        {"type": "command", "command": owned, "timeout": 5},
    ]}]}});
    let mixed = mixed.as_object().unwrap().clone();
    assert_eq!(codex_owned_hook_position(&mixed, "Stop"), Some((0, 1)));

    // End to end: after a hand-edit inserts a foreign hook before ours,
    // codex would look up key ...:stop:0:1 and skip the untrusted cmux
    // hook, so status must stop claiming installed; a reinstall re-appends
    // our handler as its own group and mints the key for that position.
    let tmp = tempfile::tempdir().unwrap();
    let context = context(tmp.path());
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&install, &context).failed);
    let hooks_path = context.home.join(".codex/hooks.json");
    let mut edited: Value = serde_json::from_slice(&fs::read(&hooks_path).unwrap()).unwrap();
    edited["hooks"]["Stop"][0]["hooks"]
        .as_array_mut()
        .unwrap()
        .insert(0, json!({"type": "command", "command": "foreign-first", "timeout": 5}));
    atomic_write(&hooks_path, &serde_json::to_vec_pretty(&edited).unwrap(), Some(0o600)).unwrap();

    let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
    let result = run_with_context(&status, &context);
    assert_eq!(result.value["providers"][0]["state"], "partial", "{}", result.value);

    assert!(!run_with_context(&install, &context).failed);
    let state = codex_state_table(&context);
    assert!(
        state.contains_key(&format!("{}:stop:1:0", hooks_path.display())),
        "reinstall must key trust by the hook's new position: {state:?}"
    );
    assert!(!state.contains_key(&format!("{}:stop:0:0", hooks_path.display())));
    let result = run_with_context(&status, &context);
    assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);
}

#[test]
fn codex_status_detects_a_user_edited_hook_entry() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&install, &context).failed);
    let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
    let result = run_with_context(&status, &context);
    assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);

    // A user edit to the installed entry changes codex's normalized
    // identity hash, so codex marks the hook Modified and skips it.
    // Status must hash the entry ACTUALLY on disk, not the canonical
    // shape, or it would keep claiming installed here.
    let hooks_path = context.home.join(".codex/hooks.json");
    let mut edited: Value = serde_json::from_slice(&fs::read(&hooks_path).unwrap()).unwrap();
    edited["hooks"]["Stop"][0]["hooks"][0]["timeout"] = json!(60);
    atomic_write(&hooks_path, &serde_json::to_vec_pretty(&edited).unwrap(), Some(0o600)).unwrap();
    let result = run_with_context(&status, &context);
    assert_eq!(result.value["providers"][0]["state"], "partial", "{}", result.value);

    // Reinstall rewrites the canonical entry, whose hash matches the
    // stored trust state again.
    assert!(!run_with_context(&install, &context).failed);
    let result = run_with_context(&status, &context);
    assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);
}

#[test]
fn snapshot_file_propagates_non_notfound_read_errors() {
    let root = tempfile::tempdir().unwrap();
    // A directory in place of the file is a read error that is NOT
    // NotFound; mapping it to None would make a later rollback delete a
    // pre-existing hooks.json as if it had been absent.
    let dir = root.path().join("hooks.json");
    fs::create_dir_all(&dir).unwrap();
    let error = snapshot_file(&dir).unwrap_err();
    assert!(error.to_string().contains("snapshot"), "{error:#}");

    assert!(snapshot_file(&root.path().join("absent.json")).unwrap().is_none());
    let file = root.path().join("present.json");
    atomic_write(&file, b"{}", Some(0o600)).unwrap();
    assert_eq!(snapshot_file(&file).unwrap().unwrap().0, b"{}");
}

#[cfg(unix)]
#[test]
fn codex_operations_fail_closed_on_a_fifo_config_toml() {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt as _;

    let root = tempfile::tempdir().unwrap();
    let worker_context = context(root.path());
    let context = context(root.path());
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&install, &context).failed);
    let hooks_path = context.home.join(".codex/hooks.json");
    let installed = fs::read(&hooks_path).unwrap();
    let config_path = context.home.join(".codex/config.toml");
    fs::remove_file(&config_path).unwrap();
    let fifo = CString::new(config_path.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);

    // The FIFO has no writer, so merely opening it would block forever;
    // every operation must gate on metadata instead. Run them on a worker
    // thread with a bounded wait so a regression fails fast as a timeout
    // panic instead of hanging the suite.
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
        let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
        let _ = sender.send((
            run_with_context(&status, &worker_context),
            run_with_context(&install, &worker_context),
            run_with_context(&uninstall, &worker_context),
        ));
    });
    let (status_result, install_result, uninstall_result) = receiver
        .recv_timeout(Duration::from_secs(60))
        .expect("codex operations must fail closed on a FIFO config instead of blocking");

    assert_eq!(status_result.value["providers"][0]["state"], "partial", "{}", status_result.value);
    assert!(install_result.failed, "{}", install_result.value);
    assert!(
        install_result.value["errors"][0].as_str().unwrap().contains("not a regular file"),
        "{}",
        install_result.value
    );
    assert!(uninstall_result.failed, "{}", uninstall_result.value);
    // Both mutating operations failed in preflight: hooks.json untouched.
    assert_eq!(fs::read(&hooks_path).unwrap(), installed);
}

#[test]
fn codex_install_supports_an_inline_hooks_table() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let config_path = context.home.join(".codex/config.toml");
    // `hooks = { enabled = true }` is a valid inline table; inserting the
    // state subtable into it used to be silently discarded and then panic.
    atomic_write(&config_path, b"hooks = { enabled = true }\n", Some(0o600)).unwrap();
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let result = run_with_context(&install, &context);
    assert!(!result.failed, "{}", result.value);
    let state = codex_state_table(&context);
    assert_eq!(state.len(), CODEX_EVENTS.len());
    let text = fs::read_to_string(&config_path).unwrap();
    assert!(text.contains("enabled = true"), "{text}");

    let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
    let result = run_with_context(&uninstall, &context);
    assert!(!result.failed, "{}", result.value);
    let text = fs::read_to_string(&config_path).unwrap();
    assert!(text.contains("enabled = true"), "{text}");
    assert!(!text.contains("trusted_hash"), "{text}");
}

#[test]
fn codex_uninstall_keeps_a_commented_user_state_table_byte_identical() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let config_path = context.home.join(".codex/config.toml");
    let original = "# reserved for my hook overrides\n[hooks.state]\n";
    atomic_write(&config_path, original.as_bytes(), Some(0o600)).unwrap();

    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&install, &context).failed);
    assert!(fs::read_to_string(&config_path).unwrap().contains("trusted_hash"));
    let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
    assert!(!run_with_context(&uninstall, &context).failed);
    // The table is empty again but carries the user's comment; deleting
    // it would destroy their content, so the cycle must round-trip.
    assert_eq!(fs::read_to_string(&config_path).unwrap(), original);
}

#[test]
fn codex_trust_commit_re_renders_after_a_concurrent_config_edit() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&install, &context).failed);
    let hooks_path = context.home.join(".codex/hooks.json");
    let config_path = context.home.join(".codex/config.toml");

    // Reset the trust state so a fresh edit is pending, then preflight it.
    atomic_write(&config_path, b"model = \"gpt-5.6\"\n", Some(0o600)).unwrap();
    let hooks_root = read_json_object(&hooks_path).unwrap();
    let prepared = prepare_codex_trust_state(&hooks_path, false, &hooks_root, &hooks_root, true)
        .unwrap()
        .expect("trust entries are missing, so an edit must be pending");

    // A concurrent writer (codex's own trust review or the user) edits
    // config.toml between the preflight and the commit; the commit must
    // fold that edit in rather than clobber it with the stale render.
    atomic_write(&config_path, b"model = \"gpt-5.6\"\nconcurrent = \"edit\"\n", Some(0o600))
        .unwrap();
    commit_codex_trust_state(&prepared).unwrap();
    let text = fs::read_to_string(&config_path).unwrap();
    assert!(text.contains("concurrent = \"edit\""), "{text}");
    assert!(text.contains("model = \"gpt-5.6\""), "{text}");
    assert_eq!(codex_state_table(&context).len(), CODEX_EVENTS.len());

    // If the fresh content no longer validates, the commit must fail and
    // the rollback path must restore hooks.json.
    atomic_write(&config_path, b"model = \"gpt-5.6\"\n", Some(0o600)).unwrap();
    let hooks_root = read_json_object(&hooks_path).unwrap();
    let prepared = prepare_codex_trust_state(&hooks_path, false, &hooks_root, &hooks_root, true)
        .unwrap()
        .unwrap();
    let installed_hooks = fs::read(&hooks_path).unwrap();
    atomic_write(&config_path, b"hooks = true\n", Some(0o600)).unwrap();
    atomic_write(&hooks_path, b"{}\n", Some(0o600)).unwrap();
    let error = commit_codex_trust_state_or_rollback(
        &prepared,
        &hooks_path,
        Some(Some((installed_hooks.clone(), 0o600))),
    )
    .unwrap_err();
    assert!(format!("{error:#}").contains("hooks key"), "{error:#}");
    assert_eq!(fs::read(&hooks_path).unwrap(), installed_hooks);
    assert_eq!(fs::read_to_string(&config_path).unwrap(), "hooks = true\n");
}

#[test]
fn codex_trust_sync_preserves_user_config_and_is_idempotent_and_reversible() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let config_path = context.home.join(".codex/config.toml");
    let user_key = "manual/hooks.json:stop:0:0";
    atomic_write(
        &config_path,
        format!(
            "# personal codex config\nmodel = \"gpt-5.6\"\n\n[hooks.state.\"{user_key}\"]\nenabled = false\ntrusted_hash = \"sha256:user\"\n"
        )
        .as_bytes(),
        Some(0o600),
    )
    .unwrap();
    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let first = run_with_context(&plan, &context);
    assert!(!first.failed, "{}", first.value);
    assert_eq!(first.value["providers"][0]["changed"], Value::Bool(true));
    let text = fs::read_to_string(&config_path).unwrap();
    assert!(text.contains("# personal codex config"));
    assert!(text.contains("model = \"gpt-5.6\""));
    assert!(text.contains("sha256:user"));

    let second = run_with_context(&plan, &context);
    assert!(!second.failed, "{}", second.value);
    assert_eq!(second.value["providers"][0]["changed"], Value::Bool(false));
    assert_eq!(fs::read_to_string(&config_path).unwrap(), text);

    let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
    let result = run_with_context(&uninstall, &context);
    assert!(!result.failed, "{}", result.value);
    let state = codex_state_table(&context);
    assert_eq!(state.len(), 1, "only the user's own trust entry survives");
    assert!(state.contains_key(user_key));
    let text = fs::read_to_string(&config_path).unwrap();
    assert!(text.contains("# personal codex config"));
    assert!(!text.contains(&format!("{}", context.home.join(".codex/hooks.json").display())));
}

#[test]
fn codex_uninstall_removes_entries_but_never_tables() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&install, &context).failed);
    let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
    assert!(!run_with_context(&uninstall, &context).failed);
    // Ownership of an empty table cannot be proven across processes, so
    // uninstall deletes only hash-proven trust entries and leaves the
    // empty [hooks.state] skeleton behind; codex ignores it.
    let state = codex_state_table(&context);
    assert!(state.is_empty(), "only the empty skeleton may remain: {state:?}");
    let text = fs::read_to_string(context.home.join(".codex/config.toml")).unwrap();
    assert!(!text.contains("trusted_hash"), "{text}");
}

#[test]
fn codex_uninstall_removes_a_re_accepted_trust_entry() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&install, &context).failed);
    let hooks_path = context.home.join(".codex/hooks.json");
    let config_path = context.home.join(".codex/config.toml");

    // Simulate codex re-accepting a user-edited cmux hook: the entry
    // keeps the cmux hook's positional key but carries a NEW hash that
    // no canonical command shape produces. Add a user-owned entry at
    // another key that must survive.
    let mut doc: toml_edit::DocumentMut =
        fs::read_to_string(&config_path).unwrap().parse().unwrap();
    let state = doc["hooks"]["state"].as_table_like_mut().unwrap();
    let stop_key = format!("{}:stop:0:0", hooks_path.display());
    state
        .get_mut(&stop_key)
        .unwrap()
        .as_table_like_mut()
        .unwrap()
        .insert("trusted_hash", toml_edit::value("sha256:re-accepted-after-user-edit"));
    let mut user_entry = toml_edit::InlineTable::new();
    user_entry.insert("trusted_hash", toml_edit::Value::from("sha256:user"));
    let user_key = "manual/hooks.json:stop:0:0";
    state.insert(user_key, toml_edit::Item::Value(user_entry.into()));
    atomic_write(&config_path, doc.to_string().as_bytes(), Some(0o600)).unwrap();

    let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
    let result = run_with_context(&uninstall, &context);
    assert!(!result.failed, "{}", result.value);
    // The hook left hooks.json, so its trust entry must go with it by
    // positional key, regardless of the re-accepted hash value.
    assert!(!fs::read_to_string(&hooks_path).unwrap().contains(COMMAND_MARKER));
    let state = codex_state_table(&context);
    assert!(!state.contains_key(&stop_key), "{state:?}");
    assert_eq!(state.len(), 1, "{state:?}");
    assert!(state.contains_key(user_key));
}

#[test]
fn codex_install_refuses_to_clobber_invalid_or_scalar_hooks_config() {
    for broken in ["not = valid = toml\n", "hooks = true\n"] {
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let config_path = context.home.join(".codex/config.toml");
        atomic_write(&config_path, broken.as_bytes(), Some(0o600)).unwrap();
        let hooks_path = context.home.join(".codex/hooks.json");
        let custom =
            br#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"custom-hook"}]}]}}"#;
        atomic_write(&hooks_path, custom, Some(0o600)).unwrap();
        let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
        let result = run_with_context(&plan, &context);
        assert!(result.failed, "{broken:?}: {}", result.value);
        assert_eq!(fs::read_to_string(&config_path).unwrap(), broken);
        // The config preflight runs before hooks.json is touched, so a
        // failed install must not leave new untrusted hooks behind.
        assert_eq!(fs::read(&hooks_path).unwrap(), custom, "{broken:?}");
    }
}

#[test]
fn codex_install_preflight_failure_leaves_an_absent_hooks_json_absent() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let config_path = context.home.join(".codex/config.toml");
    atomic_write(&config_path, b"hooks = true\n", Some(0o600)).unwrap();
    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let result = run_with_context(&plan, &context);
    assert!(result.failed, "{}", result.value);
    assert!(!context.home.join(".codex/hooks.json").exists());
}

#[test]
fn codex_uninstall_preflight_failure_leaves_hooks_json_untouched() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&install, &context).failed);
    let hooks_path = context.home.join(".codex/hooks.json");
    let installed = fs::read(&hooks_path).unwrap();
    let config_path = context.home.join(".codex/config.toml");
    atomic_write(&config_path, b"not = valid = toml\n", Some(0o600)).unwrap();

    let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
    let result = run_with_context(&uninstall, &context);
    assert!(result.failed, "{}", result.value);
    // Removing the hooks while their stale trust entries linger would be a
    // half-applied uninstall; the config preflight must fail first.
    assert_eq!(fs::read(&hooks_path).unwrap(), installed);
    assert_eq!(fs::read_to_string(&config_path).unwrap(), "not = valid = toml\n");
}

#[cfg(unix)]
#[test]
fn codex_install_edits_the_target_of_a_symlinked_config_toml() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let real = root.path().join("dotfiles/codex-config.toml");
    atomic_write(&real, b"# managed by dotfiles\nmodel = \"gpt-5.6\"\n", Some(0o600)).unwrap();
    let config_path = context.home.join(".codex/config.toml");
    fs::create_dir_all(config_path.parent().unwrap()).unwrap();
    symlink(&real, &config_path).unwrap();

    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let first = run_with_context(&install, &context);
    assert!(!first.failed, "{}", first.value);
    // The symlink must survive; the trust entries land in its target so
    // codex and the dotfile manager keep seeing one file.
    assert!(fs::symlink_metadata(&config_path).unwrap().file_type().is_symlink());
    let text = fs::read_to_string(&real).unwrap();
    assert!(text.contains("# managed by dotfiles"));
    assert!(text.contains("trusted_hash"));
    let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
    let result = run_with_context(&status, &context);
    assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);
    let second = run_with_context(&install, &context);
    assert_eq!(second.value["providers"][0]["changed"], Value::Bool(false));

    let uninstall = Plan { action: Action::Uninstall, providers: vec!["codex".into()] };
    let result = run_with_context(&uninstall, &context);
    assert!(!result.failed, "{}", result.value);
    assert!(fs::symlink_metadata(&config_path).unwrap().file_type().is_symlink());
    let text = fs::read_to_string(&real).unwrap();
    assert!(text.contains("# managed by dotfiles"));
    assert!(!text.contains("trusted_hash"));
}

#[cfg(unix)]
#[test]
fn codex_install_refuses_a_dangling_config_symlink() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let config_path = context.home.join(".codex/config.toml");
    fs::create_dir_all(config_path.parent().unwrap()).unwrap();
    symlink(root.path().join("missing-target.toml"), &config_path).unwrap();

    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let result = run_with_context(&plan, &context);
    assert!(result.failed, "{}", result.value);
    assert!(result.value["errors"][0].as_str().unwrap().contains("does not resolve"));
    // Preflight runs first: no hooks were installed and the link survives.
    assert!(!context.home.join(".codex/hooks.json").exists());
    assert!(fs::symlink_metadata(&config_path).unwrap().file_type().is_symlink());
}

#[test]
fn codex_status_reports_partial_for_an_oversized_config_toml() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&install, &context).failed);
    let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
    let result = run_with_context(&status, &context);
    assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);

    // Grow config.toml past the cap without writing real data; the status
    // path must reject it from metadata instead of reading it.
    let config_path = context.home.join(".codex/config.toml");
    let file = OpenOptions::new().write(true).open(&config_path).unwrap();
    file.set_len(MAX_CONFIG_BYTES + 1).unwrap();
    drop(file);
    let result = run_with_context(&status, &context);
    assert_eq!(result.value["providers"][0]["state"], "partial", "{}", result.value);
}

#[test]
fn codex_status_reports_partial_until_config_toml_trusts_the_hooks() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    assert!(!run_with_context(&install, &context).failed);
    let status = Plan { action: Action::Status, providers: vec!["codex".into()] };
    let result = run_with_context(&status, &context);
    assert_eq!(result.value["providers"][0]["state"], "installed", "{}", result.value);

    // codex ignores hooks.json without matching trust state, so a wiped
    // config.toml must demote the report even though hooks.json is intact.
    fs::remove_file(context.home.join(".codex/config.toml")).unwrap();
    let result = run_with_context(&status, &context);
    assert_eq!(result.value["providers"][0]["state"], "partial", "{}", result.value);
}

#[cfg(unix)]
#[test]
fn codex_home_override_trust_keys_use_the_canonicalized_path() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().unwrap();
    let mut context = context(root.path());
    let real = root.path().join("codex-home");
    fs::create_dir_all(&real).unwrap();
    let link = root.path().join("codex-home-link");
    symlink(&real, &link).unwrap();
    context.environment.insert("CODEX_HOME".into(), link.clone().into());
    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let result = run_with_context(&plan, &context);
    assert!(!result.failed, "{}", result.value);
    assert!(link.join("hooks.json").is_file());
    let text = fs::read_to_string(link.join("config.toml")).unwrap();
    let config: toml::Value = toml::from_str(&text).unwrap();
    let state = config["hooks"]["state"].as_table().unwrap();
    // codex canonicalizes an explicit CODEX_HOME before building trust
    // keys, so keys minted against the symlink path would never match.
    let canonical_key = format!(
        "{}:session_start:0:0",
        fs::canonicalize(&real).unwrap().join("hooks.json").display()
    );
    assert!(state.contains_key(&canonical_key), "{text}");
    assert!(!state.keys().any(|key| key.starts_with(&format!("{}", link.display()))), "{text}");
}

/// Claude Code shows a `SessionStart` hook's `systemMessage` only when it
/// waits for the hook: cmux's startup line (how the session compacts)
/// needs a synchronous hook whose output the helper writes.
#[test]
fn claude_session_start_waits_for_the_helper_output() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install = Plan { action: Action::Install, providers: vec!["claude".into()] };
    let result = run_with_context(&install, &context);
    assert!(!result.failed, "{}", result.value);

    let settings: Value =
        serde_json::from_slice(&fs::read(context.home.join(".claude/settings.json")).unwrap())
            .unwrap();
    let hook = &settings["hooks"]["SessionStart"][0]["hooks"][0];
    assert_eq!(hook.get("async").and_then(Value::as_bool), None, "{hook}");
    let command = hook["command"].as_str().unwrap();
    assert!(command.ends_with(&format!("||echo {{}};#{COMMAND_MARKER}")), "{command}");
    assert!(!command.contains(";echo {};"), "{command}");
}

#[test]
fn claude_commands_are_async_without_weakening_other_provider_receipts() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install =
        Plan { action: Action::Install, providers: vec!["codex".into(), "claude".into()] };
    let result = run_with_context(&install, &context);
    assert!(!result.failed, "{}", result.value);

    for (provider, config, expected_async) in [
        ("codex", context.home.join(".codex/hooks.json"), None),
        ("claude", context.home.join(".claude/settings.json"), Some(true)),
    ] {
        let root: Value = serde_json::from_slice(&fs::read(config).unwrap()).unwrap();
        let hook = &root["hooks"]["Stop"][0]["hooks"][0];
        assert_eq!(hook.get("async").and_then(Value::as_bool), expected_async, "{provider}");
        assert_eq!(
            hook.get("timeout").and_then(Value::as_u64),
            Some(COMMAND_HOOK_TIMEOUT_SECONDS),
            "{provider} outer timeout must exceed the journal admission window"
        );
    }
}

#[test]
fn claude_pre_tool_hook_waits_for_sync_barrier() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install = Plan { action: Action::Install, providers: vec!["claude".into()] };
    let result = run_with_context(&install, &context);
    assert!(!result.failed, "{}", result.value);
    let root: Value =
        serde_json::from_slice(&fs::read(context.home.join(".claude/settings.json")).unwrap())
            .unwrap();
    let hook = &root["hooks"]["PreToolUse"][0]["hooks"][0];
    assert_eq!(hook.get("async").and_then(Value::as_bool), None, "{hook}");
}

/// The Codex wrapper's SessionStart hook prints the helper's session
/// context alone on success and the empty object when the helper fails:
/// one JSON object either way.
#[cfg(unix)]
#[test]
fn codex_launch_session_context_prints_one_json_object() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let helper = root.path().join("hook");
    let command =
        codex_contextual_hook_command("SessionStart", Path::new("/unused"), "term_test", &helper);
    for (script, expected) in [
        (
            "#!/bin/sh\necho '{\"hookSpecificOutput\":{\"additionalContext\":\"cmux\"}}'\n",
            json!({"hookSpecificOutput": {"additionalContext": "cmux"}}),
        ),
        ("#!/bin/sh\nexit 1\n", json!({})),
    ] {
        fs::write(&helper, script).unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
        let result = std::process::Command::new("sh").arg("-c").arg(&command).output().unwrap();
        assert_eq!(result.status.code(), Some(0), "{command}");
        let value: Value = serde_json::from_slice(&result.stdout)
            .unwrap_or_else(|error| panic!("{error}: {:?}", result.stdout));
        assert_eq!(value, expected, "{command}");
    }
}

#[cfg(unix)]
#[test]
fn native_pre_tool_wrappers_keep_denials_and_block_helper_failures() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let helper = root.path().join("hook");
    for provider in ["claude", "codex"] {
        let installed = hook_command(provider, "PreToolUse");
        let fallback =
            emit_hook_command(&shell_quote(helper.to_str().unwrap()), provider, "PreToolUse");
        let contextual =
            codex_contextual_hook_command("PreToolUse", Path::new("/unused"), "term_test", &helper);
        for command in [installed, fallback, contextual] {
            for (script, expected) in [
                (
                    "#!/bin/sh\necho '{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}'\n",
                    0,
                ),
                ("#!/bin/sh\necho 'sync not ready' >&2\nexit 1\n", 2),
            ] {
                fs::write(&helper, script).unwrap();
                fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
                let result = std::process::Command::new("sh")
                    .arg("-c")
                    .arg(&command)
                    .env("CMUX_TUI_HOOK", &helper)
                    .output()
                    .unwrap();
                assert_eq!(result.status.code(), Some(expected), "{command}");
                if expected == 0 {
                    let value: Value = serde_json::from_slice(&result.stdout).unwrap();
                    assert_eq!(value["hookSpecificOutput"]["permissionDecision"], "deny");
                }
            }
        }
    }
    let settings = claude_session_hook_settings(Some(&helper)).unwrap();
    let hook = &settings["hooks"]["PreToolUse"][0]["hooks"][0];
    assert_eq!(hook["async"], false);
    assert_eq!(hook["timeout"], 90);
    assert!(hook["command"].as_str().unwrap().contains(HOOK_MODE_ARG));
}

#[cfg(unix)]
#[test]
fn any_launcher_plugin_hooks_run_the_build_helper_marked_as_the_plugin_copy() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().unwrap();
    // A path that needs every double-quote escape.
    let folder = dir.path().join("a \"b\" $c `d` \\e");
    fs::create_dir_all(&folder).unwrap();
    let helper = folder.join("cmux-tui-hook");
    let log = dir.path().join("log");
    fs::write(
        &helper,
        format!(
            "#!/bin/sh\nprintf '%s %s %s\\n' \"${CLAUDE_PLUGIN_ORIGIN_ENV}\" \"$1\" \"$2\" >> '{}'\n",
            log.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
    let plugin = claude_plugin_hook_settings(&helper).unwrap();
    let installed = claude_session_hook_settings(None).unwrap();
    let events = |settings: &Map<String, Value>| {
        settings["hooks"].as_object().unwrap().keys().cloned().collect::<Vec<_>>()
    };
    assert_eq!(events(&plugin), events(&installed));
    for event in ["SessionStart", "Stop", "PreToolUse", "UserPromptSubmit"] {
        let hook = &plugin["hooks"][event][0]["hooks"][0];
        let twin = &installed["hooks"][event][0]["hooks"][0];
        assert_eq!(hook["timeout"], twin["timeout"], "{event}");
        assert_eq!(hook["async"], twin["async"], "{event}");
        let command = hook["command"].as_str().unwrap();
        assert_ne!(Some(command), twin["command"].as_str(), "{event}");
        // Without CMUX_TUI_HOOK the build's helper runs; with it, that one.
        for inherited in [None, Some(helper.as_os_str())] {
            let mut shell = std::process::Command::new("sh");
            shell.arg("-c").arg(command).env_remove(CLAUDE_PLUGIN_ORIGIN_ENV);
            match inherited {
                Some(value) => shell.env("CMUX_TUI_HOOK", value),
                None => shell.env_remove("CMUX_TUI_HOOK"),
            };
            let result = shell.output().unwrap();
            assert!(result.status.success(), "{event}: {command}");
        }
    }
    let lines = fs::read_to_string(&log).unwrap();
    assert_eq!(lines.lines().count(), 8, "{lines}");
    assert!(
        lines.lines().all(|line| line.starts_with(&format!("{CLAUDE_PLUGIN_ORIGIN} claude "))),
        "{lines}"
    );
}

#[test]
fn cloud_catalog_covers_every_local_hook_provider_and_alias() {
    let expected = [
        "codex",
        "claude",
        "gemini",
        "cursor",
        "grok",
        "opencode",
        "amp",
        "pi",
        "omp",
        "campfire",
        "kiro",
        "antigravity",
        "rovodev",
        "hermes-agent",
        "copilot",
        "codebuddy",
        "factory",
        "qoder",
        "kimi",
    ];
    for provider in expected {
        assert!(
            PROVIDERS.iter().any(|candidate| candidate.id == provider),
            "missing cloud provider {provider}"
        );
    }
    assert_eq!(
        select_providers(
            &Plan { action: Action::Status, providers: vec!["agy".into(), "rovo".into()] },
            &context(tempfile::tempdir().unwrap().path())
        )
        .unwrap()
        .iter()
        .map(|provider| provider.id)
        .collect::<Vec<_>>(),
        ["antigravity", "rovodev"]
    );
}

#[cfg(unix)]
#[test]
fn every_catalog_provider_installs_and_reports_ready_in_a_real_home() {
    let root = tempfile::tempdir().unwrap();
    let mut context = context(root.path());
    // Hermes activation requires its CLI, unlike file-only providers.
    // Keep the executable and its enabled state inside this test's home.
    let binary = root.path().join("hermes");
    atomic_write(
        &binary,
        br#"#!/bin/sh
state="${0%/*}/hermes-enabled"
case "$*" in
  'plugins list --enabled --user --no-bundled --json')
    if [ -s "$state" ]; then
      printf '[{"name":"cmux-tui-journal"}]\n'
    else
      printf '[]\n'
    fi ;;
  'plugins enable cmux-tui-journal') printf enabled > "$state" ;;
  'plugins disable cmux-tui-journal') : > "$state" ;;
  *) exit 64 ;;
esac
"#,
        Some(0o755),
    )
    .unwrap();
    context.path = Some(root.path().as_os_str().to_owned());
    for provider in PROVIDERS {
        let plan = Plan { action: Action::Install, providers: vec![provider.id.into()] };
        let result = run_with_context(&plan, &context);
        assert!(!result.failed, "{}: {}", provider.id, result.value);
        let status = Plan { action: Action::Status, providers: vec![provider.id.into()] };
        let result = run_with_context(&status, &context);
        assert_eq!(
            result.value["providers"][0]["state"], "installed",
            "{}: {}",
            provider.id, result.value
        );
    }
    assert_eq!(fs::read_to_string(root.path().join("hermes-enabled")).unwrap(), "enabled");
    let uninstall = Plan { action: Action::Uninstall, providers: vec!["hermes-agent".into()] };
    let result = run_with_context(&uninstall, &context);
    assert!(!result.failed, "{}", result.value);
    assert!(fs::read(root.path().join("hermes-enabled")).unwrap().is_empty());
}

#[cfg(unix)]
#[test]
fn install_without_a_standalone_helper_writes_a_cmux_tui_launcher() {
    use std::os::unix::fs::PermissionsExt as _;

    let root = tempfile::tempdir().unwrap();
    let mut context = context(root.path());
    context.helper_source = None;
    context.helper_launcher = Some(root.path().join("it's bin/cmux-tui"));
    let plan = Plan { action: Action::Install, providers: vec!["claude".into()] };
    let result = run_with_context(&plan, &context);
    assert!(!result.failed, "{}", result.value);
    let helper = context.installed_helper();
    assert_eq!(
        fs::read_to_string(&helper).unwrap(),
        format!(
            "#!/bin/sh\nexec '{}/it'\\''s bin/cmux-tui' __agent-hook \"$@\"\n",
            root.path().display()
        )
    );
    assert_ne!(fs::metadata(&helper).unwrap().permissions().mode() & 0o111, 0);
    let modified = fs::metadata(&helper).unwrap().modified().unwrap();
    let again = run_with_context(&plan, &context);
    assert!(!again.failed, "{}", again.value);
    assert_eq!(again.value["providers"][0]["changed"], false, "{}", again.value);
    assert_eq!(fs::metadata(&helper).unwrap().modified().unwrap(), modified);
}

#[test]
fn install_without_any_helper_reports_it() {
    let root = tempfile::tempdir().unwrap();
    let mut context = context(root.path());
    context.helper_source = None;
    let plan = Plan { action: Action::Install, providers: vec!["claude".into()] };
    let result = run_with_context(&plan, &context);
    assert!(result.failed, "{}", result.value);
    assert!(result.value["errors"][0].as_str().unwrap().contains("cmux-tui-hook"));
}

#[test]
fn hermes_install_requires_its_executable() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let plan = Plan { action: Action::Install, providers: vec!["hermes-agent".into()] };
    let result = run_with_context(&plan, &context);
    assert!(result.failed, "{}", result.value);
    let error = result.value["errors"][0].as_str().unwrap();
    assert!(error.contains("Hermes Agent executable is unavailable"));
}

#[cfg(unix)]
#[test]
fn command_hook_noops_without_session_helper_and_uses_short_positional_arguments() {
    use std::process::Command;

    let root = tempfile::tempdir().unwrap();
    let mut context = context(root.path());
    let capture = root.path().join("capture");
    let helper_source = context.helper_source.as_ref().unwrap();
    atomic_write(
        helper_source,
        b"#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$CAPTURE\"\necho {}\n",
        Some(0o755),
    )
    .unwrap();
    context.helper_source = Some(helper_source.clone());
    let install = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let result = run_with_context(&install, &context);
    assert!(!result.failed, "{}", result.value);
    let root: Value =
        serde_json::from_slice(&fs::read(context.home.join(".codex/hooks.json")).unwrap()).unwrap();
    let command = root["hooks"]["PreToolUse"][0]["hooks"][0]["command"].as_str().unwrap();
    assert!(command.len() <= 200, "hook command is {} bytes: {command}", command.len());
    assert!(!command.contains("CMUX_TUI_SOCKET"));
    assert!(!hook_command("claude", "Stop").contains("GROK_HOOK_EVENT"));

    let output = Command::new("/bin/sh")
        .args(["-c", command])
        .env("CMUX_TUI_SOCKET", "/tmp/cmux-test.sock")
        .env_remove("CMUX_TUI_HOOK")
        .env_remove("TMUX")
        .env("CAPTURE", &capture)
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(output.stdout, b"{}\n");
    assert!(!capture.exists(), "missing helper identity must be a process-free no-op");

    let output = Command::new("/bin/sh")
        .args(["-c", command])
        .env_remove("CMUX_TUI_SOCKET")
        .env("CMUX_TUI_HOOK", context.installed_helper())
        .env("CAPTURE", &capture)
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(output.stdout, b"{}\n");
    assert_eq!(fs::read_to_string(&capture).unwrap(), "codex PreToolUse\n");
    fs::remove_file(&capture).unwrap();

    // A tmux pane without the session's variables falls back to the
    // installed helper, which routes through the attached tmux client.
    let output = Command::new("/bin/sh")
        .args(["-c", command])
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_HOOK")
        .env("TMUX", "/tmp/tmux-test/default,1,0")
        .env("XDG_DATA_HOME", &context.data_home)
        .env("CAPTURE", &capture)
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(output.stdout, b"{}\n");
    assert_eq!(fs::read_to_string(&capture).unwrap(), "codex PreToolUse\n");
}

#[test]
fn every_command_hook_fits_in_two_hundred_bytes() {
    for provider in PROVIDERS {
        for event in provider.events {
            let command = hook_command(provider.id, event);
            assert!(
                command.len() <= 200,
                "{} {event} hook command is {} bytes: {command}",
                provider.id,
                command.len()
            );
        }
    }
}

#[test]
fn flat_install_preserves_unrelated_cursor_hooks() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let config = context.home.join(".cursor/hooks.json");
    atomic_write(
        &config,
        br#"{"version":1,"hooks":{"stop":[{"command":"custom-hook"},{"command":"'$HOME/.cargo/bin/cmux-tui-agent-hook' cursor stop"}]}}"#,
        Some(0o600),
    )
    .unwrap();
    let cursor = PROVIDERS.iter().copied().find(|provider| provider.id == "cursor").unwrap();
    assert_eq!(provider_status(cursor, &config, false).unwrap().0, "partial");
    let plan = Plan { action: Action::Install, providers: vec!["cursor".into()] };
    let result = run_with_context(&plan, &context);
    assert!(!result.failed, "{}", result.value);
    let text = fs::read_to_string(&config).unwrap();
    assert!(text.contains("custom-hook"));
    assert!(!text.contains("cmux-tui-agent-hook"));
    assert_eq!(text.matches(COMMAND_MARKER).count(), CURSOR_EVENTS.len());
    assert_eq!(provider_status(cursor, &config, false).unwrap().0, "installed");
}

#[test]
fn grok_compatibility_deduplication_does_not_expand_hook_commands() {
    for provider in ["claude", "cursor"] {
        let command = hook_command(provider, "Stop");
        assert!(!command.contains("GROK_HOOK_EVENT"), "{provider}: {command}");
    }
    let grok = hook_command("grok", "Stop");
    assert!(!grok.contains("GROK_HOOK_EVENT"), "{grok}");
}

#[test]
fn plugin_installs_are_owned_idempotent_and_reversible() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let install = Plan {
        action: Action::Install,
        providers: vec!["opencode".into(), "amp".into(), "pi".into()],
    };
    let first = run_with_context(&install, &context);
    assert!(!first.failed, "{}", first.value);
    let snapshots = [
        context.home.join(".config/opencode/plugins/cmux-tui-journal.js"),
        context.home.join(".config/amp/plugins/cmux-tui-journal.ts"),
        context.home.join(".pi/agent/extensions/cmux-tui-journal.ts"),
    ]
    .map(|path| (path.clone(), fs::read(path).unwrap()));
    let second = run_with_context(&install, &context);
    assert!(!second.failed, "{}", second.value);
    for (path, bytes) in &snapshots {
        assert_eq!(&fs::read(path).unwrap(), bytes);
        assert!(String::from_utf8_lossy(bytes).contains(PLUGIN_MARKER));
        assert!(String::from_utf8_lossy(bytes).contains("CMUX_TUI_HOOK"));
        assert!(
            !String::from_utf8_lossy(bytes)
                .contains(&context.installed_helper().to_string_lossy().to_string())
        );
    }

    let uninstall = Plan { action: Action::Uninstall, providers: install.providers };
    let result = run_with_context(&uninstall, &context);
    assert!(!result.failed, "{}", result.value);
    assert!(snapshots.iter().all(|(path, _)| !path.exists()));
}

#[test]
fn plugin_install_migrates_the_owned_legacy_helper() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let path = context.home.join(".config/amp/plugins/cmux-tui-journal.ts");
    atomic_write(&path, b"const binary = '/tmp/cmux-tui-agent-hook';\n", Some(0o600)).unwrap();
    let amp = PROVIDERS.iter().copied().find(|provider| provider.id == "amp").unwrap();
    assert_eq!(provider_status(amp, &path, false).unwrap().0, "partial");
    let plan = Plan { action: Action::Install, providers: vec!["amp".into()] };
    let result = run_with_context(&plan, &context);
    assert!(!result.failed, "{}", result.value);
    let text = fs::read_to_string(path).unwrap();
    assert!(text.contains(PLUGIN_MARKER));
    assert!(!text.contains("cmux-tui-agent-hook"));
    assert_eq!(
        provider_status(amp, &context.home.join(".config/amp/plugins/cmux-tui-journal.ts"), false)
            .unwrap()
            .0,
        "installed"
    );
}

#[test]
fn hermes_plugin_files_are_owned_idempotent_and_reversible() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let hermes = PROVIDERS.iter().copied().find(|provider| provider.id == "hermes-agent").unwrap();
    let path = context.provider_path(hermes);
    let irc = path.parent().unwrap().join("cmux-irc/__init__.py");
    atomic_write(
        &irc,
        b"# Generated by cmux-irc. Reinstall instead of editing this file.\nBINARY = '/tmp/cmux-tui-cmux-irc'\n",
        Some(0o600),
    )
    .unwrap();
    assert_eq!(install_provider(hermes, &path, false, None).unwrap(), ("installed", true));
    assert!(migrate_hermes_cmux_irc_tee(&path).unwrap());
    assert!(!fs::read_to_string(&irc).unwrap().contains("cmux-tui-cmux-irc"));
    assert!(!migrate_hermes_cmux_irc_tee(&path).unwrap());
    assert_eq!(provider_status(hermes, &path, false).unwrap().0, "installed");
    assert_eq!(install_provider(hermes, &path, false, None).unwrap(), ("installed", false));
    assert_eq!(uninstall_provider(hermes, &path, false).unwrap(), ("absent", true));
    assert!(!path.exists());
}

#[test]
fn plugin_install_refuses_to_overwrite_an_unowned_file() {
    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let path = context.home.join(".config/amp/plugins/cmux-tui-journal.ts");
    atomic_write(&path, b"export default custom;\n", Some(0o600)).unwrap();
    let plan = Plan { action: Action::Install, providers: vec!["amp".into()] };
    let result = run_with_context(&plan, &context);
    assert!(result.failed);
    assert_eq!(fs::read_to_string(path).unwrap(), "export default custom;\n");
}

#[cfg(unix)]
#[test]
fn installer_refuses_to_replace_a_config_symlink() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().unwrap();
    let context = context(root.path());
    let target = root.path().join("target.json");
    atomic_write(&target, b"{}\n", Some(0o600)).unwrap();
    let path = context.home.join(".codex/hooks.json");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    symlink(&target, &path).unwrap();
    let plan = Plan { action: Action::Install, providers: vec!["codex".into()] };
    let result = run_with_context(&plan, &context);
    assert!(result.failed);
    assert_eq!(fs::read_to_string(target).unwrap(), "{}\n");
}
