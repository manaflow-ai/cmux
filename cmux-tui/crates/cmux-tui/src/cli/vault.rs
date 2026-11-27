//! `cmux vault`: the end-to-end encrypted secrets vault (cmuxterm-hq docs/design/e2e-vault.md, crate
//! `cmux-vault-e2e`). Values sync to the person's own devices sealed, and reach their Cloud machines sealed to each
//! machine's daemon key; the server stores ciphertext only. Opt-in: nothing happens until `cmux vault on`.
//!
//! - `status` / `on` / `devices` / `approve CODE` / `remove-device ID` / `rotate`
//! - `ls` / `set NAME [--repo OWNER/NAME | --machine vm_…]` / `rm NAME [--repo … | --machine …]`
//! - `import FILE [--only A,B | --all] [--repo … | --machine …]`: a checkbox per name on a terminal
//! - `sync`: seal what each of the person's machines (spares too) should hold
//!
//! Every verb takes `--team team_…` (the team vault instead of the personal one), `--api URL` and `--json`. The
//! token: `CMUX_CLOUD_ACCESS_TOKEN`, `--cloud-token-file PATH`, else the signed-in app's (`cmux auth token`).
//! A value comes from a hidden prompt or stdin, never argv, and is never printed: every listing shows `••••••••`.
//!
//! This device's key lives in the login Keychain on a Mac and in an owner-only file elsewhere ([`OsDeviceStore`]). Supersedes the Credential Vault of cmux#26487,
//! whose noun this takes.

use std::io::{BufRead as _, IsTerminal as _, Write as _};
use std::path::PathBuf;
use std::time::Duration;

use cmux_vault_e2e::client::{DeviceStore, Http, Vault, VaultRef};
use cmux_vault_e2e::{Scope, dotenv};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{OutputMode, UsageError};

pub(crate) const USAGE: &str = "usage: cmux vault status | on | devices | approve CODE | remove-device ID | rotate
       cmux vault ls
       cmux vault set NAME [--repo OWNER/NAME | --machine vm_...]   (the value from a hidden prompt or stdin)
       cmux vault rm NAME [--repo OWNER/NAME | --machine vm_...]
       cmux vault import FILE [--only A,B | --all] [--repo OWNER/NAME | --machine vm_...]
       cmux vault sync
  each takes --team team_... (the team vault), --api URL, --cloud-token-file PATH (or CMUX_CLOUD_ACCESS_TOKEN) and --json.
  End to end encrypted: your devices hold the key; Cloud machines get only their values, sealed to them.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Verb {
    Help,
    Status,
    On,
    Devices,
    Approve(String),
    RemoveDevice(String),
    Rotate,
    Ls,
    Set { name: String, scope: Scope },
    Rm { name: String, scope: Option<Scope> },
    Import { file: PathBuf, only: Option<Vec<String>>, all: bool, scope: Scope },
    Sync,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct Opts {
    pub team: Option<String>,
    pub api: Option<String>,
    pub token_file: Option<PathBuf>,
}

pub(super) fn parse(rest: &[String]) -> Result<(Verb, Opts), UsageError> {
    let usage = || UsageError::new(USAGE);
    let mut opts = Opts::default();
    let mut positional: Vec<String> = Vec::new();
    let (mut repo, mut machine, mut only, mut all) = (None, None, None, false);
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let Some(flag) = word.strip_prefix("--") else {
            positional.push(word.clone());
            continue;
        };
        let (flag, inline) = match flag.split_once('=') {
            Some((f, v)) => (f, Some(v.to_owned())),
            None => (flag, None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| words.next().cloned())
                .ok_or_else(|| UsageError::new(format!("--{flag} needs a value")))
        };
        match flag {
            "team" => opts.team = Some(value()?),
            "api" | "platform" => opts.api = Some(value()?),
            "cloud-token-file" => opts.token_file = Some(value()?.into()),
            "repo" => repo = Some(value()?),
            "machine" => machine = Some(value()?),
            "only" => {
                only = Some(
                    value()?
                        .split(',')
                        .map(|s| s.trim().to_owned())
                        .filter(|s| !s.is_empty())
                        .collect(),
                )
            }
            "all" => all = true,
            "json" => {}
            "help" => return Ok((Verb::Help, opts)),
            _ => return Err(UsageError::new(format!("unknown flag --{flag}\n{USAGE}"))),
        }
    }
    if let Some(team) = &opts.team
        && VaultRef::parse(&format!("team:{team}")).is_none()
    {
        return Err(UsageError::new("--team takes a team id (team_...)"));
    }
    let scope = match (repo, machine) {
        (Some(_), Some(_)) => return Err(UsageError::new("pick one of --repo and --machine")),
        (Some(repo), None) => Some(
            Scope::parse(&format!("repo:{repo}"))
                .ok_or_else(|| UsageError::new("--repo takes OWNER/NAME"))?,
        ),
        (None, Some(vm)) => Some(
            Scope::parse(&format!("machine:{vm}"))
                .ok_or_else(|| UsageError::new("--machine takes a machine id (vm_...)"))?,
        ),
        (None, None) => None,
    };
    let Some((verb, args)) = positional.split_first() else { return Ok((Verb::Help, opts)) };
    let one = |args: &[String]| match args {
        [one] => Ok(one.clone()),
        _ => Err(usage()),
    };
    let verb = match (verb.as_str(), args) {
        ("help", []) => Verb::Help,
        ("status", []) => Verb::Status,
        ("on" | "enable" | "join", []) => Verb::On,
        ("devices", []) => Verb::Devices,
        ("approve", args) => Verb::Approve(args.join(" ")),
        ("remove-device", args) => Verb::RemoveDevice(one(args)?),
        ("rotate", []) => Verb::Rotate,
        ("ls" | "list", []) => Verb::Ls,
        ("set" | "add", args) => {
            let name = one(args)?;
            if !cmux_vault_e2e::valid_name(&name) {
                return Err(UsageError::new(format!("{name} is not a name the vault keeps")));
            }
            Verb::Set { name, scope: scope.clone().unwrap_or(Scope::All) }
        }
        ("rm" | "remove", args) => Verb::Rm { name: one(args)?, scope: scope.clone() },
        ("import", args) => {
            if only.is_some() && all {
                return Err(UsageError::new("pick one of --only and --all"));
            }
            Verb::Import {
                file: one(args)?.into(),
                only: only.clone(),
                all,
                scope: scope.clone().unwrap_or(Scope::All),
            }
        }
        ("sync", []) => Verb::Sync,
        _ => return Err(usage()),
    };
    if matches!(verb, Verb::Approve(ref code) if code.chars().filter(char::is_ascii_digit).count() != 8)
    {
        return Err(UsageError::new("approve takes the 8-digit code the new device shows"));
    }
    Ok((verb, opts))
}

/// `Some(exit code)` when `args` is `vault …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [vault, rest @ ..] = command_args.as_slice() else { return None };
    if vault != "vault" {
        return None;
    }
    let output = if rest.iter().any(|a| a == "--json") { OutputMode::Json } else { global.output };
    let (verb, opts) = match parse(rest) {
        Ok(parsed) => parsed,
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}", error.0),
                output,
                2,
            ));
        }
    };
    if verb == Verb::Help {
        println!("{USAGE}");
        return Some(0);
    }
    Some(match run(verb, &opts, output) {
        Ok(code) => code,
        Err(failure) => super::app::failure(
            &failure.code,
            &format!("cmux vault: {}", failure.message),
            output,
            1,
        ),
    })
}

/// The Cloud API and a bearer: flags and env first, else the signed-in app.
fn auth(
    opts: &Opts,
) -> Result<(String, Zeroizing<String>, Option<String>), cmux_vault_e2e::client::Failure> {
    use cmux_vault_e2e::client::Failure;
    let from_env = std::env::var("CMUX_CLOUD_ACCESS_TOKEN").ok().filter(|t| !t.trim().is_empty());
    let from_file = match &opts.token_file {
        Some(path) => {
            Some(std::fs::read_to_string(path).map(|t| t.trim().to_owned()).map_err(|_| {
                Failure::new("vault.token_file", "the token file could not be read")
            })?)
        }
        None => None,
    };
    let api_env = std::env::var("CMUX_CLOUD_API").ok().filter(|a| !a.trim().is_empty());
    if let Some(token) = from_file.or(from_env) {
        let api = opts.api.clone().or(api_env).ok_or_else(|| {
            Failure::new(
                "vault.no_api",
                "name the Cloud API with --api URL (or CMUX_CLOUD_API) when you pass a token",
            )
        })?;
        return Ok((api.trim_end_matches('/').to_owned(), Zeroizing::new(token), None));
    }
    let app = super::auth_token::app_token_in(opts.team.as_deref()).map_err(|code| {
        Failure::new(
            "vault.not_signed_in",
            format!("no Cloud sign-in ({code}): sign in to cmux, or pass CMUX_CLOUD_ACCESS_TOKEN and --api"),
        )
    })?;
    let api = opts.api.clone().unwrap_or(app.api_origin);
    Ok((api.trim_end_matches('/').to_owned(), app.token, Some(app.team)))
}

/// reqwest on a current-thread runtime, the bearer on every call.
struct Transport {
    origin: String,
    bearer: Zeroizing<String>,
    team: Option<String>,
    client: reqwest::Client,
    runtime: tokio::runtime::Runtime,
}

impl Transport {
    fn new(
        origin: String,
        bearer: Zeroizing<String>,
        team: Option<String>,
    ) -> Result<Self, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        let space = cmux_build_space::headers().map_err(|e| e.to_string())?;
        let client = cmux_egress::client_builder("cmux_tui::cli::vault")
            .default_headers(space)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self { origin, bearer, team, client, runtime })
    }
}

impl Http for Transport {
    fn send(
        &self,
        method: &str,
        path: &str,
        headers: &[(&str, &str)],
        body: Option<&Value>,
    ) -> Result<(u16, Value), String> {
        let method =
            reqwest::Method::from_bytes(method.as_bytes()).map_err(|_| "bad method".to_owned())?;
        let mut request = self
            .client
            .request(method, format!("{}{path}", self.origin))
            .bearer_auth(self.bearer.as_str())
            .header(reqwest::header::ACCEPT, "application/json")
            .timeout(Duration::from_secs(30));
        if let Some(team) = &self.team {
            request = request.header("x-cmux-team", team.as_str());
        }
        for (key, value) in headers {
            request = request.header(*key, *value);
        }
        if let Some(body) = body {
            request = request.json(body);
        }
        self.runtime.block_on(async move {
            let response = request
                .send()
                .await
                .map_err(|e| format!("the Cloud API did not answer: {}", e.without_url()))?;
            let status = response.status().as_u16();
            let bytes = response
                .bytes()
                .await
                .map_err(|_| format!("the Cloud API answered {status} unreadably"))?;
            Ok((status, serde_json::from_slice(&bytes).unwrap_or(Value::Null)))
        })
    }
}

/// This device's key: the login Keychain on a Mac (the build's Cloud secrets service, account
/// `vault-device:<origin>`), an owner-only file beside the build's Cloud secrets index elsewhere. A DEV build's
/// launch names both (`CMUX_NEXT_CLOUD_SECRETS_SERVICE`, `CMUX_NEXT_CLOUD_SECRETS_FILE`), so its device is its own.
pub(crate) struct OsDeviceStore {
    account: String,
}

impl OsDeviceStore {
    pub(crate) fn for_origin(origin: &str) -> Self {
        let host = origin.split("://").nth(1).unwrap_or(origin).trim_end_matches('/');
        let account: String = host
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || "-._".contains(c) { c } else { '_' })
            .collect();
        Self { account }
    }

    fn file(&self) -> Option<PathBuf> {
        let index = super::cloud_secret::index_path()?;
        Some(index.parent()?.join("vault-device").join(format!("{}.json", self.account)))
    }

    fn keychain_account(&self) -> String {
        format!("vault-device:{}", self.account)
    }

    fn keychain() -> bool {
        cfg!(target_os = "macos")
            && std::path::Path::new("/usr/bin/security").exists()
            && std::env::var_os("CMUX_VAULT_DEVICE_FILE").is_none()
    }

    fn decode(text: &str) -> Option<(String, Zeroizing<Vec<u8>>)> {
        let parsed: Value = serde_json::from_str(text.trim()).ok()?;
        let id = parsed.get("id")?.as_str()?.to_owned();
        let key = cmux_vault_e2e::b64::decode(parsed.get("privateKey")?.as_str()?)?;
        Some((id, Zeroizing::new(key)))
    }
}

impl DeviceStore for OsDeviceStore {
    fn load(&self) -> Result<Option<cmux_vault_e2e::client::DeviceRecord>, String> {
        if Self::keychain() {
            // -g: the password on stderr, never in argv.
            let output = cmux_process::Command::new("/usr/bin/security")
                .args([
                    "find-generic-password",
                    "-s",
                    &super::cloud_secret::service(),
                    "-a",
                    &self.keychain_account(),
                    "-g",
                ])
                .stdin(cmux_process::Stdio::null())
                .stdout(cmux_process::Stdio::null())
                .stderr(cmux_process::Stdio::piped())
                .output()
                .map_err(|_| "the Keychain did not answer".to_owned())?;
            let raw = Zeroizing::new(output.stderr);
            if !output.status.success() {
                return if output.status.code() == Some(44) {
                    Ok(None)
                } else {
                    Err("the Keychain did not answer".to_owned())
                };
            }
            let text = Zeroizing::new(String::from_utf8_lossy(&raw).into_owned());
            let password = Zeroizing::new(
                acpmux::config::profiles::parse_security_password(&text)
                    .ok_or_else(|| "the Keychain item is unreadable".to_owned())?,
            );
            return Ok(Self::decode(&password));
        }
        let Some(path) = self.file() else { return Ok(None) };
        match std::fs::read_to_string(&path) {
            Ok(text) => Ok(Self::decode(&Zeroizing::new(text))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(_) => Err("the device key file could not be read".to_owned()),
        }
    }

    fn save(&self, id: &str, private_key: &[u8]) -> Result<(), String> {
        let record = Zeroizing::new(
            json!({"id": id, "privateKey": cmux_vault_e2e::b64::encode(private_key)}).to_string(),
        );
        if Self::keychain() {
            let cmd = acpmux::cli::harness_secret::store_item(
                "macos",
                &super::cloud_secret::service(),
                &self.keychain_account(),
                "cmux vault device key",
                &record,
            )
            .map_err(|_| "the Keychain refused the device key".to_owned())?;
            return acpmux::cli::harness_secret::run_store(&cmd)
                .map_err(|_| "the Keychain refused the device key".to_owned());
        }
        let path = self.file().ok_or_else(|| "no HOME for the device key".to_owned())?;
        let dir = path.parent().ok_or_else(|| "no folder for the device key".to_owned())?;
        std::fs::create_dir_all(dir)
            .map_err(|_| "the device key folder could not be made".to_owned())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
            let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
            let tmp = path.with_extension("tmp");
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&tmp)
                .map_err(|_| "the device key file could not be written".to_owned())?;
            file.write_all(record.as_bytes())
                .map_err(|_| "the device key file could not be written".to_owned())?;
            std::fs::rename(&tmp, &path)
                .map_err(|_| "the device key file could not be written".to_owned())?;
        }
        #[cfg(not(unix))]
        std::fs::write(&path, record.as_bytes())
            .map_err(|_| "the device key file could not be written".to_owned())?;
        Ok(())
    }
}

fn host_label() -> String {
    let mut buf = [0_u8; 256];
    // SAFETY: gethostname writes at most `buf.len()` bytes into `buf`, which outlives the call.
    #[cfg(unix)]
    let named = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
    #[cfg(not(unix))]
    let named = false;
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    let host = if named {
        String::from_utf8_lossy(buf.get(..end).unwrap_or_default()).trim().to_owned()
    } else {
        String::new()
    };
    let host = if host.is_empty() { "this computer".to_owned() } else { host };
    host.chars().take(120).collect()
}

fn kind() -> &'static str {
    if cfg!(target_os = "macos") { "mac" } else { "cli" }
}

fn run(
    verb: Verb,
    opts: &Opts,
    output: OutputMode,
) -> Result<i32, cmux_vault_e2e::client::Failure> {
    let json = output == OutputMode::Json;
    let (value, text) = perform(verb, opts, json)?;
    if json {
        println!("{value}");
    } else {
        println!("{text}");
    }
    Ok(0)
}

/// One verb, answered as JSON and as text; prints nothing (the MCP tools call it too). `json` also means "no
/// terminal prompts".
pub(super) fn perform(
    verb: Verb,
    opts: &Opts,
    json: bool,
) -> Result<(Value, String), cmux_vault_e2e::client::Failure> {
    use cmux_vault_e2e::client::Failure;
    let (origin, bearer, team_header) = auth(opts)?;
    let header = opts.team.clone().or(team_header);
    let http = Transport::new(origin.clone(), bearer, header)
        .map_err(|m| Failure::new("vault.transport", m))?;
    let store = OsDeviceStore::for_origin(&origin);
    let vault_ref = match &opts.team {
        Some(team) => VaultRef(format!("team:{team}")),
        None => VaultRef::personal(),
    };
    let vault = Vault {
        http: &http,
        store: &store,
        vault: vault_ref,
        kind: kind().to_owned(),
        label: host_label(),
        now_ms: cmux_vault_e2e::client::system_now_ms,
    };
    let out = std::cell::RefCell::new((Value::Null, String::new()));
    let print = |value: Value, text: String| {
        *out.borrow_mut() = (value, text);
    };
    match verb {
        Verb::Help => print(json!({"usage": USAGE}), USAGE.to_owned()),
        Verb::Status | Verb::Devices | Verb::Ls => {
            let status = vault.status()?;
            let value = serde_json::to_value(&status).unwrap_or_default();
            let mut text = match status.state.as_str() {
                "off" => "The vault is off: nothing is synced. `cmux vault on` turns it on for this device.".to_owned(),
                "pending" => format!(
                    "This device waits for an approve. On one of your other devices run `cmux vault approve {}` (or approve it in Settings > Cloud > Vault).",
                    status.safety_code.clone().unwrap_or_default()
                ),
                "not_enrolled" => "The vault is on for your other devices; `cmux vault on` asks to add this one.".to_owned(),
                _ => format!("The vault is on ({} items, {} devices).", status.items.len(), status.devices.len()),
            };
            if verb != Verb::Ls {
                for d in &status.devices {
                    text.push_str(&format!(
                        "\n  {} {:<24} {:<8} {:<8} code {}{}",
                        d.id,
                        d.label,
                        d.kind,
                        d.state,
                        d.safety_code,
                        if d.this_device { "  (this device)" } else { "" }
                    ));
                }
            }
            if verb != Verb::Devices {
                for i in &status.items {
                    text.push_str(&format!("\n  {:<32} {:<8} {}", i.name, i.masked, i.scope_label));
                }
            }
            print(value, text);
        }
        Verb::On => {
            let status = vault.enroll()?;
            let text = if status.state == "active" {
                "The vault is on for this device.".to_owned()
            } else {
                format!(
                    "Asked to add this device. Approve it on one of your other devices with the code {}: `cmux vault approve {}`.",
                    status.safety_code.clone().unwrap_or_default(),
                    status.safety_code.clone().unwrap_or_default()
                )
            };
            print(serde_json::to_value(&status).unwrap_or_default(), text);
        }
        Verb::Approve(code) => {
            let device = vault.approve(&code)?;
            print(
                json!({"approved": device}),
                format!("Approved {} ({}).", device.label, device.id),
            );
        }
        Verb::RemoveDevice(id) => {
            let epoch = vault.remove_device(&id)?;
            print(
                json!({"removed": id, "epoch": epoch}),
                format!("Removed {id}; the vault key was rotated (epoch {epoch})."),
            );
        }
        Verb::Rotate => {
            let epoch = vault.rotate()?;
            print(json!({"epoch": epoch}), format!("Rotated the vault key (epoch {epoch})."));
        }
        Verb::Set { name, scope } => {
            let value = acpmux::cli::harness_secret::read_value(&name)
                .map_err(|_| Failure::new("vault.no_value", "no value was read"))?;
            let revision = vault.set(&name, &scope, value.trim_end_matches(['\n', '\r']))?;
            let synced = vault.sync().map(|rows| rows.len()).unwrap_or(0);
            print(
                json!({"name": name, "scope": scope.wire(), "revision": revision, "machines": synced}),
                format!(
                    "Kept {name} for {} ({}); sealed to {synced} machine(s).",
                    scope.label(),
                    cmux_vault_e2e::mask("")
                ),
            );
        }
        Verb::Rm { name, scope } => {
            let count = vault.remove(&name, scope.as_ref())?;
            let _ = vault.sync();
            print(
                json!({"name": name, "removed": count}),
                format!("Removed {name} ({count} item(s))."),
            );
        }
        Verb::Import { file, only, all, scope } => {
            let text = Zeroizing::new(std::fs::read_to_string(&file).map_err(|_| {
                Failure::new("vault.import_unreadable", "the file could not be read")
            })?);
            let parsed = dotenv::parse(&text);
            let kept = vault.status()?.items;
            let rows = cmux_vault_e2e::client::preview(&parsed, &kept, &scope);
            let keepable: Vec<&cmux_vault_e2e::client::PreviewRow> =
                rows.iter().filter(|r| r.keepable).collect();
            let picked: Vec<String> = if let Some(only) = only {
                for name in &only {
                    if !keepable.iter().any(|r| &r.name == name) {
                        return Err(Failure::new(
                            "vault.import_missing",
                            format!("{name} is not a name the file sets that the vault keeps"),
                        ));
                    }
                }
                only
            } else if all || !std::io::stdin().is_terminal() || json {
                if !all {
                    // Not on a terminal, no --only and no --all: show what it would keep, keep nothing.
                    print(
                        json!({"preview": rows, "skippedLines": parsed.skipped_lines}),
                        format!(
                            "{} names in {}; pass --all or --only A,B to keep them.",
                            keepable.len(),
                            file.display()
                        ),
                    );
                    return Ok(out.into_inner());
                }
                keepable.iter().map(|r| r.name.clone()).collect()
            } else {
                pick(&keepable)?
            };
            let entries: Vec<(&str, &Scope, &str)> = parsed
                .entries
                .iter()
                .filter(|e| picked.contains(&e.name))
                .map(|e| (e.name.as_str(), &scope, e.value.as_str()))
                .collect();
            let done = vault.set_many(&entries)?;
            let synced = vault.sync().map(|rows| rows.len()).unwrap_or(0);
            let names: Vec<&str> = done.iter().map(|(n, _)| n.as_str()).collect();
            print(
                json!({"kept": names, "scope": scope.wire(), "skippedLines": parsed.skipped_lines, "machines": synced}),
                format!(
                    "Kept {} for {}: {}; sealed to {synced} machine(s).",
                    names.len(),
                    scope.label(),
                    names.join(", ")
                ),
            );
        }
        Verb::Sync => {
            let rows = vault.sync()?;
            let mut text = format!("{} machine(s):", rows.len());
            for r in &rows {
                text.push_str(&format!(
                    "\n  {} {:<20} {}{} ({} names)",
                    r.id,
                    r.name.clone().unwrap_or_default(),
                    r.outcome,
                    if r.spare { " spare" } else { "" },
                    r.names.len()
                ));
            }
            print(json!({"machines": rows}), text);
        }
    }
    Ok(out.into_inner())
}

/// A checkbox per name on a terminal: every name starts ticked; the person types numbers to untick, Enter keeps.
fn pick(
    rows: &[&cmux_vault_e2e::client::PreviewRow],
) -> Result<Vec<String>, cmux_vault_e2e::client::Failure> {
    let mut ticked = vec![true; rows.len()];
    let stdin = std::io::stdin();
    loop {
        eprintln!("Keep which names? Values stay hidden.");
        for (index, (row, on)) in rows.iter().zip(&ticked).enumerate() {
            eprintln!(
                "  [{}] {:>2}. {:<32} {}{}",
                if *on { "x" } else { " " },
                index + 1,
                row.name,
                row.masked,
                if row.already_kept { "  (replaces the kept one)" } else { "" }
            );
        }
        eprint!("Numbers to toggle (e.g. 2,4), a for all, n for none, Enter to keep the ticked: ");
        let _ = std::io::stderr().flush();
        let mut line = String::new();
        if stdin.lock().read_line(&mut line).is_err() {
            return Err(cmux_vault_e2e::client::Failure::new(
                "vault.import_cancelled",
                "nothing was kept",
            ));
        }
        let line = line.trim();
        match line {
            "" => break,
            "a" => ticked.iter_mut().for_each(|t| *t = true),
            "n" => ticked.iter_mut().for_each(|t| *t = false),
            _ => {
                for part in line.split([',', ' ']).filter(|p| !p.is_empty()) {
                    if let Some(t) = part
                        .parse::<usize>()
                        .ok()
                        .and_then(|n| n.checked_sub(1))
                        .and_then(|i| ticked.get_mut(i))
                    {
                        *t = !*t;
                    }
                }
            }
        }
    }
    Ok(rows.iter().zip(ticked).filter(|(_, t)| *t).map(|(r, _)| r.name.clone()).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn parses_every_verb() {
        assert_eq!(parse(&words("status")).unwrap().0, Verb::Status);
        assert_eq!(
            parse(&words("approve 1234 5678")).unwrap().0,
            Verb::Approve("1234 5678".into())
        );
        assert!(parse(&words("approve 123")).is_err());
        assert_eq!(
            parse(&words("set OPENAI_API_KEY --repo Manaflow-AI/cmux")).unwrap().0,
            Verb::Set {
                name: "OPENAI_API_KEY".into(),
                scope: Scope::Repo("manaflow-ai/cmux".into())
            }
        );
        assert!(parse(&words("set PATH")).is_err());
        assert!(parse(&words("set A --repo a/b --machine vm_abcdefghij0123456789")).is_err());
        assert_eq!(
            parse(&words("import .env --only A,B")).unwrap().0,
            Verb::Import {
                file: ".env".into(),
                only: Some(vec!["A".into(), "B".into()]),
                all: false,
                scope: Scope::All
            }
        );
        let (verb, opts) = parse(&words("ls --team team_abc")).unwrap();
        assert_eq!((verb, opts.team.as_deref()), (Verb::Ls, Some("team_abc")));
        assert!(parse(&words("ls --team nope")).is_err());
        assert_eq!(parse(&[]).unwrap().0, Verb::Help);
    }

    /// The vault's one client: the bearer goes out in `authorization` and nowhere else (not the
    /// path, not the team header, not the body), checked on the wire by cmux-egress's capture.
    #[test]
    fn seeded_bearer_rides_only_in_authorization() {
        cmux_egress::capture::install().unwrap();
        let origin = "https://vault-api.seeded-person.example.org";
        cmux_egress::allow_named(origin);
        let bearer = Zeroizing::new("SEEDvaultBearer-7c1e9a".to_owned());
        let transport =
            Transport::new(origin.to_owned(), bearer, Some("team_SEEDteam".into())).unwrap();
        let body =
            serde_json::json!({ "name": "OPENAI_API_KEY", "ciphertext": "c2VlZGVkLWNpcGhlcg" });
        let _ = transport.send(
            "PUT",
            "/v1/vault/secrets",
            &[("x-cmux-device", "dev_SEED")],
            Some(&body),
        );

        assert_eq!(
            cmux_egress::capture::requests_to("vault-api.seeded-person.example.org").len(),
            1
        );
        assert_eq!(
            cmux_egress::capture::leaks("SEEDvaultBearer-7c1e9a"),
            vec![
                "vault-api.seeded-person.example.org PUT /v1/vault/secrets: header authorization"
                    .to_owned()
            ]
        );
    }
}
