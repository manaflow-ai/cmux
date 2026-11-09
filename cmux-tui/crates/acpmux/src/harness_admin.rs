//! Adding and removing your own harness (BRING-YOUR-OWN-HARNESS H2; Lawrence
//! 2026-10-08: "ensure people are able to add their own ACP stuff, via UI,
//! cli, mcp, cmd shift p"). One implementation behind every entry point: the
//! daemon methods `_acpmux/harness/add|remove|restore|doctor` and
//! `_acpmux/registry` (which the app's Settings, palette and MCP tools call)
//! and the CLI (`cmux harness add|remove|restore|doctor|registry`).
//!
//! - **add** writes `<user harness folder>/<id>.toml` from a command (with
//!   args, a display name and env), a shipped example, or an ACP Registry
//!   agent, and checks that it loads. A literal value under a secret-looking
//!   env key is refused before anything is written (H4): secrets are Keychain
//!   references (`keychain:NAME`) or login-shell copies (`env:VAR`).
//! - **remove** moves a user profile file into `<acpmux home>/harness-backups`
//!   (RECOVERABLE-BY-DEFAULT); managed (company), cmux.json, discovered and
//!   folder profiles are not removable here.
//! - **restore** moves a backup back, by its name only.
//!
//! The caller reloads the catalog afterwards (the daemon announces
//! `_acpmux/harnesses_changed`; the CLI asks a running daemon to reload).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Value, json};

use crate::byo_endpoint;
use crate::cli::harness::{self, AddRequest, DoctorReport, StepStatus};
use crate::config::profiles::{self, ProfileSources};
use crate::config::{Config, ProfileSource};
use crate::registry::{self, Launch, Registry};
use cmux_json::JsonSet as _;

/// Why an operation was refused. `reason()` is the stable code the daemon
/// puts in an error's `data.reason`.
#[derive(Debug)]
pub enum AdminError {
    /// A profile file with this id exists (add without replace, restore).
    Exists(String),
    /// The id names a harness this operation may not remove.
    NotRemovable(String),
    /// A literal value under a secret-looking env key.
    SecretInline(String),
    /// No such harness, example, registry agent or backup.
    NotFound(String),
    /// Bad parameters.
    Invalid(String),
    /// Disk or registry trouble.
    Failed(String),
}

impl AdminError {
    pub fn reason(&self) -> Option<&'static str> {
        match self {
            AdminError::Exists(_) => Some("harness.exists"),
            AdminError::NotRemovable(_) => Some("harness.not_removable"),
            AdminError::SecretInline(_) => Some("harness.secret_inline"),
            AdminError::NotFound(_) => Some("harness.not_found"),
            AdminError::Invalid(_) | AdminError::Failed(_) => None,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            AdminError::Exists(m)
            | AdminError::NotRemovable(m)
            | AdminError::SecretInline(m)
            | AdminError::NotFound(m)
            | AdminError::Invalid(m)
            | AdminError::Failed(m) => m,
        }
    }
}

impl std::fmt::Display for AdminError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for AdminError {}

fn failed(e: impl std::fmt::Display) -> AdminError {
    AdminError::Failed(e.to_string())
}

/// What to add. Exactly one of `command`, `registry` and `example`.
#[derive(Debug, Default, Clone)]
pub struct AddParams {
    pub id: Option<String>,
    pub display_name: Option<String>,
    pub command: Option<String>,
    pub args: Vec<String>,
    /// "acp" (default) or "terminal".
    pub protocol: Option<String>,
    pub registry: Option<String>,
    pub example: Option<String>,
    /// KEY -> a plain non-secret value, `keychain:NAME` or `env:VAR`.
    pub env: BTreeMap<String, String>,
    pub replace: bool,
    /// Endpoint examples: the endpoint's base URL.
    pub base_url: Option<String>,
    /// Endpoint examples: the model ids, the default first; an entry may hold
    /// several separated by commas, and `*` stands for every model the
    /// endpoint lists ([`fetch_endpoint_models`] fills it in).
    pub models: Vec<String>,
    /// Endpoint examples: the Keychain item that holds the key.
    pub keychain_item: Option<String>,
}

impl AddParams {
    /// The daemon's `_acpmux/harness/add` params.
    pub fn from_json(params: &Value) -> Result<Self, AdminError> {
        // The key itself never reaches a profile (H4): it goes to the Keychain
        // and the profile names it. An endpoint add's `apiKey` is taken out
        // before this (server/harness_admin.rs) and stored by `add_endpoint_keyed`.
        for name in
            ["key", "apiKey", "api_key", "token", "authToken", "secret", "value", "password"]
        {
            if params.get(name).is_some_and(|v| !v.is_null()) {
                return Err(AdminError::SecretInline(format!(
                    "{name}: a key never goes into a harness profile; store it with \
                     `_acpmux/harness/secret/set {{id, key, value}}` (or `cmux harness secret set ID KEY`) \
                     and pass keychainItem"
                )));
            }
        }
        let text = |key: &str| -> Result<Option<String>, AdminError> {
            match params.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if s.trim().is_empty() => Ok(None),
                Some(Value::String(s)) => Ok(Some(s.trim().to_owned())),
                Some(_) => Err(AdminError::Invalid(format!("{key} must be a string"))),
            }
        };
        let args = match params.get("args") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => items
                .iter()
                .map(|a| {
                    a.as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| AdminError::Invalid("args must be strings".into()))
                })
                .collect::<Result<_, _>>()?,
            Some(_) => return Err(AdminError::Invalid("args must be an array of strings".into())),
        };
        let env = match params.get("env") {
            None | Some(Value::Null) => BTreeMap::new(),
            Some(Value::Object(map)) => map
                .iter()
                .map(|(k, v)| {
                    v.as_str()
                        .map(|v| (k.clone(), v.to_owned()))
                        .ok_or_else(|| AdminError::Invalid(format!("env {k} must be a string")))
                })
                .collect::<Result<_, _>>()?,
            Some(_) => return Err(AdminError::Invalid("env must be an object".into())),
        };
        let mut models: Vec<String> = text("model")?.into_iter().collect();
        match params.get("models") {
            None | Some(Value::Null) => {}
            Some(Value::Array(items)) => {
                for m in items {
                    let m = m
                        .as_str()
                        .ok_or_else(|| AdminError::Invalid("models must be strings".into()))?;
                    models.push(m.to_owned());
                }
            }
            Some(_) => {
                return Err(AdminError::Invalid("models must be an array of strings".into()));
            }
        }
        Ok(Self {
            id: text("id")?,
            display_name: text("displayName")?,
            command: text("command")?,
            args,
            protocol: text("protocol")?,
            registry: text("registry")?,
            example: text("example")?,
            env,
            replace: params.get("replace").and_then(Value::as_bool).unwrap_or(false),
            base_url: text("baseUrl")?,
            models,
            keychain_item: text("keychainItem")?,
        })
    }
}

#[derive(Debug, Serialize)]
pub struct Added {
    pub id: String,
    pub path: PathBuf,
    /// Every problem the written file has (never env values).
    pub diagnostics: Vec<String>,
    /// Endpoint examples: where the key goes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secret: Option<SecretSlot>,
}

/// Where an endpoint harness reads its key: the env `key` (what
/// `_acpmux/harness/secret/set` and `cmux harness secret set` take) and the
/// Keychain item the profile names.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SecretSlot {
    pub key: String,
    pub keychain_item: String,
}

fn toml_string(s: &str) -> String {
    // A JSON string is a valid TOML basic string.
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

/// One `[env]` line, or why the value may not be written.
fn env_line(id: &str, key: &str, value: &str) -> Result<String, AdminError> {
    if !profiles::valid_env_key(key) {
        return Err(AdminError::Invalid(format!("env key {key:?} is not a valid variable name")));
    }
    if let Some(item) = value.strip_prefix("keychain:") {
        if item.trim().is_empty() || item.contains('}') {
            return Err(AdminError::Invalid(format!("env {key}: give a Keychain item name")));
        }
        return Ok(format!("{key} = {{ keychain = {} }}", toml_string(item.trim())));
    }
    if let Some(var) = value.strip_prefix("env:") {
        if !profiles::valid_env_key(var.trim()) {
            return Err(AdminError::Invalid(format!("env {key}: {var:?} is not a variable name")));
        }
        return Ok(format!("{key} = {{ env = {} }}", toml_string(var.trim())));
    }
    if profiles::secret_looking(key) && !value.is_empty() {
        return Err(AdminError::SecretInline(format!(
            "env {key} looks like a secret: store it with `cmux harness secret set {id} {key}` and pass \"keychain:cmux-harness/{id}/{key}\""
        )));
    }
    Ok(format!("{key} = {}", toml_string(value)))
}

/// A profile file for a program: what `add` writes for `command`.
fn command_profile(
    id: &str,
    p: &AddParams,
    command: &str,
    protocol: &str,
) -> Result<String, AdminError> {
    let name = p.display_name.clone().unwrap_or_else(|| default_name(id));
    let mut out = format!(
        "# cmux harness profile. Guide: docs/add-your-harness.md\n\
         # Check it with: cmux harness doctor {id}\n\
         schema = 1\nid = {}\nname = {}\nprotocol = {}\ncommand = {}\nargs = [{}]\n",
        toml_string(id),
        toml_string(&name),
        toml_string(protocol),
        toml_string(command),
        p.args.iter().map(|a| toml_string(a)).collect::<Vec<_>>().join(", "),
    );
    if !p.env.is_empty() {
        out.push_str("\n[env]\n");
        for (k, v) in &p.env {
            out.push_str(&env_line(id, k, v)?);
            out.push('\n');
        }
    }
    Ok(out)
}

fn default_name(id: &str) -> String {
    let mut name: Vec<char> = id.replace('-', " ").chars().collect();
    if let Some(first) = name.first_mut() {
        *first = first.to_ascii_uppercase();
    }
    name.into_iter().collect()
}

/// `text` with its top-level `name = …` line set to `name`.
fn with_name(text: &str, name: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut done = false;
    for line in text.lines() {
        if !done && line.starts_with("name = ") {
            out.push_str(&format!("name = {}", toml_string(name)));
            done = true;
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }
    out
}

fn diagnostics_text(text: &str, path: &Path, id: &str) -> Vec<String> {
    let found = match profiles::parse_profile_toml(text, path, Some(id), ProfileSource::UserFile) {
        Ok((_, _, _, warnings)) => warnings,
        Err(errors) => errors,
    };
    found
        .iter()
        .map(|d| match &d.fix {
            Some(fix) => format!("{} (fix: {fix})", d.message),
            None => d.message.clone(),
        })
        .collect()
}

fn user_dir(sources: &ProfileSources) -> Result<PathBuf, AdminError> {
    sources
        .user_dir
        .clone()
        .ok_or_else(|| AdminError::Failed("no harness folder: set HOME or XDG_CONFIG_HOME".into()))
}

#[cfg(unix)]
fn ensure_dir(dir: &Path) -> Result<(), AdminError> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir).map_err(failed)
}
/// Windows: an owner-only folder when made here (`owner_only.rs`).
#[cfg(windows)]
fn ensure_dir(dir: &Path) -> Result<(), AdminError> {
    crate::owner_only::create_dir_all(dir).map_err(failed)
}

/// Writes the profile `p` asks for. `registry` is the ACP Registry to use for
/// `p.registry` (the caller loads it; `None` refuses a registry add).
pub fn add(
    p: &AddParams,
    sources: &ProfileSources,
    registry: Option<&Registry>,
    which: &dyn Fn(&str) -> Option<String>,
) -> Result<Added, AdminError> {
    let kinds = [p.command.is_some(), p.registry.is_some(), p.example.is_some()];
    if kinds.iter().filter(|k| **k).count() != 1 {
        return Err(AdminError::Invalid(
            "give exactly one of command, registry and example".into(),
        ));
    }
    let protocol = p.protocol.clone().unwrap_or_else(|| "acp".into());
    if !matches!(protocol.as_str(), "acp" | "terminal") {
        return Err(AdminError::Invalid(format!(
            "protocol must be acp or terminal, got {protocol:?}"
        )));
    }
    if p.command.is_none() && (!p.args.is_empty() || !p.env.is_empty()) {
        return Err(AdminError::Invalid(
            "args and env go with command; edit an example or registry profile after adding it"
                .into(),
        ));
    }
    let dir = user_dir(sources)?;
    if let Some(rid) = &p.registry {
        let reg =
            registry.ok_or_else(|| AdminError::Failed("the ACP Registry is not loaded".into()))?;
        let agent = reg
            .agent(rid)
            .ok_or_else(|| AdminError::NotFound(format!("no ACP Registry agent {rid:?}")))?;
        let id = registry::harness_id(&agent.id).ok_or_else(|| {
            AdminError::Invalid(format!("registry id {rid:?} does not make a harness id"))
        })?;
        if p.id.as_deref().is_some_and(|given| given != id) {
            return Err(AdminError::Invalid(format!(
                "a registry agent keeps its harness id {id:?}; leave id out"
            )));
        }
        let path = dir.join(format!("{id}.toml"));
        if path.exists() && !p.replace {
            return Err(AdminError::Exists(format!("{} exists", path.display())));
        }
        let (id, path) = crate::cli::harness_registry::add(reg, rid, p.replace, sources, which)
            .map_err(|e| AdminError::Invalid(format!("{e:#}")))?;
        if let Some(name) = &p.display_name {
            let text = std::fs::read_to_string(&path).map_err(failed)?;
            crate::config::write_atomic(&path, with_name(&text, name).as_bytes())
                .map_err(failed)?;
        }
        let text = std::fs::read_to_string(&path).map_err(failed)?;
        return Ok(Added {
            diagnostics: diagnostics_text(&text, &path, &id),
            id,
            path,
            secret: None,
        });
    }
    if let Some(kind) = p.example.as_deref().and_then(byo_endpoint::Kind::from_example) {
        return add_endpoint(kind, p, &dir, &EndpointKey::NONE);
    }
    if p.base_url.is_some() || !p.models.is_empty() || p.keychain_item.is_some() {
        return Err(AdminError::Invalid(
            "baseUrl, model and keychainItem go with example anthropic-endpoint or openai-endpoint"
                .into(),
        ));
    }
    if let Some(example) = &p.example {
        let id = p.id.clone();
        let req = AddRequest {
            id,
            command: None,
            protocol,
            example: Some(example.clone()),
            force: p.replace,
        };
        let candidate = req.id.clone().or_else(|| harness::example_id(example));
        if let Some(id) = &candidate
            && dir.join(format!("{id}.toml")).exists()
            && !p.replace
        {
            return Err(AdminError::Exists(format!(
                "{} exists",
                dir.join(format!("{id}.toml")).display()
            )));
        }
        let added =
            harness::add(&req, sources).map_err(|e| AdminError::Invalid(format!("{e:#}")))?;
        if let Some(name) = &p.display_name {
            let text = std::fs::read_to_string(&added.path).map_err(failed)?;
            crate::config::write_atomic(&added.path, with_name(&text, name).as_bytes())
                .map_err(failed)?;
        }
        let text = std::fs::read_to_string(&added.path).map_err(failed)?;
        return Ok(Added {
            diagnostics: diagnostics_text(&text, &added.path, &added.id),
            id: added.id,
            path: added.path,
            secret: None,
        });
    }
    let command = p.command.clone().unwrap_or_default();
    let stem = Path::new(&command)
        .file_name()
        .map(|f| f.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    let id = p.id.clone().unwrap_or(stem);
    if !profiles::valid_id(&id) {
        return Err(AdminError::Invalid(format!(
            "id {id:?} must be 1-40 lowercase letters, digits or '-'"
        )));
    }
    let text = command_profile(&id, p, &command, &protocol)?;
    let path = dir.join(format!("{id}.toml"));
    if path.exists() && !p.replace {
        return Err(AdminError::Exists(format!(
            "{} exists; pass replace to write it again",
            path.display()
        )));
    }
    ensure_dir(&dir)?;
    crate::config::write_atomic(&path, text.as_bytes()).map_err(failed)?;
    Ok(Added { diagnostics: diagnostics_text(&text, &path, &id), id, path, secret: None })
}

/// An endpoint add's key: the one to store (the app's add sends it with the
/// profile, one call), the store command's runner, and the ids another source
/// already has (a built-in, a managed profile).
pub struct EndpointKey<'a> {
    pub value: Option<&'a str>,
    pub store: &'a dyn Fn(&crate::cli::harness_secret::StoreCommand) -> anyhow::Result<()>,
    pub taken: &'a dyn Fn(&str) -> bool,
}

fn never(_: &str) -> bool {
    false
}

fn no_store(_: &crate::cli::harness_secret::StoreCommand) -> anyhow::Result<()> {
    anyhow::bail!("this add stores no key")
}

impl EndpointKey<'static> {
    /// No key and no other source: `add`'s endpoint path.
    pub const NONE: Self = Self { value: None, store: &no_store, taken: &never };
}

/// Every endpoint add and every remove, one at a time across processes (the
/// daemon and the CLI): an OS lock on `.endpoint-add.lock` in the harness
/// folder, held from the id check through the profile and its key (a remove:
/// through the move and the key's deletion), so two adds of one id never both
/// pass the check, a later key never lands under another profile, and a remove
/// never deletes the key of an add that came between. Released when the file
/// closes.
fn lock_endpoint_adds(dir: &Path) -> Result<std::fs::File, AdminError> {
    ensure_dir(dir)?;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join(".endpoint-add.lock"))
        .map_err(failed)?;
    file.lock().map_err(failed)?;
    Ok(file)
}

/// `add` for an endpoint example with its key (the daemon's add with `apiKey`,
/// the CLI). See [`add_endpoint`].
pub fn add_endpoint_keyed(
    p: &AddParams,
    sources: &ProfileSources,
    key: &EndpointKey<'_>,
) -> Result<Added, AdminError> {
    let kind =
        p.example.as_deref().and_then(byo_endpoint::Kind::from_example).ok_or_else(|| {
            AdminError::Invalid(
                "a key goes with example anthropic-endpoint or openai-endpoint".into(),
            )
        })?;
    add_endpoint(kind, p, &user_dir(sources)?, key)
}

/// Refuses an id this add may not write: another source's id (a built-in, a managed or
/// cmux.json profile) is never written over, `replace` or not (a user file there would only be
/// ignored on reload); this folder's own file only with `replace`.
fn id_free(
    id: &str,
    path: &Path,
    replace: bool,
    taken: &dyn Fn(&str) -> bool,
) -> Result<(), AdminError> {
    // `taken` answers for other sources only (`taken_elsewhere`): a user file of this id that
    // another source overrides is refused too, `replace` or not.
    if taken(id) {
        return Err(AdminError::Exists(format!(
            "{id} is already a harness from another source; pick another id"
        )));
    }
    if path.exists() && !replace {
        return Err(AdminError::Exists(format!(
            "{id} already has a profile; pass replace to write it again"
        )));
    }
    Ok(())
}

/// Whether a harness `id` comes from somewhere other than this user folder's own `<id>.toml`
/// (a built-in, a managed or cmux.json profile, a program on PATH): the `taken` an endpoint add
/// refuses. The folder's own file is not "taken": `replace` writes over it.
pub fn taken_elsewhere<'a>(
    cfg: &'a Config,
    sources: &ProfileSources,
) -> impl Fn(&str) -> bool + 'a {
    let dir = sources.user_dir.clone();
    move |id: &str| {
        if cfg.profile(id).is_none() {
            return false;
        }
        let own = dir.as_ref().map(|d| d.join(format!("{id}.toml")));
        let from = cfg.profile_meta.get(id).map(|m| PathBuf::from(&m.source_path));
        match (own, from) {
            (Some(own), Some(from)) => {
                let same = |a: &Path, b: &Path| {
                    a == b
                        || matches!((a.canonicalize(), b.canonicalize()), (Ok(x), Ok(y)) if x == y)
                };
                !same(&own, &from)
            }
            _ => true,
        }
    }
}

/// The id check of an endpoint add, run before anything else it does (reading the endpoint's
/// `*` models included), so an add of a taken id fails as `exists` whatever else would fail.
/// The add checks again under its lock.
pub fn endpoint_id_free(
    p: &AddParams,
    sources: &ProfileSources,
    taken: &dyn Fn(&str) -> bool,
) -> Result<(), AdminError> {
    let Some(kind) = p.example.as_deref().and_then(byo_endpoint::Kind::from_example) else {
        return Ok(());
    };
    let id = p.id.clone().unwrap_or_else(|| kind.example().to_owned());
    if !profiles::valid_id(&id) {
        return Ok(());
    }
    id_free(&id, &user_dir(sources)?.join(format!("{id}.toml")), p.replace, taken)
}

/// What an endpoint profile file is: its kind, the base URL its harness sends to, and the
/// Keychain item it reads its key from (if any).
#[derive(Debug, Clone, PartialEq, Eq)]
struct ExistingEndpoint {
    kind: byo_endpoint::Kind,
    base_url: String,
    item: Option<String>,
}

/// The endpoint profile `text` (one `add_endpoint` wrote), or None for any other profile.
fn existing_endpoint(text: &str) -> Option<ExistingEndpoint> {
    use byo_endpoint::Kind;
    let value: toml::Value = toml::from_str(text).ok()?;
    let env = value.get("env")?.as_table()?;
    let marker = env.get(byo_endpoint::OWN_ENDPOINT_KEY)?.as_str()?;
    let kind = [Kind::Anthropic, Kind::OpenAi].into_iter().find(|k| k.marker() == marker)?;
    let base_url = match kind {
        Kind::Anthropic => env.get("ANTHROPIC_BASE_URL")?.as_str()?.to_owned(),
        Kind::OpenAi => {
            let config: Value =
                serde_json::from_str(env.get("OPENCODE_CONFIG_CONTENT")?.as_str()?).ok()?;
            config
                .pointer(&format!("/provider/{}/options/baseURL", byo_endpoint::OPENCODE_PROVIDER))?
                .as_str()?
                .to_owned()
        }
    };
    let item = env
        .get(kind.secret_key())
        .and_then(|v| v.get("keychain"))
        .and_then(toml::Value::as_str)
        .map(str::to_owned);
    Some(ExistingEndpoint { kind, base_url, item })
}

/// The Keychain item the endpoint profile at `path` reads its key from, only when that profile
/// is of `kind` and sends to `base_url` (checked): a key reaches only the URL it was stored with,
/// so a replace that changes the URL or the kind never takes the old key along.
fn item_for_same_url(
    path: &Path,
    id: &str,
    kind: byo_endpoint::Kind,
    base_url: &str,
) -> Option<String> {
    let old = existing_endpoint(&std::fs::read_to_string(path).ok()?)?;
    let same = old.kind == kind
        && byo_endpoint::check_base_url(&old.base_url).is_ok_and(|url| url == base_url);
    // An item in cmux's own service only if it is this id's own (an older build took any).
    let own_or_named = |item: &String| {
        let service = item.split_once('/').map_or(item.as_str(), |(s, _)| s);
        !byo_endpoint::is_own_service(service) || own_account(item, id).is_some()
    };
    old.item.filter(|item| same && own_or_named(item))
}

/// The account suffix (`KEY` or `KEY.<generation>`) of an item in endpoint `id`'s own
/// Keychain space (`cmux-harness/<id>/...`), or None for any other item.
fn own_account<'a>(item: &'a str, id: &str) -> Option<&'a str> {
    let (service, account) = item.split_once('/')?;
    if service != crate::cli::harness_secret::SERVICE
        || !byo_endpoint::is_own_account(account, Some(id))
    {
        return None;
    }
    account.split_once('/').map(|(_, key)| key)
}

/// A new account for endpoint key `key`: `KEY.<generation>`, unique to one profile generation.
/// Each add or re-key that brings a key stores it in a new item, and the profile names that one
/// item, so no other profile (an earlier one of this id still running, a backup for Undo, a
/// failed publish) ever reads it.
fn new_generation(key: &str) -> String {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{key}.{nanos:x}{:x}{n:x}", std::process::id())
}

/// A `keychainItem` an endpoint add may name: any item but one in cmux's own `cmux-harness`
/// service, in any spelling (bare, with an account, `keychain:`, another case), which holds keys
/// cmux stored for one endpoint profile each (typed for its URL); the bare service would match any.
fn given_item(item: &str) -> Result<String, AdminError> {
    let item = byo_endpoint::check_keychain_item(item).map_err(|(secret, m)| {
        if secret { AdminError::SecretInline(m) } else { AdminError::Invalid(m) }
    })?;
    let service = item.split_once('/').map_or(item.as_str(), |(s, _)| s);
    if byo_endpoint::is_own_service(service) {
        return Err(AdminError::Invalid(format!(
            "keychainItem {item:?} is a key cmux stored for one endpoint; give the key itself \
             (it is stored for this endpoint only)"
        )));
    }
    Ok(item)
}

/// `add` for an endpoint example: a checked profile that names the key's
/// Keychain item, never the key. The rule every path keeps: a key reaches only
/// the URL it was stored with.
///
/// With `key.value` the key is stored in a new item of this profile generation
/// (`cmux-harness/<id>/<KEY>.<generation>`, [`new_generation`]) before the
/// profile is published (one atomic rename), under the add lock: a profile
/// already there (a replace) keeps reading its own item until the rename, a
/// failed store leaves the profile as it was, and a failed publish deletes the
/// new item. Without a key the profile names the item `keychainItem` gives
/// (never one in `cmux-harness/`), else (with `replace`) the one the profile it
/// replaces names, only if that one sends to the same kind and base URL, else
/// none: a fresh add never picks up a key some earlier profile of this id left,
/// and a keyless endpoint has no key reference that would fail to resolve. A
/// replace that no longer names the old profile's own generation item deletes
/// it (best effort, after the publish).
fn add_endpoint(
    kind: byo_endpoint::Kind,
    p: &AddParams,
    dir: &Path,
    key: &EndpointKey<'_>,
) -> Result<Added, AdminError> {
    if p.command.is_some() || p.registry.is_some() || !p.args.is_empty() || !p.env.is_empty() {
        return Err(AdminError::Invalid(format!(
            "{} takes id, displayName, baseUrl, model and keychainItem only",
            kind.example()
        )));
    }
    let id = p.id.clone().unwrap_or_else(|| kind.example().to_owned());
    if !profiles::valid_id(&id) {
        return Err(AdminError::Invalid(format!(
            "id {id:?} must be 1-40 lowercase letters, digits or '-'"
        )));
    }
    if key.value.is_some() && p.keychain_item.is_some() {
        return Err(AdminError::Invalid(
            "give the key or keychainItem, not both: a key given is stored in the profile's own item"
                .into(),
        ));
    }
    let base_url =
        byo_endpoint::check_base_url(p.base_url.as_deref().unwrap_or("")).map_err(|e| match e {
            byo_endpoint::UrlError::Invalid(m) => AdminError::Invalid(m),
            byo_endpoint::UrlError::Secret(m) => AdminError::SecretInline(m),
        })?;
    let models = byo_endpoint::check_models(&p.models).map_err(AdminError::Invalid)?;
    if models.iter().any(|m| m == byo_endpoint::ALL_MODELS) {
        return Err(AdminError::Invalid(
            "`*` (every model the endpoint lists) is filled in before the add: type the model ids"
                .into(),
        ));
    }
    let given = p.keychain_item.as_deref().map(given_item).transpose()?;
    let name = p.display_name.clone().unwrap_or_else(|| default_name(&id));
    if name.chars().any(char::is_control) || name.len() > 100 {
        return Err(AdminError::Invalid(
            "displayName must be one line of at most 100 bytes".into(),
        ));
    }
    let path = dir.join(format!("{id}.toml"));
    let default = byo_endpoint::default_item(kind, &id);
    let _one = lock_endpoint_adds(dir)?;
    id_free(&id, &path, p.replace, key.taken)?;
    let old_item = std::fs::read_to_string(&path)
        .ok()
        .and_then(|text| existing_endpoint(&text))
        .and_then(|old| old.item);
    let account = key.value.map(|_| new_generation(kind.secret_key()));
    let item = match (given, &account) {
        (Some(item), _) => Some(item),
        (None, Some(account)) => Some(crate::cli::harness_secret::reference(&id, account)),
        (None, None) => item_for_same_url(&path, &id, kind, &base_url).filter(|_| p.replace),
    };
    let text = byo_endpoint::profile_text(&byo_endpoint::Endpoint {
        kind,
        id: &id,
        name: &name,
        base_url: &base_url,
        models: &models,
        keychain_item: item.as_deref(),
    });
    ensure_dir(dir)?;
    let delete = |account: &str| {
        let _ = (key.store)(&crate::cli::harness_secret::delete_command(
            std::env::consts::OS,
            &id,
            account,
        ));
    };
    // The key first, in its own new item, the profile last (one atomic rename): no reader (the
    // profile watcher reloads without this lock) ever sees this profile before its key is in its
    // item, and the profile it replaces reads its own item, with its own URL, up to the rename.
    if let (Some(value), Some(account)) = (key.value, &account) {
        crate::cli::harness_secret::store_command(std::env::consts::OS, &id, account, value)
            .and_then(|cmd| (key.store)(&cmd))
            .map_err(|e| AdminError::Failed(format!("the key was not stored: {e:#}")))?;
    }
    if let Err(e) = crate::config::write_atomic(&path, text.as_bytes()) {
        // Not published: the new item goes again; the profile there (if any) names its own.
        if let Some(account) = &account {
            delete(account);
        }
        return Err(failed(e));
    }
    // Published: the replaced profile's own generation item is no one's now. (A plain
    // `cmux-harness/<id>/<KEY>` an older app wrote stays: a backup may name it.)
    if let Some(old) = old_item.filter(|old| Some(old) != item.as_ref())
        && let Some(account) = own_account(&old, &id).filter(|a| a.contains('.'))
    {
        delete(account);
    }
    Ok(Added {
        diagnostics: diagnostics_text(&text, &path, &id),
        secret: Some(SecretSlot {
            key: kind.secret_key().to_owned(),
            keychain_item: item.unwrap_or(default),
        }),
        id,
        path,
    })
}

/// Fills in `*` of an endpoint add's models with what the endpoint lists
/// (`byo_endpoint::fetch_models`), after the models typed before it. The key
/// is `key` (the one the add brings), else read from the Keychain item the
/// add names, else (with `replace`) the one the profile it replaces names if
/// that profile sends to this same kind and base URL;
/// otherwise the list is asked for without a key (a local server), never with
/// a key an earlier profile of this id left.
/// Nothing to do for any other add.
pub async fn fetch_endpoint_models(
    p: &mut AddParams,
    key: Option<&str>,
    sources: &ProfileSources,
    lookup_keychain: impl Fn(&str, Option<&str>) -> Result<String, String> + Send + 'static,
) -> Result<(), AdminError> {
    let Some(kind) = p.example.as_deref().and_then(byo_endpoint::Kind::from_example) else {
        return Ok(());
    };
    let wanted = byo_endpoint::check_models(&p.models).map_err(AdminError::Invalid)?;
    if !wanted.iter().any(|m| m == byo_endpoint::ALL_MODELS) {
        return Ok(());
    }
    let base_url = p.base_url.clone().unwrap_or_default();
    let id = p.id.clone().unwrap_or_else(|| kind.example().to_owned());
    // The key of the profile this add replaces only if that one sends to this very URL.
    let item = match &p.keychain_item {
        Some(item) => Some(given_item(item)?),
        None => byo_endpoint::check_base_url(&base_url).ok().and_then(|url| {
            user_dir(sources)
                .ok()
                .filter(|_| p.replace)
                .and_then(|dir| item_for_same_url(&dir.join(format!("{id}.toml")), &id, kind, &url))
        }),
    };
    let key = match (key, item) {
        (Some(key), _) => Some(zeroize::Zeroizing::new(key.to_owned())),
        (None, None) => None,
        (None, Some(item)) => tokio::task::spawn_blocking(move || {
            let (service, account) = match item.split_once('/') {
                Some((s, a)) => (s, Some(a)),
                None => (item.as_str(), None),
            };
            // The one gate for an endpoint's Keychain reads: cmux's own items by exact account.
            byo_endpoint::endpoint_keychain_lookup(Some(&id), service, account, &lookup_keychain)
                .ok()
                .map(zeroize::Zeroizing::new)
        })
        .await
        .map_err(failed)?,
    };
    let fetched = byo_endpoint::fetch_models(
        kind,
        &base_url,
        key.as_ref().map(|k| k.as_str()),
        byo_endpoint::FETCH_TIMEOUT,
    )
    .await
    .map_err(|e| AdminError::Invalid(format!("could not list the endpoint's models: {e}")))?;
    let mut models: Vec<String> = Vec::new();
    for m in wanted
        .into_iter()
        .flat_map(|m| if m == byo_endpoint::ALL_MODELS { fetched.clone() } else { vec![m] })
    {
        if !models.contains(&m) && models.len() < byo_endpoint::MAX_MODELS {
            models.push(m);
        }
    }
    p.models = models;
    Ok(())
}

#[derive(Debug, Serialize)]
pub struct Removed {
    pub id: String,
    /// The backup's name, for `restore`.
    pub backup: String,
    /// With `forget`: why one of the endpoint's own Keychain items could not be deleted. The
    /// profile is removed, but its key is still in the Keychain; the caller says so.
    #[serde(rename = "keyError", skip_serializing_if = "Option::is_none")]
    pub key_error: Option<String>,
}

impl Removed {
    /// What a caller shows when the key stayed: "removed ID, but its key could not be deleted
    /// from Keychain: <reason>".
    pub fn key_warning(&self) -> Option<String> {
        self.key_error.as_ref().map(|reason| {
            format!("removed {}, but its key could not be deleted from Keychain: {reason}", self.id)
        })
    }
}

/// The folder backups go to.
pub fn backup_dir(acpmux_home: &Path) -> PathBuf {
    acpmux_home.join("harness-backups")
}

fn unix_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// Moves `from` to `to`; across file systems, copies then deletes.
fn move_file(from: &Path, to: &Path) -> Result<(), AdminError> {
    if std::fs::rename(from, to).is_ok() {
        return Ok(());
    }
    std::fs::copy(from, to).map_err(failed)?;
    std::fs::remove_file(from).map_err(failed)
}

/// Moves the user profile file of `id` into the backups. `cfg` says where
/// other harnesses of that id come from, to refuse them by name.
///
/// An endpoint's key stays in the Keychain (the backup holds only the reference, never the
/// key), so Undo (`restore`) brings back a working endpoint. `forget` (a caller that owns the
/// add, cleaning up one it never kept) also deletes the items in this id's own Keychain space.
pub fn remove(
    id: &str,
    cfg: &Config,
    sources: &ProfileSources,
    acpmux_home: &Path,
    forget: Option<&dyn Fn(&crate::cli::harness_secret::StoreCommand) -> anyhow::Result<()>>,
) -> Result<Removed, AdminError> {
    if !profiles::valid_id(id) {
        return Err(AdminError::Invalid(format!("{id:?} is not a harness id")));
    }
    let user = user_dir(sources)?;
    let _one = lock_endpoint_adds(&user)?;
    let path = user.join(format!("{id}.toml"));
    if !path.is_file() {
        if cfg.harnesses.contains_key(id) {
            let from = match cfg.profile_meta.get(id).map(|m| m.source) {
                Some(ProfileSource::Managed) => "your company's managed config",
                Some(ProfileSource::CmuxJson) => "cmux.json (agents.harnesses)",
                Some(ProfileSource::UserFile) => "a profile file outside your harness folder",
                None => "acpmux itself (a built-in or a program on PATH)",
            };
            return Err(AdminError::NotRemovable(format!(
                "{id} comes from {from}; only profiles in your harness folder can be removed here"
            )));
        }
        return Err(AdminError::NotFound(format!(
            "no harness profile {id} in your harness folder"
        )));
    }
    let dir = backup_dir(acpmux_home);
    ensure_dir(&dir)?;
    let backup = format!("{id}-{}.toml", unix_millis());
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    move_file(&path, &dir.join(&backup))?;
    // Only on `forget`: the items in this id's own Keychain space (`cmux-harness/<id>/...`)
    // go too. Kept otherwise, for Undo; a later fresh add of this id never reads them (it names
    // no item unless given a key, which then replaces the item).
    // An item already gone is fine (`forget` answers Ok); any other failure is reported
    // (`key_error`), never taken for a deleted key.
    let mut key_error = None;
    if let Some(forget) = forget {
        for key in endpoint_own_keys(&text, id) {
            let cmd = crate::cli::harness_secret::delete_command(std::env::consts::OS, id, &key);
            if let Err(e) = forget(&cmd) {
                key_error.get_or_insert_with(|| format!("{e:#}"));
            }
        }
    }
    Ok(Removed { id: id.to_owned(), backup, key_error })
}

/// The accounts of endpoint profile `text`'s Keychain items in this id's own space
/// (`cmux-harness/<id>/<KEY>.<generation>`, or `<KEY>` as an older app wrote it, any KEY: one
/// named `API_KEY`); none for any other profile.
fn endpoint_own_keys(text: &str, id: &str) -> Vec<String> {
    let Ok(value) = toml::from_str::<toml::Value>(text) else { return Vec::new() };
    let Some(env) = value.get("env").and_then(toml::Value::as_table) else { return Vec::new() };
    if env.get(byo_endpoint::OWN_ENDPOINT_KEY).and_then(toml::Value::as_str).is_none() {
        return Vec::new();
    }
    env.values()
        .filter_map(|v| v.get("keychain").and_then(toml::Value::as_str))
        .filter_map(|item| own_account(item, id).map(str::to_owned))
        .collect()
}

#[derive(Debug, Serialize)]
pub struct Restored {
    pub id: String,
    pub path: PathBuf,
}

/// Moves backup `name` (as `remove` named it) back into the user folder.
pub fn restore(
    name: &str,
    sources: &ProfileSources,
    acpmux_home: &Path,
) -> Result<Restored, AdminError> {
    let valid = name.ends_with(".toml")
        && !name.starts_with('.')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '.' | '_'));
    if !valid {
        return Err(AdminError::Invalid(format!("{name:?} is not a backup name")));
    }
    let from = backup_dir(acpmux_home).join(name);
    if !from.is_file() {
        return Err(AdminError::NotFound(format!("no backup {name}")));
    }
    let id = name
        .strip_suffix(".toml")
        .and_then(|stem| stem.rsplit_once('-'))
        .map(|(id, _)| id.to_owned())
        .filter(|id| profiles::valid_id(id))
        .ok_or_else(|| AdminError::Invalid(format!("{name:?} is not a backup name")))?;
    let dir = user_dir(sources)?;
    let to = dir.join(format!("{id}.toml"));
    // Under the lock adds and removes take: a restore never races an add of this id.
    let _one = lock_endpoint_adds(&dir)?;
    if to.exists() {
        return Err(AdminError::Exists(format!(
            "{} exists; remove or rename it first",
            to.display()
        )));
    }
    move_file(&from, &to)?;
    Ok(Restored { id, path: to })
}

/// What `secret_set` stored (never the value).
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SecretStored {
    pub id: String,
    pub key: String,
    /// The Keychain item (`cmux-harness/<id>/<key>`).
    pub keychain_item: String,
    /// `written` (the profile now names the item), `unchanged` (it did
    /// already) or `manual` (add `line` under `[env]` by hand).
    pub profile: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<String>,
}

/// `_acpmux/harness/secret/set`: store `value` for harness `id`'s env `key`
/// in the system secret store (service `cmux-harness`, account
/// `<id>/<key>`, the item `keychain_lookup` reads) and point a user profile
/// at it, as `cmux harness secret set` does. Never for an endpoint harness
/// (its key comes only with its add). `store` runs the store command (the
/// value only on its stdin). No error or reply holds the value.
pub fn secret_set(
    id: &str,
    key: &str,
    value: &str,
    cfg: &Config,
    store: &dyn Fn(&crate::cli::harness_secret::StoreCommand) -> anyhow::Result<()>,
) -> Result<SecretStored, AdminError> {
    use crate::cli::harness_secret::{self as secret, FileChange};
    if !profiles::valid_id(id) {
        return Err(AdminError::Invalid(format!("{id:?} is not a harness id")));
    }
    if !profiles::valid_env_key(key) {
        return Err(AdminError::Invalid(format!("{key:?} is not an env variable name")));
    }
    // Errors of the store path name the step, never the value.
    let change = secret::secret_set(id, key, value, cfg, store)
        .map_err(|e| AdminError::Failed(format!("{e:#}")))?;
    let keychain_item = secret::reference(id, key);
    let (profile, path, line) = match change {
        FileChange::Written(p) => ("written", Some(p.display().to_string()), None),
        FileChange::Unchanged(p) => ("unchanged", Some(p.display().to_string()), None),
        FileChange::Manual { path, .. } => ("manual", path, Some(secret::reference_line(id, key))),
    };
    Ok(SecretStored { id: id.to_owned(), key: key.to_owned(), keychain_item, profile, path, line })
}

/// The daemon's `_acpmux/harness/doctor` answer: each step as `{name, ok,
/// detail, fix?}`. A warning or a skipped step is ok; never an env value.
pub fn doctor_value(report: &DoctorReport) -> Value {
    let steps: Vec<Value> = report
        .steps
        .iter()
        .map(|s| {
            let mut step = json!({
                "name": s.step,
                "ok": s.status != StepStatus::Fail,
                "status": s.status,
                "detail": s.detail,
            });
            if let Some(fix) = &s.fix {
                step.set("fix", json!(fix));
            }
            step
        })
        .collect();
    json!({"id": report.id, "ok": report.ok, "steps": steps})
}

/// The daemon's `_acpmux/registry` answer: every agent and how it can start here.
pub fn registry_value(reg: &Registry, which: &dyn Fn(&str) -> Option<String>) -> Value {
    let platform = registry::platform();
    let agents: Vec<Value> = reg
        .agents
        .iter()
        .map(|agent| {
            let launch = agent.launch(platform, which);
            let how = match launch {
                Launch::Installed { .. } => "path",
                Launch::Npx { .. } => "npx",
                Launch::Uvx { .. } => "uvx",
                Launch::Download { .. } | Launch::Unavailable => "none",
            };
            let mut row = json!({
                "id": agent.id,
                "name": agent.name,
                "version": agent.version,
                "launch": how,
                "installed": matches!(launch, Launch::Installed { .. }),
            });
            if let Some(d) = &agent.description {
                row.set("description", json!(d));
            }
            if let Some(w) = &agent.website {
                row.set("website", json!(w));
            }
            if let Some(h) = registry::harness_id(&agent.id) {
                row.set("harnessId", json!(h));
            }
            row
        })
        .collect();
    json!({"agents": agents})
}
