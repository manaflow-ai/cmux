//! The ACP Registry (cx-1785): the public list of coding agents that speak
//! the Agent Client Protocol (https://cdn.agentclientprotocol.com/registry/
//! v1/latest/registry.json, from github.com/agentclientprotocol/registry).
//! Every agent names how it starts: an `npx` package, a `uvx` package, or a
//! per-platform binary archive with the command inside it.
//!
//! acpmux uses it three ways, never running anything at discovery:
//! - **Installed agents are harnesses.** An agent whose program is on PATH
//!   (the binary distribution's command, or the known bin of its npm
//!   package) becomes a harness with the registry's arguments and env
//!   ([`discovered`]). Only the cached copy is read; built-in harnesses win.
//! - **`cmux harness registry`** lists every agent and how it can start
//!   here (on PATH, `npx`, `uvx`, or not here).
//! - **`cmux harness add ID --registry`** writes a profile file that starts
//!   the agent at the registry's pinned version ([`profile_toml`]). That is
//!   the user's explicit choice to run an `npx`/`uvx` package.
//!
//! Binary archives are never downloaded by acpmux: an agent that ships only
//! an archive is listed with its download page until it is installed.
//!
//! The registry is fetched by the daemon (HTTPS only, no redirects, 30 s,
//! 1 MiB cap) and cached at `~/.acpmux/acp-registry/registry.json`. Every
//! field is checked; a bad agent is dropped alone.
//!
//! The approach (the registry as the source of extra harnesses, exact
//! versions only, launch order binary > npx > uvx) follows t3code's ACP
//! Registry driver (apps/server/src/provider/acp/AcpRegistrySupport.ts).
//! Portions adapted from t3code, Copyright (c) 2026 T3 Tools Inc., MIT License
//! (https://github.com/pingdotgg/t3code; see THIRD_PARTY_LICENSES.md).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

use crate::config::{HarnessKind, HarnessProfile};

/// Where the daemon reads the registry.
pub const REGISTRY_URL: &str =
    "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json";
/// Largest registry body read, in bytes.
pub const MAX_BODY_BYTES: usize = 1 << 20;
/// Most agents read from one registry.
pub const MAX_AGENTS: usize = 512;
const MAX_ARGS: usize = 32;
const MAX_ARG_BYTES: usize = 256;
const MAX_ENV: usize = 16;
const MAX_ENV_VALUE_BYTES: usize = 512;
const MAX_TEXT_BYTES: usize = 512;

static ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-z0-9][a-z0-9._-]{0,63}$").unwrap()); // crash-allow: constant pattern
static NPX_PACKAGE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*@[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$")
        .unwrap() // crash-allow: constant pattern
});
static UVX_PACKAGE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._-]*(==|@)[0-9][0-9A-Za-z.+-]*$").unwrap() // crash-allow: constant pattern
});
static ENV_KEY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Z_][A-Z0-9_]{0,63}$").unwrap()); // crash-allow: constant pattern
static SHA256: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[0-9a-f]{64}$").unwrap()); // crash-allow: constant pattern

/// Env keys a registry entry may never set: they change how any program,
/// the loader or the package runner behaves.
fn reserved_env(key: &str) -> bool {
    matches!(key, "PATH" | "HOME" | "SHELL" | "NODE_OPTIONS" | "PYTHONPATH" | "PYTHONHOME")
        || key.starts_with("LD_")
        || key.starts_with("DYLD_")
        || key.starts_with("NPM_CONFIG")
        || key.starts_with("UV_")
        || key.starts_with("ACPMUX_")
        || key.starts_with("CMUX_")
}

/// An npm or PyPI package launch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Package {
    /// `name@1.2.3` (npm) or `name==1.2.3` / `name@1.2.3` (PyPI), exact.
    pub package: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
}

/// One platform's binary archive.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Binary {
    pub archive: String,
    /// The program inside the archive, relative (`./goose`).
    pub cmd: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub sha256: Option<String>,
}

/// One registry agent, checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Agent {
    pub id: String,
    pub name: String,
    pub version: String,
    pub description: Option<String>,
    pub website: Option<String>,
    pub license: Option<String>,
    pub npx: Option<Package>,
    pub uvx: Option<Package>,
    /// By platform key (`darwin-aarch64`, `linux-x86_64`, ...).
    pub binary: BTreeMap<String, Binary>,
}

/// The checked registry.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Registry {
    pub agents: Vec<Agent>,
}

impl Registry {
    pub fn agent(&self, id: &str) -> Option<&Agent> {
        self.agents.iter().find(|a| a.id == id)
    }
}

fn text(value: &Value, max: usize) -> Option<String> {
    let s = value.as_str()?.trim();
    (!s.is_empty() && s.len() <= max && !s.contains('\0')).then(|| s.to_owned())
}

fn https(value: &Value) -> Option<String> {
    let s = text(value, 2048)?;
    let url = reqwest::Url::parse(&s).ok()?;
    (url.scheme() == "https" && url.host_str().is_some()).then_some(s)
}

/// Arguments: strings, bounded, and never a `${...}` expansion (profile
/// arguments expand those).
fn args(value: &Value) -> Option<Vec<String>> {
    let Some(list) = value.as_array() else {
        return value.is_null().then(Vec::new);
    };
    if list.len() > MAX_ARGS {
        return None;
    }
    list.iter()
        .map(|a| {
            let s = a.as_str()?;
            (s.len() <= MAX_ARG_BYTES && !s.contains('\0') && !s.contains("${"))
                .then(|| s.to_owned())
        })
        .collect()
}

fn env(value: &Value) -> Option<BTreeMap<String, String>> {
    let Some(map) = value.as_object() else {
        return value.is_null().then(BTreeMap::new);
    };
    if map.len() > MAX_ENV {
        return None;
    }
    map.iter()
        .map(|(k, v)| {
            let v = v.as_str()?;
            (ENV_KEY.is_match(k)
                && !reserved_env(k)
                && v.len() <= MAX_ENV_VALUE_BYTES
                && !v.contains('\0')
                && !v.contains("${"))
            .then(|| (k.clone(), v.to_owned()))
        })
        .collect()
}

fn package(value: &Value, pattern: &Regex) -> Option<Package> {
    let package = text(&value["package"], 214)?;
    pattern.is_match(&package).then_some(())?;
    Some(Package { package, args: args(&value["args"])?, env: env(&value["env"])? })
}

/// A relative program path inside an archive: no `..`, no absolute path.
fn archive_cmd(value: &Value) -> Option<String> {
    let cmd = text(value, 256)?;
    let path = cmd.replace('\\', "/");
    let bad = path.starts_with('/')
        || path.split('/').any(|part| part == "..")
        || path.contains(':')
        || program_name(&cmd).is_none();
    (!bad).then_some(cmd)
}

fn binary(value: &Value) -> Option<Binary> {
    let sha256 = match &value["sha256"] {
        Value::Null => None,
        v => Some(text(v, 64).filter(|s| SHA256.is_match(s))?),
    };
    Some(Binary {
        archive: https(&value["archive"])?,
        cmd: archive_cmd(&value["cmd"])?,
        args: args(&value["args"])?,
        env: env(&value["env"])?,
        sha256,
    })
}

fn agent(value: &Value) -> Option<Agent> {
    let id = text(&value["id"], 64).filter(|id| ID.is_match(id))?;
    let version = text(&value["version"], 64)
        .filter(|v| v.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '+')))?;
    let dist = &value["distribution"];
    let npx = match &dist["npx"] {
        Value::Null => None,
        v => Some(package(v, &NPX_PACKAGE)?),
    };
    let uvx = match &dist["uvx"] {
        Value::Null => None,
        v => Some(package(v, &UVX_PACKAGE)?),
    };
    let mut targets = BTreeMap::new();
    if let Some(map) = dist["binary"].as_object() {
        for (platform, target) in map {
            if PLATFORMS.contains(&platform.as_str()) {
                targets.insert(platform.clone(), binary(target)?);
            }
        }
    }
    if npx.is_none() && uvx.is_none() && targets.is_empty() {
        return None;
    }
    Some(Agent {
        name: text(&value["name"], MAX_TEXT_BYTES)?,
        description: text(&value["description"], MAX_TEXT_BYTES),
        website: https(&value["website"]).or_else(|| https(&value["repository"])),
        license: text(&value["license"], 64),
        id,
        version,
        npx,
        uvx,
        binary: targets,
    })
}

/// Parses a registry body. A bad envelope fails; a bad agent is left out.
pub fn parse(_bytes: &[u8]) -> Result<Registry, String> {
    // Red: no agent is read yet.
    let _ = agent;
    Ok(Registry::default())
}

/// Platform keys the registry uses.
pub const PLATFORMS: &[&str] = &[
    "darwin-aarch64",
    "darwin-x86_64",
    "linux-aarch64",
    "linux-x86_64",
    "windows-aarch64",
    "windows-x86_64",
];

/// This machine's platform key.
pub fn platform() -> Option<&'static str> {
    let os = match std::env::consts::OS {
        "macos" => "darwin",
        "linux" => "linux",
        "windows" => "windows",
        _ => return None,
    };
    let arch = match std::env::consts::ARCH {
        "aarch64" => "aarch64",
        "x86_64" => "x86_64",
        _ => return None,
    };
    PLATFORMS.iter().copied().find(|p| *p == format!("{os}-{arch}"))
}

/// The program a command names: its file name without `.exe` or `.cmd`,
/// when that is a plain name.
pub fn program_name(cmd: &str) -> Option<String> {
    let base = cmd.replace('\\', "/");
    let base = base.rsplit('/').next()?;
    let base = base.strip_suffix(".exe").or_else(|| base.strip_suffix(".cmd")).unwrap_or(base);
    let plain = !base.is_empty()
        && base.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        && !base.starts_with('.');
    plain.then(|| base.to_owned())
}

/// The program an npm package installs, for the agents where the registry
/// id alone does not say (a global `npm install -g` puts it on PATH). Only
/// names checked against each package; an unknown package is not looked up.
fn npm_bin(id: &str) -> Option<&'static str> {
    Some(match id {
        "github-copilot-cli" => "copilot",
        "qwen-code" => "qwen",
        "auggie" => "auggie",
        "cline" => "cline",
        "factory-droid" => "droid",
        "codebuddy-code" => "codebuddy",
        "qoder" => "qodercli",
        _ => return None,
    })
}

/// The harness id a registry agent takes: our own id for agents acpmux
/// already knows under another name, else the registry id with `.` and `_`
/// made `-` (profile ids are lowercase letters, digits and `-`).
pub fn harness_id(registry_id: &str) -> String {
    match registry_id {
        "codex-acp" => "codex".into(),
        "pi-acp" => "pi".into(),
        "grok-build" => "grok".into(),
        "antigravity-acp" => "antigravity".into(),
        "claude-acp" => "claude-acp".into(),
        other => other.replace(['.', '_'], "-"),
    }
}

/// How an agent can start on this machine, best first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Launch {
    /// Its program is on PATH.
    Installed { argv: Vec<String>, env: BTreeMap<String, String> },
    /// Through `npx -y <package>` (downloads the pinned package).
    Npx { argv: Vec<String>, env: BTreeMap<String, String> },
    /// Through `uvx <package>` (downloads the pinned package).
    Uvx { argv: Vec<String>, env: BTreeMap<String, String> },
    /// Only a binary archive, not installed: its download page.
    Download { archive: String, sha256: Option<String> },
    /// Nothing that runs here.
    Unavailable,
}

impl Launch {
    pub fn method(&self) -> &'static str {
        match self {
            Launch::Installed { .. } => "installed",
            Launch::Npx { .. } => "npx",
            Launch::Uvx { .. } => "uvx",
            Launch::Download { .. } => "download",
            Launch::Unavailable => "unavailable",
        }
    }
    pub fn argv_env(&self) -> Option<(&[String], &BTreeMap<String, String>)> {
        match self {
            Launch::Installed { argv, env }
            | Launch::Npx { argv, env }
            | Launch::Uvx { argv, env } => Some((argv, env)),
            _ => None,
        }
    }
}

impl Agent {
    /// The installed program and its arguments and env, when one is on PATH.
    fn installed(
        &self,
        platform: Option<&str>,
        which: &dyn Fn(&str) -> Option<String>,
    ) -> Option<Launch> {
        if let Some(target) = platform.and_then(|p| self.binary.get(p))
            && let Some(path) = program_name(&target.cmd).and_then(|name| which(&name))
        {
            let mut argv = vec![path];
            argv.extend(target.args.iter().cloned());
            return Some(Launch::Installed { argv, env: target.env.clone() });
        }
        let npx = self.npx.as_ref()?;
        let path = which(npm_bin(&self.id)?)?;
        let mut argv = vec![path];
        argv.extend(npx.args.iter().cloned());
        Some(Launch::Installed { argv, env: npx.env.clone() })
    }

    /// How the agent starts here: on PATH, else `npx`, else `uvx`, else its
    /// archive's download page.
    pub fn launch(&self, platform: Option<&str>, which: &dyn Fn(&str) -> Option<String>) -> Launch {
        if let Some(installed) = self.installed(platform, which) {
            return installed;
        }
        if let Some(npx) = &self.npx
            && let Some(runner) = which("npx")
        {
            let mut argv = vec![runner, "-y".into(), npx.package.clone()];
            argv.extend(npx.args.iter().cloned());
            return Launch::Npx { argv, env: npx.env.clone() };
        }
        if let Some(uvx) = &self.uvx
            && let Some(runner) = which("uvx")
        {
            let mut argv = vec![runner, uvx.package.replacen("==", "@", 1)];
            argv.extend(uvx.args.iter().cloned());
            return Launch::Uvx { argv, env: uvx.env.clone() };
        }
        match platform.and_then(|p| self.binary.get(p)) {
            Some(target) => {
                Launch::Download { archive: target.archive.clone(), sha256: target.sha256.clone() }
            }
            None => Launch::Unavailable,
        }
    }
}

/// The harnesses of the installed registry agents (program on PATH), by
/// harness id. Ids in `taken` (harnesses found another way) are skipped.
pub fn discovered(
    registry: &Registry,
    platform: Option<&str>,
    which: &dyn Fn(&str) -> Option<String>,
    taken: &dyn Fn(&str) -> bool,
) -> BTreeMap<String, HarnessProfile> {
    let mut out = BTreeMap::new();
    for agent in &registry.agents {
        let id = harness_id(&agent.id);
        if !crate::config::profiles::valid_id(&id) || taken(&id) || out.contains_key(&id) {
            continue;
        }
        let Some(Launch::Installed { argv, env }) = agent.installed(platform, which) else {
            continue;
        };
        out.insert(
            id,
            HarnessProfile {
                kind: HarnessKind::Acp,
                argv,
                env,
                description: Some(format!("{} (ACP Registry {})", agent.name, agent.version)),
                fallback: None,
                family: None,
                models: vec![],
                model: None,
                effort: None,
                policy: None,
            },
        );
    }
    out
}

/// The harness ids of the installed agents in the cached registry.
pub fn installed_ids(home: &Path) -> std::collections::BTreeSet<String> {
    load_cached(home)
        .map(|reg| {
            discovered(&reg, platform(), &crate::config::which, &|_| false).into_keys().collect()
        })
        .unwrap_or_default()
}

fn toml_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

/// A profile file (schema 1) that starts `agent` the way `launch` says:
/// `cmux harness add ID --registry`. `None` when the agent cannot start here.
pub fn profile_toml(agent: &Agent, launch: &Launch) -> Option<String> {
    let (argv, env) = launch.argv_env()?;
    let (command, rest) = argv.split_first()?;
    let id = harness_id(&agent.id);
    let how = match launch {
        Launch::Installed { .. } => "the installed program".to_owned(),
        Launch::Npx { .. } => "npx, at the registry's pinned version".to_owned(),
        _ => "uvx, at the registry's pinned version".to_owned(),
    };
    let mut out = format!(
        "# {name} from the ACP Registry (agent {rid} {version}), started through {how}.\n\
         # Written by `cmux harness add {rid} --registry`; run it again with --force to update.\n\
         schema = 1\nid = {id}\nname = {name_q}\nprotocol = \"acp\"\ncommand = {command}\nargs = [{args}]\n",
        name = agent.name,
        rid = agent.id,
        version = agent.version,
        id = toml_string(&id),
        name_q = toml_string(&agent.name),
        command = toml_string(command),
        args = rest.iter().map(|a| toml_string(a)).collect::<Vec<_>>().join(", "),
    );
    if !env.is_empty() {
        out.push_str("\n[env]\n");
        for (k, v) in env {
            out.push_str(&format!("{k} = {}\n", toml_string(v)));
        }
    }
    if let Some(site) = &agent.website {
        out.push_str(&format!("\n[auth]\ndocs = {}\n", toml_string(site)));
    }
    Some(out)
}

/// The cache folder in acpmux's home.
pub fn cache_dir(home: &Path) -> PathBuf {
    home.join("acp-registry")
}

/// The cached registry, when one was saved and still parses.
pub fn load_cached(home: &Path) -> Option<Registry> {
    let bytes = std::fs::read(cache_dir(home).join("registry.json")).ok()?;
    parse(&bytes).ok()
}

/// Saves a body that parses, through a temp file and a rename. Returns
/// whether the saved copy changed.
pub fn save(home: &Path, body: &[u8]) -> Result<bool, String> {
    parse(body)?;
    let dir = cache_dir(home);
    let path = dir.join("registry.json");
    if std::fs::read(&path).is_ok_and(|old| old == body) {
        return Ok(false);
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let tmp = dir.join(format!("registry.json.{}.tmp", std::process::id()));
    std::fs::write(&tmp, body).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    Ok(true)
}

/// One HTTPS GET of the registry: no redirects, 30 s, body cap.
pub async fn fetch(url: &str) -> Result<Vec<u8>, String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(30))
        .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())?;
    let mut response = client
        .get(url)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("the registry answered {}", response.status()));
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        crate::catalog::fetch::push_capped(&mut body, &chunk, MAX_BODY_BYTES)?;
    }
    Ok(body)
}

/// Fetches the registry and saves it when it parses. Returns whether the
/// saved copy changed.
pub async fn refresh(home: &Path) -> Result<bool, String> {
    let body = fetch(REGISTRY_URL).await?;
    save(home, &body)
}

#[cfg(test)]
#[path = "registry_tests.rs"]
mod tests;
