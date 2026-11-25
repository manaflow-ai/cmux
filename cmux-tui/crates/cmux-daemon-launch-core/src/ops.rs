//! The JSON ops of the C ABI (`cmux_daemon_launch_call`): one op name and
//! one request object in, one reply value out. Field names are camelCase;
//! an environment is a JSON object of strings. The golden vectors in
//! `tests/cases/*.json` list each op's requests and replies.

use crate::failure::{self, ErrorInput, Outcome, StartFailure};
use crate::fs::{FakeFs, Fs};
use crate::shell_integration::{BundledCli, Integration, shell_arguments};
use crate::{
    Env, cloud_link, ensure, handoff, install_key::InstallKey, legacy, login_env, terminal_env,
};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

/// Why an op gave no reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of these.
    Unknown,
    /// The request is not the object the op takes.
    Invalid,
}

fn de<T: DeserializeOwned>(request: &Value) -> Result<T, OpError> {
    serde_json::from_value(request.clone()).map_err(|_| OpError::Invalid)
}

fn to_value<T: serde::Serialize>(value: &T) -> Result<Value, OpError> {
    serde_json::to_value(value).map_err(|_| OpError::Invalid)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Text {
    #[serde(default)]
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Decide {
    running: handoff::Stamp,
    #[serde(default)]
    bundled: Option<handoff::Stamp>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Parse {
    status: i32,
    #[serde(default)]
    stdout: String,
    #[serde(default)]
    stderr: String,
    #[serde(default)]
    replace: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TimingInput {
    #[serde(default)]
    binary_is_bundled: bool,
    #[serde(default = "twenty_seconds")]
    ensure_timeout_ms: u64,
    #[serde(default)]
    replace: bool,
}

fn twenty_seconds() -> u64 {
    20_000
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EnvOnly {
    #[serde(default)]
    environment: Env,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ErrorRequest {
    error: ErrorInput,
    #[serde(default)]
    free_bytes: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OutcomeRequest {
    #[serde(default)]
    state: Outcome,
    #[serde(default)]
    error: Option<ErrorInput>,
    #[serde(default)]
    pid: Option<i32>,
    #[serde(default)]
    free_bytes: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Names {
    #[serde(default)]
    tag: Option<String>,
    #[serde(default)]
    application_support: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Binary {
    #[serde(default, rename = "override")]
    override_path: Option<String>,
    #[serde(default)]
    resources: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    fs: Option<FakeFs>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoginTerminal {
    #[serde(default)]
    login: Option<Env>,
    #[serde(default)]
    base: Env,
    #[serde(default)]
    overrides: Env,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TermRequest {
    #[serde(default)]
    prefers_ghostty_term: bool,
    #[serde(default)]
    home: String,
    #[serde(default)]
    resources_directory: Option<String>,
    #[serde(default)]
    fs: Option<FakeFs>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SpawnRequest {
    #[serde(default)]
    login: Option<Env>,
    #[serde(default)]
    base: Env,
    #[serde(default)]
    overrides: Env,
    #[serde(default)]
    prefers_ghostty_term: bool,
    #[serde(default)]
    home: String,
    #[serde(default)]
    integration: Option<Integration>,
    #[serde(default)]
    cli: Option<BundledCli>,
    #[serde(default)]
    fs: Option<FakeFs>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IntegrationRequest {
    integration: Integration,
    #[serde(default)]
    env: Env,
    #[serde(default)]
    shell: Option<String>,
    #[serde(default)]
    home: String,
    #[serde(default)]
    fs: Option<FakeFs>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CliRequest {
    cli: BundledCli,
    #[serde(default)]
    env: Env,
    #[serde(default)]
    fs: Option<FakeFs>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CapturePlanRequest {
    #[serde(default)]
    shell: Option<String>,
    #[serde(default)]
    base: Env,
    #[serde(default)]
    user_shell: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    session: String,
    #[serde(default)]
    state_directory: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    touched_only: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Adopt {
    application_support: String,
    #[serde(default)]
    bundle_id: Option<String>,
    session: String,
    #[serde(default)]
    state_directory: Option<String>,
    #[serde(default)]
    remembered_snapshot: Option<String>,
    #[serde(default)]
    now: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LinkRequest {
    #[serde(flatten)]
    link: cloud_link::Link,
    #[serde(default)]
    install: String,
    #[serde(default)]
    base: Env,
    #[serde(default)]
    runtime_base: String,
    #[serde(default)]
    stdout: String,
    #[serde(default)]
    needs_pid: bool,
    #[serde(default)]
    own: Option<String>,
    #[serde(default)]
    default_root: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyRequest {
    #[serde(default)]
    payload: Option<String>,
    #[serde(default)]
    install_id: Option<String>,
    #[serde(default)]
    key_hex: Option<String>,
    #[serde(default)]
    id_random_hex: Option<String>,
    #[serde(default)]
    nonce_hex: Option<String>,
}

impl KeyRequest {
    fn key(&self) -> Option<InstallKey> {
        if let Some(payload) = &self.payload {
            return InstallKey::parse(payload);
        }
        let key = cmux_local_auth::frontend_proof::unhex::<32>(self.key_hex.as_deref()?)?;
        InstallKey::new(self.install_id.as_deref()?, key)
    }
}

fn key_value(key: Option<InstallKey>) -> Value {
    key.map_or(Value::Null, |key| json!({"installId": key.install_id, "payload": key.payload()}))
}

/// Runs one op.
pub fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    match op {
        // The version handoff.
        "version_decision" => {
            let r: Decide = de(request)?;
            to_value(&handoff::version_decision(&r.running, r.bundled.as_ref()))
        }
        "build_stamp_from_version_json" => {
            let r: Text = de(request)?;
            to_value(&handoff::Stamp::from_version_json(&r.text))
        }
        "build_commit_from_version_text" => {
            let r: Text = de(request)?;
            to_value(&handoff::build_commit_from_version_text(&r.text))
        }
        "handoff_gate" => to_value(&handoff::gate(&de(request)?)),

        // `server ensure`.
        "ensure_arguments" => to_value(&ensure::ensure_arguments(&de(request)?)),
        "status_arguments" => {
            let r: ensure::Arguments = de(request)?;
            to_value(&ensure::status_arguments(&r.session))
        }
        "ensure_environment" => to_value(&ensure::environment(&de(request)?)),
        "ensure_timing" => {
            let r: TimingInput = de(request)?;
            to_value(&ensure::timing(r.binary_is_bundled, r.ensure_timeout_ms, r.replace))
        }
        "parse_ensure" => {
            let r: Parse = de(request)?;
            to_value(&ensure::parse(r.status, &r.stdout, &r.stderr, r.replace))
        }
        "reap_grace_probes" => to_value(&ensure::reap_grace_probes()),
        "lists_reap_grace" => {
            let r: Text = de(request)?;
            Ok(Value::Bool(ensure::lists_reap_grace(&r.text)))
        }
        "chief_environment" => {
            let r: EnvOnly = de(request)?;
            to_value(&ensure::chief_environment(&r.environment))
        }
        "diagnostic_knobs" => {
            let r: EnvOnly = de(request)?;
            to_value(&ensure::diagnostic_knobs(&r.environment))
        }
        "last_app_cli_publishes" => {
            let r: EnvOnly = de(request)?;
            Ok(Value::Bool(ensure::last_app_cli_publishes(&r.environment)))
        }
        "session_name" => {
            let r: Names = de(request)?;
            to_value(&ensure::session_name(r.tag.as_deref()))
        }
        "tag_state_directory" => {
            let r: Names = de(request)?;
            Ok(Value::String(ensure::tag_state_directory(
                r.tag.as_deref().unwrap_or_default(),
                &r.application_support,
            )))
        }
        "channel_bundle_ids" => Ok(json!(
            ensure::CHANNEL_BUNDLE_IDS
                .iter()
                .map(|(id, c)| json!({"bundleId": id, "channel": c}))
                .collect::<Vec<_>>()
        )),
        "resolve_binary" => {
            let r: Binary = de(request)?;
            let fs = Fs::from_request(r.fs);
            Ok(
                match ensure::resolve_binary(
                    r.override_path.as_deref(),
                    r.resources.as_deref(),
                    &fs,
                ) {
                    Ok(binary) => json!({"binary": binary}),
                    Err(searched) => json!({"searched": searched}),
                },
            )
        }
        "bundled_executable" => {
            let r: Binary = de(request)?;
            to_value(&ensure::bundled_executable(
                r.resources.as_deref(),
                r.name.as_deref().unwrap_or_default(),
                r.override_path.as_deref(),
            ))
        }

        // Start failures.
        "classify_error" => {
            let r: ErrorRequest = de(request)?;
            Ok(json!({
                "stuck": r.error.is_stuck_owner(),
                "diskFull": r.error.is_disk_full(),
                "watch": failure::EnsureKind::new(Some(&r.error), None),
                "failure": StartFailure::new(&r.error, r.free_bytes),
            }))
        }
        "says_disk_full" => {
            let r: Text = de(request)?;
            Ok(Value::Bool(failure::says_disk_full(&r.text)))
        }
        "note_outcome" => {
            let r: OutcomeRequest = de(request)?;
            to_value(&failure::note_outcome(&r.state, r.error.as_ref(), r.pid, r.free_bytes))
        }

        // Environments.
        "terminal_filter" => {
            let r: EnvOnly = de(request)?;
            to_value(&terminal_env::filter(&r.environment))
        }
        "terminal_environment" => {
            let r: LoginTerminal = de(request)?;
            to_value(&terminal_env::terminal(r.login.as_ref(), &r.base))
        }
        "daemon_environment" => {
            let r: LoginTerminal = de(request)?;
            to_value(&terminal_env::daemon(r.login.as_ref(), &r.base, &r.overrides))
        }
        "daemon_identity_keys" => to_value(&terminal_env::DAEMON_IDENTITY_KEYS),
        "term" => {
            let r: TermRequest = de(request)?;
            Ok(Value::String(
                terminal_env::term(r.prefers_ghostty_term, &r.home, &Fs::from_request(r.fs)).into(),
            ))
        }
        "ghostty_identity" => {
            let r: TermRequest = de(request)?;
            let fs = Fs::from_request(r.fs);
            to_value(&terminal_env::ghostty(
                r.resources_directory.as_deref(),
                r.prefers_ghostty_term,
                &r.home,
                &fs,
            ))
        }
        "terminal_spawn_environment" => {
            let r: SpawnRequest = de(request)?;
            let fs = Fs::from_request(r.fs);
            let term = terminal_env::term(r.prefers_ghostty_term, &r.home, &fs);
            to_value(&terminal_env::spawn(
                r.login.as_ref(),
                &r.base,
                &r.overrides,
                term,
                r.integration.as_ref(),
                r.cli.as_ref(),
                &r.home,
                &fs,
            ))
        }
        "shell_integration_apply" => {
            let r: IntegrationRequest = de(request)?;
            to_value(&r.integration.apply(
                &r.env,
                r.shell.as_deref(),
                &r.home,
                &Fs::from_request(r.fs),
            ))
        }
        "shell_integration_features" => {
            let r: IntegrationRequest = de(request)?;
            to_value(&r.integration.features_value())
        }
        "shell_integration_shell" => {
            let r: IntegrationRequest = de(request)?;
            let mode = r.integration.shell_for(r.shell.as_deref());
            Ok(mode.map_or(Value::Null, |m| {
                serde_json::to_value(format!("{m:?}").to_lowercase()).unwrap_or(Value::Null)
            }))
        }
        "shell_arguments" => {
            let r: IntegrationEnv = de(request)?;
            to_value(&shell_arguments(&r.env))
        }
        "bundled_cli_apply" => {
            let r: CliRequest = de(request)?;
            to_value(&r.cli.apply(&r.env, &Fs::from_request(r.fs)))
        }

        // The login environment.
        "login_capture_plan" => {
            let r: CapturePlanRequest = de(request)?;
            to_value(&login_env::capture_plan(r.shell.as_deref(), &r.base, r.user_shell.as_deref()))
        }
        "login_store_encode" => {
            let r: EnvOnly = de(request)?;
            to_value(&login_env::store_encode(&r.environment))
        }
        "login_store_decode" => {
            let r: Text = de(request)?;
            to_value(&login_env::store_decode(&r.text))
        }

        // The legacy channel session and launch snapshots.
        "legacy_channel" => {
            let r: Adopt = de(request)?;
            to_value(&legacy::channel(r.bundle_id.as_deref(), &r.session))
        }
        "legacy_adopts" => {
            let r: Adopt = de(request)?;
            Ok(Value::Bool(legacy::adopts(&legacy::AdoptInput {
                application_support: &r.application_support,
                bundle_id: r.bundle_id.as_deref(),
                session: &r.session,
                state_directory: r.state_directory.as_deref(),
                remembered_snapshot: r.remembered_snapshot.as_deref(),
                now: &r.now,
            })))
        }
        "find_launch_snapshot" => {
            let r: Snapshot = de(request)?;
            to_value(
                &r.state_directory
                    .as_deref()
                    .and_then(|dir| legacy::find_snapshot(&r.session, dir)),
            )
        }
        "snapshot_workspaces" => {
            let r: Snapshot = de(request)?;
            to_value(&legacy::workspaces(r.path.as_deref().unwrap_or_default(), r.touched_only))
        }

        // The Cloud link process.
        "cloud_link_ensure_arguments" => {
            let r: LinkRequest = de(request)?;
            to_value(&r.link.ensure_arguments(&r.install))
        }
        "cloud_link_stop_arguments" => {
            let r: LinkRequest = de(request)?;
            to_value(&r.link.verb_arguments("stop"))
        }
        "cloud_link_archive_arguments" => {
            let r: LinkRequest = de(request)?;
            to_value(&r.link.verb_arguments("archive"))
        }
        "cloud_link_environment" => {
            let r: LinkRequest = de(request)?;
            to_value(&r.link.environment(&r.base, &r.runtime_base))
        }
        "cloud_link_state_directory" => {
            let r: LinkRequest = de(request)?;
            to_value(&r.link.state_directory())
        }
        "cloud_link_parse_ensure" => {
            let r: LinkRequest = de(request)?;
            Ok(match cloud_link::parse_ensure(&r.stdout, r.needs_pid) {
                Ok(ensured) => json!({"ok": ensured}),
                Err(error) => json!({"error": error}),
            })
        }
        "cloud_link_last_line" => {
            let r: Text = de(request)?;
            Ok(Value::String(cloud_link::last_line(&r.text).into()))
        }
        "cloud_link_state_root" => {
            let r: LinkRequest = de(request)?;
            Ok(cloud_link::state_root(r.own.as_deref(), r.default_root.as_deref())
                .map_or(Value::Null, |(root, own)| json!({"root": root, "own": own})))
        }

        // The install key.
        "install_key_parse" => {
            let r: KeyRequest = de(request)?;
            Ok(key_value(r.key()))
        }
        "install_key_generate" => {
            let r: KeyRequest = de(request)?;
            let key = cmux_local_auth::frontend_proof::unhex::<32>(
                r.key_hex.as_deref().unwrap_or_default(),
            );
            let random = r.id_random_hex.as_deref().and_then(unhex_any);
            Ok(key_value(
                key.zip(random).and_then(|(key, random)| InstallKey::generate(key, &random)),
            ))
        }
        "install_key_valid_id" => {
            let r: KeyRequest = de(request)?;
            Ok(Value::Bool(cmux_local_auth::frontend_proof::valid_install_id(
                r.install_id.as_deref().unwrap_or_default(),
            )))
        }
        "install_key_proof" => {
            let r: KeyRequest = de(request)?;
            to_value(&r.key().and_then(|key| key.proof(r.nonce_hex.as_deref().unwrap_or_default())))
        }
        _ => Err(OpError::Unknown),
    }
}

#[derive(Deserialize)]
struct IntegrationEnv {
    #[serde(default)]
    env: Env,
}

fn unhex_any(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    text.as_bytes()
        .chunks_exact(2)
        .map(|pair| std::str::from_utf8(pair).ok().and_then(|hex| u8::from_str_radix(hex, 16).ok()))
        .collect()
}
