//! `cmux keys`: connect a key provider once, then let agents mint narrowly scoped, expiring keys and
//! store them, with no click per key.
//!
//!     cmux keys connect cloudflare --account ACCOUNT_ID      the one-time bootstrap token, from a no-echo
//!                                                            prompt or stdin, never argv
//!     cmux keys mint cloudflare-r2 --bucket B (--rw|--ro) [--ttl 90d] [--create-bucket]
//!         [--expire-objects-days N] --store SPEC [--store SPEC]
//!     cmux keys mint cloudflare-r2 --via MAC --bucket B (--rw|--ro) ... --store SPEC
//!                                                            from a machine without the bootstrap (a Linux
//!                                                            host): MAC's broker mints over the acpmux peer
//!                                                            link and sends back only the scoped key
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
//!
//! Keys from any other provider (one an agent got from an API or CLI, one the person pastes once, a
//! generated one) are stored, used as env, written and filled by `local.rs`: `cmux keys put|generate|
//! request|use|write|fill|rm`. Cloudflare minting is one provider among them.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use zeroize::Zeroizing;

use super::UsageError;

pub(super) mod local;
mod store;

pub(super) use store::Store;

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

const USAGE: &str = "usage: cmux keys ls\n       cmux keys revoke ID|NAME\n       \
cmux keys connect cloudflare --account ACCOUNT_ID\n       \
cmux keys mint cloudflare-r2 --bucket B (--rw|--ro) [--ttl 90d] [--create-bucket] [--expire-objects-days N] [--via MACHINE] --store SPEC...\n\
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
        println!("{USAGE}\n       {}", local::USAGE);
        return Some(0);
    }
    if let Command::Local(local::Local::Use(run)) = &command {
        // The command's own exit code and output (masked), not a reply.
        let ran = Paths::home().and_then(|paths| {
            local::run_use(&paths, &local::OsVault, run, std::io::stdout(), std::io::stderr())
        });
        return Some(match ran {
            Ok(code) => code,
            Err(message) => {
                super::app::failure("keys.failed", &format!("cmux: {message}"), global.output, 1)
            }
        });
    }
    let result = Paths::home().and_then(|paths| match command {
        Command::Local(local) => local::run(
            local,
            &paths,
            &local::OsVault,
            &LiveSinks,
            &local::LiveApp(&global),
            &|name| acpmux::cli::harness_secret::read_value(name).map_err(|e| e.to_string()),
        ),
        Command::MintR2(mint) if mint.via.is_some() => {
            mint_via(mint, &paths, &LivePeerBroker, &LiveSinks)
        }
        command => run(command, &paths, &Live::new()?, &LiveSinks, &local::OsVault),
    });
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
    Connect {
        account: String,
    },
    MintR2(MintR2),
    Ls,
    Revoke {
        id: String,
    },
    /// Keys from any provider: put, generate, request, use, write, fill.
    Local(local::Local),
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
    /// `--via MACHINE`: the peer whose broker holds the bootstrap mints the key and sends back only
    /// it, over the acpmux peer link (`acpmux` `server/keys_relay.rs`); this machine stores it.
    via: Option<String>,
    /// `--reply-to-machine NAME`: the key goes back to the asking machine on stdout (a pipe the
    /// acpmux relay reads), stored nowhere here. Only the relay runs this.
    reply_to: Option<String>,
}

/// A machine's name as the relay passes it: printable, at most 256 characters.
fn valid_machine(name: &str) -> bool {
    !name.is_empty() && name.len() <= 256 && !name.chars().any(char::is_control)
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
    if let Some(local) = local::parse(verb, rest) {
        return local.map(Command::Local);
    }
    match (verb.as_str(), rest) {
        ("--help" | "-h" | "help", []) => Ok(Command::Help),
        ("ls" | "list", []) => Ok(Command::Ls),
        // A minted key's provider id, or a stored key's NAME.
        ("revoke" | "rm", [id])
            if !id.is_empty()
                && id.len() <= 80
                && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') =>
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
        via: None,
        reply_to: None,
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
            "--via" | "--reply-to-machine" => {
                let machine = value()?;
                if !valid_machine(&machine) {
                    return Err(UsageError::new(format!(
                        "{flag} {machine:?} is not a machine name"
                    )));
                }
                if flag == "--via" {
                    mint.via = Some(machine);
                } else {
                    mint.reply_to = Some(machine);
                }
            }
            other => return Err(UsageError::new(format!("unknown flag {other:?}\n{USAGE}"))),
        }
    }
    if !valid_bucket(&mint.bucket) {
        return Err(UsageError::new("--bucket NAME is required: 3 to 63 of a-z, 0-9 and -"));
    }
    mint.write = access.ok_or_else(|| UsageError::new("give --rw or --ro"))?;
    if mint.reply_to.is_some() {
        if !mint.stores.is_empty() || mint.via.is_some() {
            return Err(UsageError::new(
                "--reply-to-machine sends the key back to the asking machine: no --store or --via",
            ));
        }
        return Ok(mint);
    }
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

pub(super) struct LiveSinks;

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
            Store::Vault { hosts, .. } => {
                let mut args = vec!["machine", "vault", "keep", name];
                if hosts.is_empty() {
                    args.push("--env");
                }
                for host in hosts {
                    args.extend(["--host", host.as_str()]);
                }
                pipe_to("acpmux", &args, value, &format!("acpmux machine vault keep {name}"))
            }
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

/// Names this build's audit: a DEV app sets it for its terminals (Swift `BuildStatePaths`), so a dev
/// build never reads or changes nightly's or another tag's list.
pub(super) const AUDIT_OVERRIDE: &str = "CMUX_NEXT_KEYS_AUDIT_FILE";

impl Paths {
    pub(super) fn home() -> Result<Self, String> {
        let other_app = crate::app_identity::this_process_in_other_apps_terminal();
        Self::from_env(|key| std::env::var_os(key).filter(|v| !v.is_empty()), other_app)
    }

    /// `$CMUX_NEXT_KEYS_AUDIT_FILE`, else `$HOME/.config/cmux/keys.json`. A `cmux` bundled in another
    /// app than the terminal's (`other_app`) ignores the variable: it is that app's audit.
    pub(super) fn from_env(
        env: impl Fn(&str) -> Option<std::ffi::OsString>,
        other_app: bool,
    ) -> Result<Self, String> {
        if !other_app && let Some(path) = env(AUDIT_OVERRIDE) {
            return Ok(Self { audit: PathBuf::from(path) });
        }
        let home = env("HOME").ok_or("HOME is not set")?;
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

/// Every provider and every key, each with its state and the fields a list shows, never a value.
pub(super) fn list(paths: &Paths) -> Result<Value, String> {
    let _lock = AuditLock::take(&paths.audit)?;
    let mut audit = read_audit(&paths.audit)?;
    let now = now_secs();
    for key in local::array_mut(&mut audit, "keys").into_iter().flatten() {
        local::listed(key, now);
    }
    Ok(audit)
}

pub(super) fn run(
    command: Command,
    paths: &Paths,
    http: &dyn Http,
    sinks: &dyn Sinks,
    vault: &dyn local::KeyVault,
) -> Result<Value, String> {
    match command {
        Command::Help => Ok(json!({"usage": USAGE})),
        Command::Ls => list(paths),
        Command::Local(_) => Err("a stored key's command: local::run".into()),
        Command::Revoke { id }
            if read_audit(&paths.audit)?.get("keys").and_then(Value::as_array).is_some_and(
                |keys| {
                    keys.iter()
                        .any(|k| local::is_local(k) && local::field(k, "name") == id.as_str())
                },
            ) =>
        {
            local::revoke(paths, vault, &id)
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
            if let Some(machine) = &mint.reply_to {
                // The asking machine stores it: here the audit records where it went, and the
                // answer carries the pair to the relay's pipe. The bootstrap is not in it.
                let record = key_record(&key.id, &account, &mint, access, created_at, expires_at)
                    .with_stores(vec![format!("machine:{machine}")], format!("machine={machine}"));
                append_audit(paths, &record, &key.id)?;
                return Ok(json!({
                    "minted": record,
                    "bucket": bucket,
                    "values": {"ACCESS_KEY_ID": key.id, "SECRET_ACCESS_KEY": secret.as_str()},
                }));
            }
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
            let record = key_record(&key.id, &account, &mint, access, created_at, expires_at)
                .with_stores(stored, requester());
            append_audit(paths, &record, &key.id)?;
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

/// A minted key's audit record, before its stores and asker.
fn key_record(
    id: &str,
    account: &str,
    mint: &MintR2,
    access: &str,
    created_at: u64,
    expires_at: u64,
) -> Value {
    json!({
        "id": id,
        "provider": "cloudflare",
        "account": account,
        "kind": "r2",
        "bucket": mint.bucket,
        "access": access,
        "created_at": rfc3339(created_at),
        "expires_at": rfc3339(expires_at),
        "expires_at_s": expires_at,
        "revoked_at": Value::Null,
    })
}

trait WithStores {
    fn with_stores(self, stores: Vec<String>, by: String) -> Value;
}

impl WithStores for Value {
    fn with_stores(mut self, stores: Vec<String>, by: String) -> Value {
        self["stores"] = json!(stores);
        self["by"] = json!(by);
        self
    }
}

fn append_audit(paths: &Paths, record: &Value, id: &str) -> Result<(), String> {
    let _lock = AuditLock::take(&paths.audit)?;
    let mut audit = read_audit(&paths.audit)?;
    audit["keys"].as_array_mut().ok_or("bad audit")?.push(record.clone());
    write_audit(&paths.audit, &audit).map_err(|e| {
        format!("the key {id} is minted and stored, but the audit was not written: {e}")
    })
}

/// Asks another machine's broker for a key over the acpmux peer link. A trait so tests answer
/// without a daemon.
pub(super) trait PeerBroker {
    fn mint(&self, ask: Value) -> Result<Value, String>;
}

struct LivePeerBroker;

impl PeerBroker for LivePeerBroker {
    fn mint(&self, ask: Value) -> Result<Value, String> {
        acpmux::computer_use::client::acpmux_request(acpmux::rpc::method::MUX_KEYS_MINT, ask)
            .map_err(|e| e.to_string())
    }
}

/// `cmux keys mint ... --via MACHINE`: that machine's broker mints with the bootstrap it keeps and
/// sends back the scoped key alone; this machine stores it in its own `--store`s and audit. The
/// bootstrap never comes here, and the pair is never printed.
pub(super) fn mint_via(
    mint: MintR2,
    paths: &Paths,
    broker: &dyn PeerBroker,
    sinks: &dyn Sinks,
) -> Result<Value, String> {
    let machine = mint.via.clone().ok_or("--via names the minting machine")?;
    let mut ask = json!({
        "machine": machine,
        "kind": "cloudflare-r2",
        "bucket": mint.bucket,
        "access": if mint.write { "rw" } else { "ro" },
        "ttl": format!("{}m", mint.ttl.as_secs() / 60),
    });
    if let Some(account) = &mint.account {
        ask["account"] = json!(account);
    }
    if mint.create_bucket {
        ask["create_bucket"] = json!(true);
    }
    if let Some(days) = mint.expire_objects_days {
        ask["expire_objects_days"] = json!(days);
    }
    let mut answer =
        broker.mint(ask).map_err(|e| format!("{machine} did not mint the key: {e}"))?;
    let mut record = answer.get("minted").cloned().ok_or("the answer has no key")?;
    let id =
        record.get("id").and_then(Value::as_str).ok_or("the answer's key has no id")?.to_owned();
    let mut take = |name: &str| -> Result<Zeroizing<String>, String> {
        match answer.pointer_mut(&format!("/values/{name}")).map(Value::take) {
            Some(Value::String(v)) if !v.is_empty() => Ok(Zeroizing::new(v)),
            _ => Err(format!("the answer has no {name}")),
        }
    };
    let pair = [
        ("ACCESS_KEY_ID", take("ACCESS_KEY_ID")?),
        ("SECRET_ACCESS_KEY", take("SECRET_ACCESS_KEY")?),
    ];
    drop(answer);
    let mut stored = Vec::new();
    for store in &mint.stores {
        for (suffix, value) in &pair {
            if let Err(message) = sinks.put(store, &store.name(suffix), value) {
                return Err(format!(
                    "{message}\nthe new key {id} is live on {machine}: revoke it there (cmux keys revoke {id}); already stored: {}",
                    if stored.is_empty() { "nothing".to_owned() } else { stored.join(", ") }
                ));
            }
            stored.push(store.label(suffix));
        }
    }
    drop(pair);
    record["via"] = json!(machine);
    let record = record.with_stores(stored, requester());
    append_audit(paths, &record, &id)?;
    Ok(json!({"minted": record}))
}

#[cfg(test)]
mod tests;
