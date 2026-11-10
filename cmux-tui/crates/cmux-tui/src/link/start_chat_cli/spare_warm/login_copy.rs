//! The warm's headless Claude login copy, in the daemon (Leo, 2026-11-10: "Why is this even in
//! Swift anyways mang"). It was the App's `CloudSpareWarm.copyLogin`, on the main actor, with every
//! machine call a child process of its own. Now one worker thread runs it after the ledger hands
//! out the copy ([`super::daemon`]): the Release remote switch, the start's own decision
//! (`harness_login::decide`, headless: only a cached login with consent installs, never a prompt),
//! the guest's kind and the machine's own login, the Keychain read, then the transfer the start
//! runs (`CloudCredentialTransfer`): the owner guest check, the write and the install.
//!
//! Every step that can stop the copy answers false, and the summary line says which. A token is
//! never logged, put in a URL or an argv: it goes only in the write's body.

use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_cloud_api::{Auth, Request as ApiRequest};
use cmux_cloud_start_core::harness_login::{self, Choice, Decision, Inputs, Provider, Step};
use cmux_cloud_start_core::machine_login;
use cmux_tui_core::server::cloud_spare_warm::SpareWarmParams;
use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::scripts;

/// The warm's harness login line: the probe ties a later "machine login cached" to it (cmuxterm-hq#7725).
pub(super) const STEP: &str = "cloud warm spare";
/// How many times the guest's kind is read while it has none yet, [`GUEST_PAUSE`] apart, and for
/// how long at most (`CloudCredentialTransfer.guestCheckTries` and `guestCheckBudget`).
const GUEST_TRIES: u32 = 30;
const GUEST_BUDGET: Duration = Duration::from_secs(90);
const GUEST_PAUSE: Duration = Duration::from_secs(3);
/// The machine's exec deadlines the start uses: 20 s, the login probe 30 s.
const EXEC_MS: u64 = 20_000;
const PROBE_MS: u64 = 30_000;
/// How long the Keychain read may take, every scope at once, before the login counts as unreadable.
const KEYCHAIN_TIMEOUT: Duration = Duration::from_secs(30);
/// The Keychain service `cmux cloud secret set` stores the transfer cache under.
const KEYCHAIN_SERVICE: &str = "cmux-cloud-secret";
/// `security find-generic-password`'s exit status for no such item (errSecItemNotFound).
const ITEM_NOT_FOUND: i32 = 44;
/// The start record's outcomes when this Mac holds no login to give.
const NO_CACHED: &str = "no cached login: the chat's Sign in to Claude card";
const UNREADABLE: &str =
    "cached login unreadable (the Keychain did not answer): the chat's Sign in to Claude card";

/// The calls the copy makes, so a test runs it with no network, Keychain or clock. `Sync`: the
/// Keychain scopes are read on threads of their own, at once.
pub(super) trait Effects: Sync {
    /// `owner.harness_login_copy`'s `enabled`, read now; None when it did not answer.
    fn remote_switch(&self) -> Option<bool>;
    /// One exec on the machine: its exit code and stdout, None when it did not answer.
    fn exec(&self, command: &str, timeout_ms: u64) -> Option<(i64, String)>;
    /// Writes `data` at `path` on the machine (mode 0644, inside `cmux`'s own 0700 folder).
    fn write(&self, path: &str, data: &[u8]) -> bool;
    /// The cached login under `scope` (None: personal): Ok(None) when there is none, Err when the
    /// Keychain did not answer by `deadline`.
    fn keychain(
        &self,
        scope: Option<&str>,
        deadline: Instant,
    ) -> Result<Option<Zeroizing<Vec<u8>>>, ()>;
    fn pause(&self, duration: Duration);
    fn now(&self) -> Instant;
}

/// Runs the copy onto `machine` in backend team `team` for `params.account`. `still` says whether
/// that account is still the person and nothing ended the copy since; `consent` is the person's
/// Release consent now. Both are asked before the copy reads anything and right before the write.
/// Answers whether a login was installed and the decision's summary line.
pub(super) fn copy(
    params: &SpareWarmParams,
    still: &dyn Fn() -> bool,
    consent: &dyn Fn() -> Option<bool>,
    effects: &dyn Effects,
) -> (bool, String) {
    let mut inputs = Inputs {
        dogfood: Some(params.dogfood),
        setting: params.setting,
        harness: Some("claude".into()),
        signed_in: true,
        headless: true,
        stored: params.stored_choice.as_deref().and_then(choice),
        ..Inputs::default()
    };
    if !params.dogfood {
        inputs.remote_switch = effects.remote_switch();
        inputs.consent = consent();
    }
    let decision = harness_login::decide(&inputs);
    if !decision.gate || decision.provider != Some(Provider::Claude) {
        return (false, decision.summary);
    }
    inputs.caller_owns = Some(still());
    let decision = harness_login::decide(&inputs);
    if !decision.reads_machine {
        return (false, decision.summary);
    }
    read_guest(&mut inputs, &decision, effects);
    let decision = harness_login::decide(&inputs);
    let mut cached = None;
    if decision.guest_takes_login {
        let read = cached_login(params, effects);
        let fingerprint =
            read.as_ref().ok().and_then(Option::as_ref).map(|t| machine_login::fingerprint(t));
        inputs.cached = matches!(read, Ok(Some(_)));
        inputs.machine_probe = effects
            .exec(&scripts::login_probe(fingerprint.as_deref()), PROBE_MS)
            .map(|(exit_code, stdout)| machine_login::Probe { exit_code, stdout });
        cached = Some(read);
    }
    let decision = harness_login::decide(&inputs);
    let outcome = |inputs: &mut Inputs, outcome: &str| {
        inputs.outcome = Some(outcome.to_owned());
        harness_login::decide(inputs).summary
    };
    if decision.provider != Some(Provider::Claude) || decision.step != Step::Install {
        return (false, decision.summary);
    }
    let token = match cached {
        Some(Ok(Some(token))) => token,
        Some(Err(())) => return (false, outcome(&mut inputs, UNREADABLE)),
        _ => return (false, outcome(&mut inputs, NO_CACHED)),
    };
    match transfer(params, &token, still, consent, effects) {
        Ok(()) => (true, outcome(&mut inputs, "installed")),
        Err(failure) => (false, outcome(&mut inputs, &format!("failed: {failure}"))),
    }
}

/// The guest's kind, read again while it has none yet (a new guest that has not bound).
fn read_guest(inputs: &mut Inputs, decision: &Decision, effects: &dyn Effects) {
    let deadline = effects.now() + GUEST_BUDGET;
    for attempt in 1..=GUEST_TRIES {
        let Some((_, stdout)) = effects.exec(&decision.guest_kind_probe, EXEC_MS) else { return };
        let unbound = harness_login::guest_kind(&stdout).as_deref() == Some("");
        inputs.guest_stdout = Some(stdout);
        if !unbound || attempt == GUEST_TRIES || effects.now() + GUEST_PAUSE >= deadline {
            return;
        }
        effects.pause(GUEST_PAUSE);
    }
}

/// The person's kept choice word.
fn choice(word: &str) -> Option<Choice> {
    match word {
        "pass" => Some(Choice::Pass),
        "machine" => Some(Choice::Machine),
        "none" => Some(Choice::None),
        _ => None,
    }
}

/// The selected team's cached login first, then the person's other scopes in order
/// (`CloudCredentialLogin.loadAny`): an unreadable or invalid entry never hides a good one. Every
/// scope is read at once, under one deadline, so the read takes [`KEYCHAIN_TIMEOUT`] at most however
/// many teams the person has.
fn cached_login(
    params: &SpareWarmParams,
    effects: &dyn Effects,
) -> Result<Option<Zeroizing<Vec<u8>>>, ()> {
    let scopes = params.login_scopes();
    let deadline = effects.now() + KEYCHAIN_TIMEOUT;
    let reads: Vec<_> = std::thread::scope(|threads| {
        let reading: Vec<_> = scopes
            .iter()
            .map(|scope| {
                std::thread::Builder::new()
                    .name("cloud-warm-keychain".into())
                    .spawn_scoped(threads, move || effects.keychain(scope.as_deref(), deadline))
            })
            .collect();
        reading
            .into_iter()
            .map(|read| read.map_or(Err(()), |read| read.join().unwrap_or(Err(()))))
            .collect()
    });
    let mut first = None;
    for read in reads {
        if let Ok(Some(token)) = &read
            && valid(token)
        {
            return Ok(Some(token.clone()));
        }
        if first.is_none() {
            first = Some(read.map(|_| None));
        }
    }
    first.unwrap_or(Ok(None))
}

/// The Keychain account the transfer cache keeps `user`'s Claude login under in `scope`
/// (`CloudCredentialLogin.name`): `*/CLAUDE_TRANSFER_` and 12 bytes of SHA-256, hex.
pub(super) fn keychain_account(user: &str, scope: Option<&str>) -> String {
    use sha2::{Digest as _, Sha256};
    let digest = Sha256::digest(format!("{user}:{}:", scope.unwrap_or("personal")).as_bytes());
    let hex: String = digest.iter().take(12).map(|byte| format!("{byte:02x}")).collect();
    format!("*/CLAUDE_TRANSFER_{hex}")
}

/// A Claude setup token (`CloudCredentialTransfer.validate`).
pub(super) fn valid(token: &[u8]) -> bool {
    token.len() <= 12_000
        && token.len() >= 32
        && token.starts_with(b"sk-ant-oat01-")
        && token.iter().all(|byte| (33..127).contains(byte))
}

/// The credential inside a stored envelope (`{"created": T, "credential": BASE64}`).
pub(super) fn envelope(output: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let text = std::str::from_utf8(output).ok()?.trim();
    let value: Value = serde_json::from_str(text).ok()?;
    let encoded = value.get("credential")?.as_str()?;
    BASE64.decode(encoded).ok().map(Zeroizing::new)
}

/// The start's transfer, headless and already consented (`CloudCredentialTransfer.run`):
/// the owner guest check (again while the guest has not bound), the token checked, the person and
/// the Release switch read again, the write into `cmux`'s staging folder, the install. A failed
/// install removes the staged copy.
fn transfer(
    params: &SpareWarmParams,
    token: &[u8],
    still: &dyn Fn() -> bool,
    consent: &dyn Fn() -> Option<bool>,
    effects: &dyn Effects,
) -> Result<(), &'static str> {
    if !still() {
        return Err("the signed-in account or Cloud team changed");
    }
    wait_for_guest(effects)?;
    if !valid(token) {
        return Err("invalid credential");
    }
    // The consent is read now, not the warm's: a person who took it back since gets no copy.
    if !(params.dogfood || (effects.remote_switch() == Some(true) && consent() == Some(true))) {
        return Err("copying the login is off");
    }
    // After every blocking read above (the guest check, the remote switch): a sign-out or a
    // switch during any of them stops the copy before the credential leaves this Mac.
    if !still() {
        return Err("the signed-in account or Cloud team changed");
    }
    let path = format!("/home/cmux/.cmux/credential-transfer/{}.json", uuid::Uuid::new_v4());
    let written = effects.write(&path, token);
    // A sign-out during the write: the staged copy is removed, never installed.
    let installed = written
        && still()
        && effects
            .exec(&scripts::install_command(&path), EXEC_MS)
            .is_some_and(|(code, _)| code == 0);
    if installed {
        return Ok(());
    }
    // A failed or stopped delivery must not leave a second readable copy on the machine.
    let _ = effects.exec(&format!("rm -f -- {}", scripts::quote(&path)), EXEC_MS);
    if written && !still() {
        return Err("the signed-in account or Cloud team changed");
    }
    Err("the credential was not installed on the machine")
}

/// The owner guest check, again while the guest has no kind record yet; a kind that fails it is
/// the guest's answer (a team guest, an image without the launchers), refused at once.
fn wait_for_guest(effects: &dyn Effects) -> Result<(), &'static str> {
    const KIND_MISSING: &str = "[ ! -s /etc/cmux/vm-kind ]";
    let deadline = effects.now() + GUEST_BUDGET;
    for attempt in 1..=GUEST_TRIES {
        match effects.exec(scripts::PREFLIGHT, EXEC_MS) {
            Some((0, _)) => return Ok(()),
            Some(_) => {}
            None => break,
        }
        match effects.exec(KIND_MISSING, EXEC_MS) {
            Some((0, _)) => {}
            Some(_) => return Err("not an owner machine"),
            None => break,
        }
        if attempt == GUEST_TRIES || effects.now() + GUEST_PAUSE >= deadline {
            break;
        }
        effects.pause(GUEST_PAUSE);
    }
    Err("the machine is still setting up")
}

/// The real effects: the cmux API's routes through `cmux-cloud-api` on one current-thread
/// runtime, and `/usr/bin/security` for the Keychain (it trusts only that tool for these items).
pub(super) struct Live<'a> {
    pub(super) params: &'a SpareWarmParams,
    pub(super) machine: &'a str,
    pub(super) team: &'a str,
    pub(super) runtime: tokio::runtime::Runtime,
}

impl Live<'_> {
    fn call(&self, call: &str, auth: Auth, args: Map<String, Value>) -> Option<Value> {
        let request = ApiRequest {
            call: call.into(),
            api: self.params.api.clone(),
            auth,
            credential: self.params.access_token.clone(),
            refresh: None,
            team: Some(self.team.to_owned()),
            app_version: None,
            local_only: false,
            args,
        };
        self.runtime.block_on(cmux_cloud_api::perform(&request, Zeroizing::new(Vec::new()))).ok()
    }

    fn io(&self, mut args: Map<String, Value>) -> Option<Value> {
        args.insert("machine".into(), json!(self.machine));
        self.call("machine.io", Auth::Worker, args)
    }
}

impl Effects for Live<'_> {
    fn remote_switch(&self) -> Option<bool> {
        self.call("owner.harness_login_copy", Auth::Owner, Map::new())?.get("enabled")?.as_bool()
    }

    fn exec(&self, command: &str, timeout_ms: u64) -> Option<(i64, String)> {
        let mut args = Map::new();
        args.insert("op".into(), json!("exec"));
        args.insert("command".into(), json!(command));
        args.insert("timeout_ms".into(), json!(timeout_ms));
        let body = self.io(args)?;
        let code = body.get("exitCode")?.as_i64()?;
        Some((code, body.get("stdout").and_then(Value::as_str).unwrap_or_default().to_owned()))
    }

    fn write(&self, path: &str, data: &[u8]) -> bool {
        let mut args = Map::new();
        args.insert("op".into(), json!("write"));
        args.insert("path".into(), json!(path));
        args.insert("data_base64".into(), json!(BASE64.encode(data)));
        args.insert("mode".into(), json!(0o644));
        self.io(args).is_some()
    }

    fn keychain(
        &self,
        scope: Option<&str>,
        deadline: Instant,
    ) -> Result<Option<Zeroizing<Vec<u8>>>, ()> {
        let account = keychain_account(&self.params.account, scope);
        let mut child = cmux_process::Command::new("/usr/bin/security")
            .args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", &account, "-w"])
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::null())
            .spawn()
            .map_err(|_| ())?;
        match child.wait_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(Some(_)) => {}
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(());
            }
        }
        let output = child.wait_with_output().map_err(|_| ())?;
        let stdout = Zeroizing::new(output.stdout);
        match output.status.code() {
            Some(ITEM_NOT_FOUND) => Ok(None),
            Some(0) => Ok(envelope(&stdout).filter(|token| valid(token))),
            _ => Err(()),
        }
    }

    fn pause(&self, duration: Duration) {
        std::thread::sleep(duration);
    }

    fn now(&self) -> Instant {
        Instant::now()
    }
}

#[cfg(test)]
#[path = "login_copy_tests.rs"]
mod tests;
