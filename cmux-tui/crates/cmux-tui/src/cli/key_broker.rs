//! `cmux keys`: connect a key provider once, then let agents mint narrowly scoped, expiring keys and
//! store them, with no click per key.
//!
//!     cmux keys connect cloudflare --account ACCOUNT_ID      the one-time bootstrap token, from a no-echo
//!                                                            prompt or stdin, never argv
//!     cmux keys mint cloudflare-r2 --bucket B (--rw|--ro) [--ttl 90d] [--create-bucket]
//!         [--expire-objects-days N] --store SPEC [--store SPEC]
//!     cmux keys ls                                           every provider and every key minted (the audit)
//!     cmux keys revoke ID                                    delete a minted key at its provider
//!
//! A store SPEC is `gh-secret:OWNER/REPO:PREFIX` (repository secrets), `gh-secret:OWNER/REPO@ENV:PREFIX`
//! (an environment's), or `keychain:PREFIX` / `keychain:OWNER/REPO:PREFIX` (this Mac's cloud secrets, the
//! store `cmux cloud secret` and the machine vault deliver from), or `vault:PREFIX` (this machine's kept
//! keys, `acpmux machine vault keep NAME --env`, which agents the daemon starts get). An R2 key stores two names:
//! PREFIX_ACCESS_KEY_ID and PREFIX_SECRET_ACCESS_KEY.
//!
//! The bootstrap token lives in the login Keychain (service `cmux-key-provider`) and only this broker
//! reads it: an agent asks for a key, never for the root credential. Values move only through stdin
//! pipes (`gh secret set`, `security -i`) and are never printed, logged or put in argv.
//! `~/.config/cmux/keys.json` (0600) is the audit: providers, and for each minted key its provider id,
//! scope, expiry, where it was stored and who asked, never a value. docs/cmux-next/keys.md is the design.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use zeroize::Zeroizing;

use super::UsageError;

/// The Keychain service of a provider's bootstrap token; the account is `<provider>/<account id>`.
const PROVIDER_SERVICE: &str = "cmux-key-provider";
const CLOUDFLARE_API: &str = "https://api.cloudflare.com/client/v4";
const DEFAULT_TTL: Duration = Duration::from_secs(90 * 86_400);
const MAX_TTL: Duration = Duration::from_secs(365 * 86_400);
/// The bucket-setup token's life: long enough for create plus lifecycle, revoked right after anyway.
const SETUP_TTL: Duration = Duration::from_secs(15 * 60);
const R2_ADMIN_WRITE: &str = "Workers R2 Storage Write";
const R2_ITEM_WRITE: &str = "Workers R2 Storage Bucket Item Write";
const R2_ITEM_READ: &str = "Workers R2 Storage Bucket Item Read";

const USAGE: &str = "usage: cmux keys connect cloudflare --account ACCOUNT_ID\n       \
cmux keys mint cloudflare-r2 --bucket B (--rw|--ro) [--ttl 90d] [--create-bucket] [--expire-objects-days N] --store SPEC...\n       \
cmux keys ls\n       cmux keys revoke ID\n\
SPEC: gh-secret:OWNER/REPO[@ENV]:PREFIX, keychain:[OWNER/REPO:]PREFIX or vault:PREFIX";

/// `Some(exit code)` when `args` is `keys …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [keys, rest @ ..] = command_args.as_slice() else { return None };
    if keys != "keys" {
        return None;
    }
    let command = match parse(rest) {
        Ok(command) => command,
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}", error.0),
                global.output,
                2,
            ));
        }
    };
    if command == Command::Help {
        println!("{USAGE}");
        return Some(0);
    }
    let result = Paths::home().and_then(|paths| run(command, &paths, &Live::new()?, &LiveSinks));
    Some(match result {
        Ok(answer) => super::wire::print_local_success(&answer, global.output),
        Err(message) => {
            super::app::failure("keys.failed", &format!("cmux: {message}"), global.output, 1)
        }
    })
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Command {
    Help,
    Connect { account: String },
    MintR2(MintR2),
    Ls,
    Revoke { id: String },
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct MintR2 {
    account: Option<String>,
    bucket: String,
    write: bool,
    ttl: Duration,
    create_bucket: bool,
    expire_objects_days: Option<u32>,
    stores: Vec<Store>,
}

/// Where a minted value goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Store {
    GhSecret {
        repo: String,
        environment: Option<String>,
        prefix: String,
    },
    Keychain {
        scope: Option<String>,
        prefix: String,
    },
    /// This machine's kept keys (`acpmux machine vault keep NAME --env`): agents the daemon starts get the
    /// values. `--env`, not `--host`: an S3 pair signs requests locally (SigV4) and the secret never goes
    /// on the wire, so the egress proxy has no placeholder it could fill.
    Vault {
        prefix: String,
    },
}

impl Store {
    fn parse(spec: &str) -> Result<Self, UsageError> {
        let bad = || {
            UsageError::new(format!(
                "--store {spec:?}: expected gh-secret:OWNER/REPO[@ENV]:PREFIX or keychain:[OWNER/REPO:]PREFIX"
            ))
        };
        if let Some(rest) = spec.strip_prefix("gh-secret:") {
            let (target, prefix) = rest.rsplit_once(':').ok_or_else(bad)?;
            let (repo, environment) = match target.split_once('@') {
                Some((repo, env)) if valid_environment(env) => (repo, Some(env.to_owned())),
                Some(_) => return Err(bad()),
                None => (target, None),
            };
            if !valid_repo(repo) || !valid_prefix(prefix) {
                return Err(bad());
            }
            return Ok(Self::GhSecret {
                repo: repo.to_owned(),
                environment,
                prefix: prefix.to_owned(),
            });
        }
        if let Some(rest) = spec.strip_prefix("keychain:") {
            let (scope, prefix) = match rest.rsplit_once(':') {
                Some((repo, prefix)) if valid_repo(repo) => {
                    (Some(repo.to_ascii_lowercase()), prefix)
                }
                Some(_) => return Err(bad()),
                None => (None, rest),
            };
            if !valid_prefix(prefix) {
                return Err(bad());
            }
            super::cloud_secret::check_name(&format!("{prefix}_ACCESS_KEY_ID"))?;
            return Ok(Self::Keychain { scope, prefix: prefix.to_owned() });
        }
        if let Some(prefix) = spec.strip_prefix("vault:") {
            if !valid_prefix(prefix) {
                return Err(bad());
            }
            return Ok(Self::Vault { prefix: prefix.to_owned() });
        }
        Err(bad())
    }

    /// The store's full name of one value: `PREFIX_SUFFIX` where it lives.
    fn label(&self, suffix: &str) -> String {
        match self {
            Self::GhSecret { repo, environment: Some(env), prefix } => {
                format!("gh-secret:{repo}@{env}:{prefix}_{suffix}")
            }
            Self::GhSecret { repo, environment: None, prefix } => {
                format!("gh-secret:{repo}:{prefix}_{suffix}")
            }
            Self::Keychain { scope, prefix } => {
                format!("keychain:{}/{prefix}_{suffix}", scope.as_deref().unwrap_or("*"))
            }
            Self::Vault { prefix } => format!("vault:{prefix}_{suffix}"),
        }
    }

    fn name(&self, suffix: &str) -> String {
        match self {
            Self::GhSecret { prefix, .. }
            | Self::Keychain { prefix, .. }
            | Self::Vault { prefix } => {
                format!("{prefix}_{suffix}")
            }
        }
    }
}

fn valid_repo(repo: &str) -> bool {
    let part = |p: &str| {
        !p.is_empty()
            && p.len() <= 100
            && p != "."
            && p != ".."
            && p.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    };
    matches!(repo.split_once('/'), Some((owner, name)) if part(owner) && part(name))
}

fn valid_environment(env: &str) -> bool {
    !env.is_empty()
        && env.len() <= 255
        && env.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

/// GitHub's secret names, upper case only: `[A-Z_][A-Z0-9_]*`, leaving room for the longest suffix.
fn valid_prefix(prefix: &str) -> bool {
    !prefix.is_empty()
        && prefix.len() <= 80
        && !prefix.starts_with("GITHUB_")
        && prefix.chars().next().is_some_and(|c| c.is_ascii_uppercase() || c == '_')
        && prefix.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
}

fn valid_account_id(id: &str) -> bool {
    id.len() == 32 && id.chars().all(|c| c.is_ascii_hexdigit())
}

/// R2's bucket names: 3 to 63 of `a-z0-9-`, not starting or ending with `-`.
fn valid_bucket(bucket: &str) -> bool {
    (3..=63).contains(&bucket.len())
        && bucket.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !bucket.starts_with('-')
        && !bucket.ends_with('-')
}

/// `90d`, `12h`, `45m`: a key always expires, at most a year out.
fn parse_ttl(text: &str) -> Result<Duration, UsageError> {
    let bad = || {
        UsageError::new(format!("--ttl {text:?}: expected a number and d, h or m (at most 365d)"))
    };
    let (number, unit) = text.split_at(text.len().saturating_sub(1));
    let n: u64 = number.parse().map_err(|_| bad())?;
    let seconds = match unit {
        "d" => n.checked_mul(86_400),
        "h" => n.checked_mul(3_600),
        "m" => n.checked_mul(60),
        _ => None,
    }
    .ok_or_else(bad)?;
    let ttl = Duration::from_secs(seconds);
    if ttl.is_zero() || ttl > MAX_TTL {
        return Err(bad());
    }
    Ok(ttl)
}

pub(super) fn parse(args: &[String]) -> Result<Command, UsageError> {
    let usage = || UsageError::new(USAGE);
    let Some((verb, rest)) = args.split_first() else { return Ok(Command::Help) };
    match (verb.as_str(), rest) {
        ("--help" | "-h" | "help", []) => Ok(Command::Help),
        ("ls" | "list", []) => Ok(Command::Ls),
        ("revoke", [id])
            if !id.is_empty()
                && id.len() <= 64
                && id.chars().all(|c| c.is_ascii_alphanumeric()) =>
        {
            Ok(Command::Revoke { id: id.clone() })
        }
        ("connect", [provider, flag, account])
            if provider == "cloudflare" && flag == "--account" =>
        {
            if !valid_account_id(account) {
                return Err(UsageError::new(format!(
                    "--account {account:?} is not a Cloudflare account id (32 hex)"
                )));
            }
            Ok(Command::Connect { account: account.to_ascii_lowercase() })
        }
        ("mint", [kind, flags @ ..]) if kind == "cloudflare-r2" => {
            parse_mint_r2(flags).map(Command::MintR2)
        }
        _ => Err(usage()),
    }
}

fn parse_mint_r2(flags: &[String]) -> Result<MintR2, UsageError> {
    let mut mint = MintR2 {
        account: None,
        bucket: String::new(),
        write: false,
        ttl: DEFAULT_TTL,
        create_bucket: false,
        expire_objects_days: None,
        stores: Vec::new(),
    };
    let mut access = None;
    let mut it = flags.iter();
    while let Some(flag) = it.next() {
        let mut value =
            || it.next().cloned().ok_or_else(|| UsageError::new(format!("{flag} needs a value")));
        match flag.as_str() {
            "--bucket" => mint.bucket = value()?,
            "--account" => {
                let account = value()?;
                if !valid_account_id(&account) {
                    return Err(UsageError::new(format!(
                        "--account {account:?} is not a Cloudflare account id"
                    )));
                }
                mint.account = Some(account.to_ascii_lowercase());
            }
            "--rw" | "--ro" if access.is_some() => {
                return Err(UsageError::new("give one of --rw and --ro"));
            }
            "--rw" => access = Some(true),
            "--ro" => access = Some(false),
            "--ttl" => mint.ttl = parse_ttl(&value()?)?,
            "--create-bucket" => mint.create_bucket = true,
            "--expire-objects-days" => {
                let days: u32 = value()?.parse().map_err(|_| {
                    UsageError::new("--expire-objects-days takes a whole number of days")
                })?;
                if !(1..=3650).contains(&days) {
                    return Err(UsageError::new("--expire-objects-days is 1 to 3650"));
                }
                mint.expire_objects_days = Some(days);
            }
            "--store" => mint.stores.push(Store::parse(&value()?)?),
            other => return Err(UsageError::new(format!("unknown flag {other:?}\n{USAGE}"))),
        }
    }
    if !valid_bucket(&mint.bucket) {
        return Err(UsageError::new("--bucket NAME is required: 3 to 63 of a-z, 0-9 and -"));
    }
    mint.write = access.ok_or_else(|| UsageError::new("give --rw or --ro"))?;
    if mint.stores.is_empty() {
        return Err(UsageError::new(
            "give at least one --store: a minted key that is stored nowhere is lost",
        ));
    }
    Ok(mint)
}

/// One HTTP call to a provider: status and JSON body. A trait so tests drive the flow with no network.
pub(super) trait Http {
    fn call(
        &self,
        method: &str,
        url: &str,
        bearer: &str,
        body: Option<&Value>,
    ) -> Result<(u16, Value), String>;
    /// Waits between retries while a fresh token propagates; tests make it instant.
    fn pause(&self, _attempt: u32) {}
}

/// Reads a bootstrap token and writes minted values. A trait so tests never touch the Keychain or gh.
pub(super) trait Sinks {
    fn provider_token(&self, provider_account: &str) -> Result<Zeroizing<String>, String>;
    fn save_provider_token(&self, provider_account: &str, token: &str) -> Result<(), String>;
    fn read_bootstrap(&self) -> Result<Zeroizing<String>, String>;
    fn put(&self, store: &Store, name: &str, value: &str) -> Result<(), String>;
}

struct Live {
    runtime: tokio::runtime::Runtime,
    client: reqwest::Client,
}

impl Live {
    fn new() -> Result<Self, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("cannot start the HTTP runtime: {e}"))?;
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .user_agent(concat!("cmux-keys/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| format!("cannot build the HTTP client: {e}"))?;
        Ok(Self { runtime, client })
    }
}

impl Http for Live {
    fn call(
        &self,
        method: &str,
        url: &str,
        bearer: &str,
        body: Option<&Value>,
    ) -> Result<(u16, Value), String> {
        let method = reqwest::Method::from_bytes(method.as_bytes()).map_err(|e| e.to_string())?;
        let mut request = self.client.request(method, url).bearer_auth(bearer);
        if let Some(body) = body {
            request = request.json(body);
        }
        self.runtime.block_on(async {
            // The error names the URL, never the bearer.
            let response =
                request.send().await.map_err(|e| format!("{url}: {}", e.without_url()))?;
            let status = response.status().as_u16();
            let text = response.text().await.map_err(|e| format!("{url}: {e}"))?;
            Ok((status, serde_json::from_str(&text).unwrap_or(Value::Null)))
        })
    }

    fn pause(&self, attempt: u32) {
        std::thread::sleep(Duration::from_secs(u64::from(attempt.min(5)) * 2));
    }
}

struct LiveSinks;

impl Sinks for LiveSinks {
    fn provider_token(&self, provider_account: &str) -> Result<Zeroizing<String>, String> {
        if std::env::consts::OS != "macos" {
            return Err("provider tokens live in this Mac's Keychain: run cmux keys on the Mac that connected the provider".into());
        }
        let output = cmux_process::Command::new("/usr/bin/security")
            .args(["find-generic-password", "-s", PROVIDER_SERVICE, "-a", provider_account, "-w"])
            .stderr(cmux_process::Stdio::null())
            .output()
            .map_err(|e| format!("cannot run security: {e}"))?;
        let raw = Zeroizing::new(output.stdout);
        if !output.status.success() {
            return Err(format!(
                "no provider {provider_account} on this Mac: connect it once with cmux keys connect"
            ));
        }
        let text = std::str::from_utf8(&raw)
            .map_err(|_| "the stored provider token is not text".to_owned())?;
        Ok(Zeroizing::new(text.trim_end_matches('\n').to_owned()))
    }

    fn save_provider_token(&self, provider_account: &str, token: &str) -> Result<(), String> {
        if std::env::consts::OS != "macos" {
            return Err(
                "provider tokens live in this Mac's Keychain: connect on the Mac with the cmux app"
                    .into(),
            );
        }
        let store = acpmux::cli::harness_secret::store_item(
            "macos",
            PROVIDER_SERVICE,
            provider_account,
            &format!("cmux keys provider {provider_account}"),
            token,
        )
        .map_err(|e| e.to_string())?;
        acpmux::cli::harness_secret::run_store(&store).map_err(|e| e.to_string())
    }

    fn read_bootstrap(&self) -> Result<Zeroizing<String>, String> {
        acpmux::cli::harness_secret::read_value("Cloudflare bootstrap token")
            .map_err(|e| e.to_string())
    }

    fn put(&self, store: &Store, name: &str, value: &str) -> Result<(), String> {
        match store {
            Store::GhSecret { repo, environment, .. } => {
                let mut args =
                    vec!["secret", "set", name, "--repo", repo.as_str(), "--app", "actions"];
                if let Some(env) = environment {
                    args.extend(["--env", env.as_str()]);
                }
                // gh reads the value from stdin when it is not a terminal: never argv, never a file.
                pipe_to("gh", &args, value, &format!("gh secret set {name} --repo {repo}"))
            }
            Store::Keychain { scope, .. } => {
                let account = format!("{}/{name}", scope.as_deref().unwrap_or("*"));
                super::cloud_secret::store_value(&account, value)
            }
            Store::Vault { .. } => pipe_to(
                "acpmux",
                &["machine", "vault", "keep", name, "--env"],
                value,
                &format!("acpmux machine vault keep {name}"),
            ),
        }
    }
}

/// Runs `program args` with `value` on its stdin (never argv, never a file); `what` names it in errors,
/// with the program's own stderr, which never echoes stdin.
fn pipe_to(program: &str, args: &[&str], value: &str, what: &str) -> Result<(), String> {
    let mut child = cmux_process::Command::new(program)
        .args(args)
        .stdin(cmux_process::Stdio::piped())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot run {program}: {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(value.as_bytes()).map_err(|e| format!("{what}: {e}"))?;
    }
    let output = child.wait_with_output().map_err(|e| format!("{what}: {e}"))?;
    if !output.status.success() {
        let why = String::from_utf8_lossy(&output.stderr);
        return Err(format!("{what} failed: {}", why.trim().chars().take(300).collect::<String>()));
    }
    Ok(())
}

/// Where the audit lives; a struct so tests point it at a temporary folder.
pub(super) struct Paths {
    audit: PathBuf,
}

impl Paths {
    fn home() -> Result<Self, String> {
        let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
        Ok(Self { audit: PathBuf::from(home).join(".config/cmux/keys.json") })
    }
}

/// The audit: `{"version":1,"providers":[...],"keys":[...]}`, names and ids only.
fn read_audit(path: &Path) -> Result<Value, String> {
    match std::fs::read(path) {
        Ok(bytes) => {
            let value: Value = serde_json::from_slice(&bytes)
                .map_err(|_| format!("{} is not a keys audit; fix or move it", path.display()))?;
            if value.get("version") != Some(&json!(1))
                || !value.get("providers").is_some_and(Value::is_array)
                || !value.get("keys").is_some_and(Value::is_array)
            {
                return Err(format!("{} is not a keys audit (version 1)", path.display()));
            }
            Ok(value)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Ok(json!({"version": 1, "providers": [], "keys": []}))
        }
        Err(e) => Err(format!("cannot read {}: {e}", path.display())),
    }
}

fn write_audit(path: &Path, audit: &Value) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt as _;
    let folder = path.parent().ok_or("the audit has no folder")?;
    std::fs::create_dir_all(folder).map_err(|e| e.to_string())?;
    let temporary = folder.join(format!(".keys.json.{}", std::process::id()));
    let _ = std::fs::remove_file(&temporary);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|e| e.to_string())?;
    file.write_all(serde_json::to_string_pretty(audit).map_err(|e| e.to_string())?.as_bytes())
        .and_then(|()| file.sync_all())
        .map_err(|e| e.to_string())?;
    std::fs::rename(&temporary, path).map_err(|e| e.to_string())
}

/// Holds `keys.json.lock` for one read-modify-write; released on drop.
struct AuditLock(#[allow(dead_code)] cmux_file_lock::FileLock);

impl AuditLock {
    fn take(audit: &Path) -> Result<Self, String> {
        use std::os::unix::fs::OpenOptionsExt as _;
        let folder = audit.parent().ok_or("the audit has no folder")?;
        std::fs::create_dir_all(folder).map_err(|e| e.to_string())?;
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(audit.with_extension("json.lock"))
            .map_err(|e| format!("cannot open the audit lock: {e}"))?;
        // Blocks until another `cmux keys` run releases it.
        cmux_file_lock::FileLock::take(file, cmux_file_lock::Kind::Exclusive)
            .map(Self)
            .map_err(|e| format!("cannot lock the audit: {e}"))
    }
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// RFC 3339 UTC, seconds precision, as Cloudflare's `expires_on` takes it.
fn rfc3339(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3_600,
        rem % 3_600 / 60,
        rem % 60
    )
}

/// Who asked for a key, for the audit: the agent session when one is known, else the user.
fn requester() -> String {
    for var in ["CMUX_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CODEX_SESSION_ID", "ACPMUX_SESSION"] {
        if let Ok(value) = std::env::var(var)
            && !value.is_empty()
            && value.len() <= 128
        {
            return format!("{var}={value}");
        }
    }
    std::env::var("USER").map(|u| format!("user={u}")).unwrap_or_else(|_| "unknown".into())
}

/// One Cloudflare API call: its `result`, or an error naming the status and Cloudflare's own codes.
fn cloudflare(
    http: &dyn Http,
    method: &str,
    path: &str,
    bearer: &str,
    body: Option<&Value>,
) -> Result<Value, (u16, String)> {
    let url = format!("{CLOUDFLARE_API}{path}");
    let (status, answer) = http.call(method, &url, bearer, body).map_err(|e| (0, e))?;
    if (200..300).contains(&status) && answer.get("success") != Some(&json!(false)) {
        return Ok(answer.get("result").cloned().unwrap_or(Value::Null));
    }
    let errors: Vec<String> = answer
        .get("errors")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .map(|e| {
                    format!(
                        "{} {}",
                        e.get("code").unwrap_or(&Value::Null),
                        e.get("message").and_then(Value::as_str).unwrap_or("")
                    )
                })
                .collect()
        })
        .unwrap_or_default();
    Err((status, format!("Cloudflare {method} {path}: HTTP {status} {}", errors.join("; "))))
}

/// The ids of the named permission groups, read from the account (the names are Cloudflare's).
fn permission_groups(
    http: &dyn Http,
    account: &str,
    bootstrap: &str,
    names: &[&str],
) -> Result<Vec<String>, String> {
    let list = cloudflare(http, "GET", &format!("/accounts/{account}/tokens/permission_groups"), bootstrap, None)
        .map_err(|(status, message)| match status {
            401 | 403 => format!("{message}\nthe connected token cannot read permission groups: it needs Account API Tokens Edit"),
            _ => message,
        })?;
    let list = list.as_array().ok_or("Cloudflare's permission groups are not a list")?;
    names
        .iter()
        .map(|name| {
            list.iter()
                .find(|group| group.get("name").and_then(Value::as_str) == Some(name))
                .and_then(|group| group.get("id").and_then(Value::as_str))
                .map(str::to_owned)
                .ok_or_else(|| {
                    format!("Cloudflare has no permission group {name:?} for this account")
                })
        })
        .collect()
}

/// A minted Cloudflare token: its id (public) and value (secret).
struct Minted {
    id: String,
    value: Zeroizing<String>,
}

fn mint_token(
    http: &dyn Http,
    account: &str,
    bootstrap: &str,
    name: &str,
    resources: Value,
    group: &str,
    expires: u64,
) -> Result<Minted, String> {
    let body = json!({
        "name": name,
        "policies": [{"effect": "allow", "resources": resources, "permission_groups": [{"id": group}]}],
        "expires_on": rfc3339(expires),
    });
    let mut result =
        cloudflare(http, "POST", &format!("/accounts/{account}/tokens"), bootstrap, Some(&body))
            .map_err(|(_, message)| message)?;
    let id = result
        .get("id")
        .and_then(Value::as_str)
        .ok_or("Cloudflare's new token has no id")?
        .to_owned();
    let value = match result.get_mut("value").map(Value::take) {
        Some(Value::String(value)) if !value.is_empty() => Zeroizing::new(value),
        _ => return Err("Cloudflare's new token has no value".into()),
    };
    Ok(Minted { id, value })
}

fn delete_token(http: &dyn Http, account: &str, bootstrap: &str, id: &str) -> Result<(), String> {
    match cloudflare(http, "DELETE", &format!("/accounts/{account}/tokens/{id}"), bootstrap, None) {
        Ok(_) => Ok(()),
        Err((404, _)) => Ok(()),
        Err((_, message)) => Err(message),
    }
}

/// A call with a token minted seconds ago: Cloudflare may answer 401/403 until it propagates.
fn with_fresh_token<T>(
    http: &dyn Http,
    mut call: impl FnMut() -> Result<T, (u16, String)>,
) -> Result<T, (u16, String)> {
    let mut attempt = 0;
    loop {
        match call() {
            Err((401 | 403, _)) if attempt < 6 => {
                attempt += 1;
                http.pause(attempt);
            }
            other => return other,
        }
    }
}

/// Makes sure the bucket exists (creating it only with --create-bucket) and, with
/// --expire-objects-days, sets its lifecycle, using a 15-minute admin token that is revoked after.
fn set_up_bucket(
    http: &dyn Http,
    account: &str,
    bootstrap: &str,
    mint: &MintR2,
    admin_group: &str,
) -> Result<Value, String> {
    let setup = mint_token(
        http,
        account,
        bootstrap,
        &format!("cmux keys: set up R2 bucket {} (15 min)", mint.bucket),
        json!({format!("com.cloudflare.api.account.{account}"): "*"}),
        admin_group,
        now_secs() + SETUP_TTL.as_secs(),
    )?;
    let outcome = (|| {
        let bucket_path = format!("/accounts/{account}/r2/buckets/{}", mint.bucket);
        let mut created = false;
        match with_fresh_token(http, || cloudflare(http, "GET", &bucket_path, &setup.value, None)) {
            Ok(_) => {}
            Err((404, _)) if mint.create_bucket => {
                with_fresh_token(http, || {
                    cloudflare(
                        http,
                        "POST",
                        &format!("/accounts/{account}/r2/buckets"),
                        &setup.value,
                        Some(&json!({"name": mint.bucket})),
                    )
                })
                .map_err(|(_, m)| m)?;
                created = true;
            }
            Err((404, _)) => {
                return Err(format!(
                    "R2 bucket {} does not exist: add --create-bucket to make it",
                    mint.bucket
                ));
            }
            Err((_, message)) => return Err(message),
        }
        let mut lifecycle = Value::Null;
        if let Some(days) = mint.expire_objects_days {
            // PUT replaces every rule the bucket had: this one rule is the whole lifecycle afterwards.
            let rules = json!({"rules": [{
                "id": format!("expire-after-{days}d"),
                "enabled": true,
                "conditions": {"prefix": ""},
                "deleteObjectsTransition": {"condition": {"type": "Age", "maxAge": u64::from(days) * 86_400}},
            }]});
            with_fresh_token(http, || {
                cloudflare(
                    http,
                    "PUT",
                    &format!("{bucket_path}/lifecycle"),
                    &setup.value,
                    Some(&rules),
                )
            })
            .map_err(|(_, m)| m)?;
            lifecycle = json!({"delete_objects_after_days": days});
        }
        Ok(json!({"bucket": mint.bucket, "created": created, "lifecycle": lifecycle}))
    })();
    let revoked = delete_token(http, account, bootstrap, &setup.id);
    match (outcome, revoked) {
        (Ok(value), Ok(())) => Ok(value),
        (Ok(_), Err(message)) => Err(format!(
            "the bucket is set up, but its 15-minute setup token {} was not revoked: {message}",
            setup.id
        )),
        (Err(message), _) => Err(message),
    }
}

/// The one connected Cloudflare account, or the one --account names.
fn cloudflare_account(audit: &Value, wanted: Option<&str>) -> Result<String, String> {
    let connected: Vec<&str> = audit["providers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|p| p.get("provider").and_then(Value::as_str) == Some("cloudflare"))
        .filter_map(|p| p.get("account").and_then(Value::as_str))
        .collect();
    match (wanted, connected.as_slice()) {
        (Some(want), list) if list.contains(&want) => Ok(want.to_owned()),
        (Some(want), _) => Err(format!("Cloudflare account {want} is not connected: cmux keys connect cloudflare --account {want}")),
        (None, [one]) => Ok((*one).to_owned()),
        (None, []) => Err("no Cloudflare account is connected: cmux keys connect cloudflare --account ACCOUNT_ID (docs/cmux-next/keys.md)".into()),
        (None, _) => Err("several Cloudflare accounts are connected: name one with --account".into()),
    }
}

pub(super) fn run(
    command: Command,
    paths: &Paths,
    http: &dyn Http,
    sinks: &dyn Sinks,
) -> Result<Value, String> {
    match command {
        Command::Help => Ok(json!({"usage": USAGE})),
        Command::Ls => {
            let _lock = AuditLock::take(&paths.audit)?;
            let mut audit = read_audit(&paths.audit)?;
            let now = now_secs();
            for key in audit["keys"].as_array_mut().into_iter().flatten() {
                let expired =
                    key.get("expires_at_s").and_then(Value::as_u64).is_some_and(|at| at <= now);
                let state = if key.get("revoked_at").is_some_and(|v| !v.is_null()) {
                    "revoked"
                } else if expired {
                    "expired"
                } else {
                    "live"
                };
                key["state"] = json!(state);
            }
            Ok(audit)
        }
        Command::Connect { account } => {
            let token = sinks.read_bootstrap()?;
            // Proof the token works and can mint: it is active, and it reads the permission groups
            // (only a token with Account API Tokens Read or Edit can).
            let verify = cloudflare(http, "GET", &format!("/accounts/{account}/tokens/verify"), &token, None).map_err(|(status, message)| match status {
                401 | 403 => format!("{message}\nthis is not an account-owned token of account {account}: make it under Manage Account > Account API Tokens"),
                _ => message,
            })?;
            if verify.get("status").and_then(Value::as_str) != Some("active") {
                return Err("Cloudflare says the token is not active".into());
            }
            permission_groups(http, &account, &token, &[R2_ITEM_WRITE])?;
            let provider_account = format!("cloudflare/{account}");
            sinks.save_provider_token(&provider_account, &token)?;
            drop(token);
            let _lock = AuditLock::take(&paths.audit)?;
            let mut audit = read_audit(&paths.audit)?;
            let providers = audit["providers"].as_array_mut().ok_or("bad audit")?;
            providers
                .retain(|p| !(p["provider"] == "cloudflare" && p["account"] == account.as_str()));
            providers.push(json!({"provider": "cloudflare", "account": account, "connected_at": rfc3339(now_secs()), "by": requester()}));
            write_audit(&paths.audit, &audit)?;
            Ok(
                json!({"connected": provider_account, "next": "cmux keys mint cloudflare-r2 --bucket B --rw --store SPEC"}),
            )
        }
        Command::MintR2(mint) => {
            let account = cloudflare_account(&read_audit(&paths.audit)?, mint.account.as_deref())?;
            let bootstrap = sinks.provider_token(&format!("cloudflare/{account}"))?;
            let item = if mint.write { R2_ITEM_WRITE } else { R2_ITEM_READ };
            let groups = permission_groups(http, &account, &bootstrap, &[item, R2_ADMIN_WRITE])?;
            let bucket = if mint.create_bucket || mint.expire_objects_days.is_some() {
                set_up_bucket(http, &account, &bootstrap, &mint, &groups[1])?
            } else {
                json!({"bucket": mint.bucket})
            };
            let access = if mint.write { "rw" } else { "ro" };
            let created_at = now_secs();
            let expires_at = created_at + mint.ttl.as_secs();
            let key = mint_token(
                http,
                &account,
                &bootstrap,
                &format!("cmux keys: R2 {} {access}", mint.bucket),
                json!({format!("com.cloudflare.edge.r2.bucket.{account}_default_{}", mint.bucket): "*"}),
                &groups[0],
                expires_at,
            )?;
            // R2's S3 credentials of an API token: the token id, and the SHA-256 of its value.
            let secret = Zeroizing::new(
                Sha256::digest(key.value.as_bytes())
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect::<String>(),
            );
            drop(key.value);
            let mut stored = Vec::new();
            for store in &mint.stores {
                for (suffix, value) in
                    [("ACCESS_KEY_ID", key.id.as_str()), ("SECRET_ACCESS_KEY", secret.as_str())]
                {
                    if let Err(message) = sinks.put(store, &store.name(suffix), value) {
                        // A key stored only in part is no use and must not linger: revoke it.
                        let revoked = delete_token(http, &account, &bootstrap, &key.id);
                        return Err(format!(
                            "{message}\nthe new key {} was {}; already stored: {}",
                            key.id,
                            if revoked.is_ok() {
                                "revoked"
                            } else {
                                "NOT revoked (cmux keys revoke it)"
                            },
                            if stored.is_empty() {
                                "nothing".to_owned()
                            } else {
                                stored.join(", ")
                            }
                        ));
                    }
                    stored.push(store.label(suffix));
                }
            }
            drop(secret);
            let record = json!({
                "id": key.id,
                "provider": "cloudflare",
                "account": account,
                "kind": "r2",
                "bucket": mint.bucket,
                "access": access,
                "created_at": rfc3339(created_at),
                "expires_at": rfc3339(expires_at),
                "expires_at_s": expires_at,
                "stores": stored,
                "by": requester(),
                "revoked_at": Value::Null,
            });
            let _lock = AuditLock::take(&paths.audit)?;
            let mut audit = read_audit(&paths.audit)?;
            audit["keys"].as_array_mut().ok_or("bad audit")?.push(record.clone());
            write_audit(&paths.audit, &audit).map_err(|e| {
                format!(
                    "the key {} is minted and stored, but the audit was not written: {e}",
                    key.id
                )
            })?;
            Ok(json!({"minted": record, "bucket": bucket}))
        }
        Command::Revoke { id } => {
            let _lock = AuditLock::take(&paths.audit)?;
            let mut audit = read_audit(&paths.audit)?;
            let key = audit["keys"]
                .as_array_mut()
                .and_then(|keys| keys.iter_mut().find(|k| k["id"] == id.as_str()))
                .ok_or_else(|| format!("no key {id} in the audit (cmux keys ls)"))?;
            let account =
                key["account"].as_str().ok_or("the audit record has no account")?.to_owned();
            let bootstrap = sinks.provider_token(&format!("cloudflare/{account}"))?;
            delete_token(http, &account, &bootstrap, &id)?;
            key["revoked_at"] = json!(rfc3339(now_secs()));
            let stores = key["stores"].clone();
            write_audit(&paths.audit, &audit)?;
            Ok(json!({"revoked": id, "stored_copies_now_dead": stores}))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    const ACCOUNT: &str = "0123456789abcdef0123456789abcdef";

    /// One recorded call: method, path, bearer, body.
    type Call = (String, String, String, Option<Value>);

    /// Answers Cloudflare calls from a script and records every call.
    struct FakeCloudflare {
        calls: RefCell<Vec<Call>>,
        bucket_exists: bool,
        fail_first_bucket_read: RefCell<bool>,
    }

    impl FakeCloudflare {
        fn new(bucket_exists: bool) -> Self {
            Self {
                calls: RefCell::new(Vec::new()),
                bucket_exists,
                fail_first_bucket_read: RefCell::new(true),
            }
        }
        fn paths(&self) -> Vec<String> {
            self.calls.borrow().iter().map(|(m, p, _, _)| format!("{m} {p}")).collect()
        }
    }

    impl Http for FakeCloudflare {
        fn call(
            &self,
            method: &str,
            url: &str,
            bearer: &str,
            body: Option<&Value>,
        ) -> Result<(u16, Value), String> {
            let path = url.strip_prefix(CLOUDFLARE_API).unwrap().to_owned();
            self.calls.borrow_mut().push((
                method.into(),
                path.clone(),
                bearer.into(),
                body.cloned(),
            ));
            let ok = |result: Value| Ok((200, json!({"success": true, "result": result})));
            let tokens = format!("/accounts/{ACCOUNT}/tokens");
            match (method, path.as_str()) {
                ("GET", p) if p == format!("{tokens}/verify") => ok(json!({"status": "active"})),
                ("GET", p) if p == format!("{tokens}/permission_groups") => ok(json!([
                    {"id": "g-admin", "name": R2_ADMIN_WRITE},
                    {"id": "g-write", "name": R2_ITEM_WRITE},
                    {"id": "g-read", "name": R2_ITEM_READ},
                ])),
                ("POST", p) if p == tokens => {
                    let name = body.unwrap()["name"].as_str().unwrap();
                    let id = if name.contains("set up") { "setup-id" } else { "key-id" };
                    ok(json!({"id": id, "value": format!("{id}-value")}))
                }
                ("DELETE", p) if p.starts_with(&tokens) => ok(json!({})),
                ("GET", p) if p.ends_with("/r2/buckets/handoff") => {
                    // A fresh token's first call: not yet propagated.
                    if self.fail_first_bucket_read.replace(false) {
                        return Ok((
                            403,
                            json!({"success": false, "errors": [{"code": 10000, "message": "Authentication error"}]}),
                        ));
                    }
                    if self.bucket_exists {
                        ok(json!({"name": "handoff"}))
                    } else {
                        Ok((404, json!({"success": false})))
                    }
                }
                ("POST", p) if p.ends_with("/r2/buckets") => ok(json!({"name": "handoff"})),
                ("PUT", p) if p.ends_with("/lifecycle") => ok(json!({})),
                _ => Ok((
                    500,
                    json!({"success": false, "errors": [{"code": 1, "message": "unexpected"}]}),
                )),
            }
        }
    }

    #[derive(Default)]
    struct FakeSinks {
        put: RefCell<Vec<(Store, String, String)>>,
        saved: RefCell<Vec<(String, String)>>,
        fail_put: bool,
    }

    impl Sinks for FakeSinks {
        fn provider_token(&self, _: &str) -> Result<Zeroizing<String>, String> {
            Ok(Zeroizing::new("bootstrap".into()))
        }
        fn save_provider_token(&self, account: &str, token: &str) -> Result<(), String> {
            self.saved.borrow_mut().push((account.into(), token.into()));
            Ok(())
        }
        fn read_bootstrap(&self) -> Result<Zeroizing<String>, String> {
            Ok(Zeroizing::new("bootstrap".into()))
        }
        fn put(&self, store: &Store, name: &str, value: &str) -> Result<(), String> {
            if self.fail_put {
                return Err("gh refused".into());
            }
            self.put.borrow_mut().push((store.clone(), name.into(), value.into()));
            Ok(())
        }
    }

    fn connected(dir: &tempfile::TempDir) -> Paths {
        let paths = Paths { audit: dir.path().join("keys.json") };
        run(
            Command::Connect { account: ACCOUNT.into() },
            &paths,
            &FakeCloudflare::new(true),
            &FakeSinks::default(),
        )
        .unwrap();
        paths
    }

    #[test]
    fn mint_parses_the_r2_ask_and_never_takes_a_value() {
        let Command::MintR2(mint) = parse(&words(
            "mint cloudflare-r2 --bucket cmux-ci-handoff --rw --ttl 180d --create-bucket --expire-objects-days 1 --store gh-secret:manaflow-ai/cmux:CI_HANDOFF_R2",
        ))
        .unwrap() else {
            panic!("not a mint")
        };
        assert_eq!(mint.bucket, "cmux-ci-handoff");
        assert!(mint.write && mint.create_bucket);
        assert_eq!(mint.ttl, Duration::from_secs(180 * 86_400));
        assert_eq!(mint.expire_objects_days, Some(1));
        assert_eq!(
            mint.stores,
            vec![Store::GhSecret {
                repo: "manaflow-ai/cmux".into(),
                environment: None,
                prefix: "CI_HANDOFF_R2".into()
            }]
        );
        for bad in [
            "mint cloudflare-r2 --bucket b --rw --store gh-secret:a/b:X", // bucket too short
            "mint cloudflare-r2 --bucket bucket --store gh-secret:a/b:X", // no access
            "mint cloudflare-r2 --bucket bucket --rw --ro --store gh-secret:a/b:X", // both
            "mint cloudflare-r2 --bucket bucket --rw",                    // stored nowhere
            "mint cloudflare-r2 --bucket bucket --rw --ttl 0d --store gh-secret:a/b:X",
            "mint cloudflare-r2 --bucket bucket --rw --ttl 400d --store gh-secret:a/b:X",
            "mint cloudflare-r2 --bucket bucket --rw --store gh-secret:a/b:lower",
            "mint cloudflare-r2 --bucket bucket --rw --store gh-secret:a/b:GITHUB_X",
            "mint cloudflare-r2 --bucket bucket --rw --store keychain:CMUX_X",
            "mint cloudflare-r2 --bucket bucket --rw --store s3:X",
            "connect cloudflare --account nothex",
            "connect cloudflare tok_live_value",
            "revoke",
        ] {
            assert!(parse(&words(bad)).is_err(), "{bad}");
        }
        assert_eq!(
            Store::parse("gh-secret:manaflow-ai/cmux@ci-cache-writer:CACHE")
                .unwrap()
                .label("ACCESS_KEY_ID"),
            "gh-secret:manaflow-ai/cmux@ci-cache-writer:CACHE_ACCESS_KEY_ID"
        );
        assert_eq!(
            Store::parse("keychain:Acme/App:R2").unwrap().label("ACCESS_KEY_ID"),
            "keychain:acme/app/R2_ACCESS_KEY_ID"
        );
        assert_eq!(
            Store::parse("vault:CI_R2").unwrap().label("SECRET_ACCESS_KEY"),
            "vault:CI_R2_SECRET_ACCESS_KEY"
        );
        assert!(Store::parse("vault:ci_r2").is_err());
    }

    #[test]
    fn connect_verifies_then_keeps_the_token_in_the_keychain_and_lists_the_provider() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths { audit: dir.path().join("keys.json") };
        let sinks = FakeSinks::default();
        let http = FakeCloudflare::new(true);
        run(Command::Connect { account: ACCOUNT.into() }, &paths, &http, &sinks).unwrap();
        assert_eq!(
            sinks.saved.borrow().as_slice(),
            &[(format!("cloudflare/{ACCOUNT}"), "bootstrap".to_owned())]
        );
        let audit = std::fs::read_to_string(&paths.audit).unwrap();
        assert!(!audit.contains("bootstrap"), "the audit never holds a value");
        assert!(audit.contains(ACCOUNT));
    }

    #[test]
    fn mint_sets_up_the_bucket_with_a_short_token_then_mints_a_bucket_scoped_key_and_stores_its_s3_pair()
     {
        let dir = tempfile::tempdir().unwrap();
        let paths = connected(&dir);
        let http = FakeCloudflare::new(false);
        let sinks = FakeSinks::default();
        let Command::MintR2(mint) = parse(&words(
            "mint cloudflare-r2 --bucket handoff --rw --create-bucket --expire-objects-days 1 --store gh-secret:manaflow-ai/cmux:CI_HANDOFF_R2",
        ))
        .unwrap() else {
            panic!()
        };
        let answer = run(Command::MintR2(mint), &paths, &http, &sinks).unwrap();
        let tokens = format!("/accounts/{ACCOUNT}/tokens");
        let buckets = format!("/accounts/{ACCOUNT}/r2/buckets");
        assert_eq!(
            http.paths(),
            vec![
                format!("GET {tokens}/permission_groups"),
                format!("POST {tokens}"),
                format!("GET {buckets}/handoff"),
                format!("GET {buckets}/handoff"),
                format!("POST {buckets}"),
                format!("PUT {buckets}/handoff/lifecycle"),
                format!("DELETE {tokens}/setup-id"),
                format!("POST {tokens}"),
            ]
        );
        let calls = http.calls.borrow();
        // Bucket work uses the setup token, never the bootstrap; the setup token is account-wide R2 admin.
        assert!(calls[2..6].iter().all(|(_, _, bearer, _)| bearer == "setup-id-value"));
        assert_eq!(
            calls[1].3.as_ref().unwrap()["policies"][0]["permission_groups"][0]["id"],
            "g-admin"
        );
        assert_eq!(
            calls[5].3.as_ref().unwrap()["rules"][0]["deleteObjectsTransition"]["condition"]["maxAge"],
            86_400
        );
        // The stored key is scoped to the one bucket, with item write only, and expires.
        let key = calls[7].3.as_ref().unwrap();
        assert_eq!(
            key["policies"][0]["resources"],
            json!({format!("com.cloudflare.edge.r2.bucket.{ACCOUNT}_default_handoff"): "*"})
        );
        assert_eq!(key["policies"][0]["permission_groups"][0]["id"], "g-write");
        assert!(key["expires_on"].as_str().unwrap().ends_with('Z'));
        let put = sinks.put.borrow();
        let expected_secret: String =
            Sha256::digest(b"key-id-value").iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(put[0].1, "CI_HANDOFF_R2_ACCESS_KEY_ID");
        assert_eq!(put[0].2, "key-id");
        assert_eq!(put[1].1, "CI_HANDOFF_R2_SECRET_ACCESS_KEY");
        assert_eq!(put[1].2, expected_secret);
        assert_eq!(answer["bucket"]["created"], true);
        let audit = std::fs::read_to_string(&paths.audit).unwrap();
        assert!(
            !audit.contains("key-id-value") && !audit.contains(&expected_secret),
            "no value in the audit"
        );
        assert!(audit.contains("gh-secret:manaflow-ai/cmux:CI_HANDOFF_R2_SECRET_ACCESS_KEY"));
    }

    #[test]
    fn a_key_that_cannot_be_stored_is_revoked_and_left_out_of_the_audit() {
        let dir = tempfile::tempdir().unwrap();
        let paths = connected(&dir);
        let http = FakeCloudflare::new(true);
        let sinks = FakeSinks { fail_put: true, ..FakeSinks::default() };
        let Command::MintR2(mint) =
            parse(&words("mint cloudflare-r2 --bucket handoff --ro --store gh-secret:a/b:R2"))
                .unwrap()
        else {
            panic!()
        };
        let error = run(Command::MintR2(mint), &paths, &http, &sinks).unwrap_err();
        assert!(error.contains("revoked"), "{error}");
        assert!(http.paths().last().unwrap().ends_with("/tokens/key-id"));
        assert!(!std::fs::read_to_string(&paths.audit).unwrap().contains("key-id"));
    }

    #[test]
    fn revoke_deletes_at_the_provider_and_ls_shows_it() {
        let dir = tempfile::tempdir().unwrap();
        let paths = connected(&dir);
        let http = FakeCloudflare::new(true);
        let Command::MintR2(mint) =
            parse(&words("mint cloudflare-r2 --bucket handoff --ro --store gh-secret:a/b:R2"))
                .unwrap()
        else {
            panic!()
        };
        run(Command::MintR2(mint), &paths, &http, &FakeSinks::default()).unwrap();
        let listed = run(Command::Ls, &paths, &http, &FakeSinks::default()).unwrap();
        assert_eq!(listed["keys"][0]["state"], "live");
        run(Command::Revoke { id: "key-id".into() }, &paths, &http, &FakeSinks::default()).unwrap();
        assert_eq!(
            http.paths().last().unwrap(),
            &format!("DELETE /accounts/{ACCOUNT}/tokens/key-id")
        );
        assert_eq!(
            run(Command::Ls, &paths, &http, &FakeSinks::default()).unwrap()["keys"][0]["state"],
            "revoked"
        );
    }

    #[test]
    fn times_are_rfc3339_utc() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(1_794_700_800), "2026-11-15T00:00:00Z");
        assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
    }
}
