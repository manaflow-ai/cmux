//! Microsoft Foundry through the Azure CLI (cmux-tui/docs/model-connections.md): connect makes a
//! resource group `cmux` tagged `managed-by=cmux` (never a group the person made), one AIServices
//! account named `cmux-{hash}-{region}`, and an OpenCode endpoint harness `foundry`; models deploy
//! on first use (`hub/foundry_gate.rs`). cmux deletes Azure resources only when a region switch
//! replaces the cmux account.

use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{Value, json};

use crate::config::{Config, profiles::ProfileSources};
use crate::harness_admin::{self, AddParams, EndpointKey};

pub const HARNESS_ID: &str = "foundry";
const GROUP: &str = "cmux";
pub const DEFAULT_REGION: &str = "eastus2";
/// Regions that offer GlobalStandard Foundry models (Settings' region Select).
pub const REGIONS: &[&str] = &[
    "eastus",
    "eastus2",
    "westus",
    "westus3",
    "southcentralus",
    "northcentralus",
    "swedencentral",
    "uksouth",
    "francecentral",
    "japaneast",
    "australiaeast",
    "southindia",
];
const SKU: &str = "GlobalStandard";
/// 100 units is 100,000 tokens per minute for the standard chat models.
const DEPLOY_CAPACITY: u64 = 100;
const TAG: &str = "managed-by=cmux";
// timeout: one az call; account create/delete and the browser sign-in take a few minutes
const AZ_TIMEOUT: Duration = Duration::from_secs(600);
// timeout: Azure serves a new deployment within about five minutes of its create
const SERVE_WAIT: Duration = Duration::from_secs(900);

/// What Settings' Foundry steps show: `{az, opencode, account, enabled, region, regions}`.
/// Reads az's own profile file, never runs az, so a state read stays cheap.
pub fn status() -> Value {
    let dir = std::env::var_os("AZURE_CONFIG_DIR")
        .map(std::path::PathBuf::from)
        .or_else(|| dirs::home_dir().map(|h| h.join(".azure")));
    let text = dir.and_then(|d| std::fs::read_to_string(d.join("azureProfile.json")).ok());
    let profile: Value = text
        .and_then(|t| serde_json::from_str(t.trim_start_matches('\u{feff}')).ok())
        .unwrap_or_default();
    let subs = profile["subscriptions"].as_array().cloned().unwrap_or_default();
    let account = subs.iter().find(|s| s["isDefault"] == true).map(|s| &s["user"]["name"]);
    let enabled = user_file(&format!("{HARNESS_ID}.toml")).is_some_and(|p| p.is_file());
    // Written on every connect and left after Turn Off, so the switch comes back in the same region.
    let region = user_file("foundry.region")
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty());
    let az = crate::config::which("az").is_some();
    let opencode = crate::harness_install::opencode_path().is_some();
    let mut status = json!({
        "az": az,
        "opencode": opencode,
        "account": account,
        "enabled": enabled,
        "region": region,
        "regions": REGIONS,
    });
    // Present only while Install is running, so a later read does not keep a finished bar.
    if let Some(install) = install_value(INSTALL.lock().unwrap_or_else(|e| e.into_inner()).as_ref())
    {
        status["install"] = install;
    }
    status
}

/// `status` plus `order`: where the person dragged the Foundry row among their connections (its
/// index in `connection_order`, the full row order a reorder stores), or null for the default (the
/// end). Foundry is a harness, not a connection, so its token (`HARNESS_ID`) rides in
/// `connection_order` only for this placement; routing ignores it.
pub fn status_with_order(connection_order: &[String]) -> Value {
    let mut status = status();
    let order = connection_order.iter().position(|id| id == HARNESS_ID);
    status["order"] = order.map_or(Value::Null, |n| json!(n));
    status
}

/// Installs OpenCode (the harness runs on it) when needed, signs in (browser) when needed, then
/// the group, the account and the harness. The account name is what a region switch deletes.
pub async fn connect(cfg: &Config, region: &str) -> Result<String, String> {
    let region = check_region(region)?;
    let program = opencode_program().await?;
    let account = match az(&["account", "show"]).await {
        Ok(v) => v,
        Err(_) => {
            az(&["login"]).await?;
            az(&["account", "show"]).await?
        }
    };
    let sub = account["id"].as_str().ok_or("This Azure account has no subscription")?;
    let ns = "Microsoft.CognitiveServices";
    az(&["provider", "register", "--namespace", ns, "--wait"]).await?;
    // `group create` on an existing group replaces its tags, so it runs only when there is none.
    match az(&["group", "show", "-n", GROUP]).await {
        Ok(group) if group_owned(&group) => {}
        Ok(_) => return Err(format!("Resource group {GROUP} exists and was not made by cmux")),
        Err(_) => {
            _ = az(&["group", "create", "-n", GROUP, "-l", DEFAULT_REGION, "--tags", TAG]).await?
        }
    }
    let name = account_name(sub, region);
    ensure_account(&name, region).await?;
    let keys = az_account(&name, &["keys", "list"], &[]).await?;
    let key = keys["key1"].as_str().ok_or("no key on the Foundry account")?;
    let key = zeroize::Zeroizing::new(key.to_owned());
    let models = chat_models(&az_account(&name, &["list-models"], &[]).await?);
    let p = AddParams {
        id: Some(HARNESS_ID.into()),
        display_name: Some("Microsoft Foundry".into()),
        example: Some("openai-endpoint".into()),
        base_url: Some(format!("https://{name}.openai.azure.com/openai/v1")),
        models,
        replace: true,
        icon: Some("foundry.png".into()),
        program,
        ..AddParams::default()
    };
    let cfg = cfg.clone();
    let region_file = region.to_owned();
    let add = move || {
        let sources = ProfileSources::current();
        // The PNG next to foundry.toml; iconSpec inlines it for every client (Mac and phone).
        // `foundry.region` survives Turn Off so the switch reconnects in the same place.
        if let Some(png) = user_file("foundry.png")
            && let Some(dir) = png.parent().map(std::path::Path::to_path_buf)
        {
            std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            std::fs::write(png, include_bytes!("foundry.png")).map_err(|e| e.to_string())?;
            std::fs::write(dir.join("foundry.region"), &region_file).map_err(|e| e.to_string())?;
        }
        // `foundry` is this path's id: after Turn Off the daemon can still list it with no user
        // file (sticky spare), and `taken_elsewhere` would refuse the reconnect.
        let elsewhere = harness_admin::taken_elsewhere(&cfg, &sources);
        let taken = |id: &str| id != HARNESS_ID && elsewhere(id);
        let store = &crate::cli::harness_secret::run_store;
        let key = EndpointKey { value: Some(key.as_str()), store, taken: &taken };
        harness_admin::add_endpoint_keyed(&p, &sources, &key).map(|_| ()).map_err(|e| e.to_string())
    };
    tokio::task::spawn_blocking(add).await.map_err(|e| e.to_string())??;
    Ok(name)
}

/// OpenCode, installed first when this machine has none (the person turned Foundry on). Some
/// path when the login PATH does not list it (OpenCode's installer's `~/.opencode/bin`): the
/// harness spawns from that PATH.
async fn opencode_program() -> Result<Option<String>, String> {
    let path = match crate::harness_install::opencode_path() {
        Some(path) => path,
        None => {
            let log = |step: &str, state: &str, detail: &str| {
                let (phase, text) = opencode_status(step, state);
                note("opencode", phase, text);
                tracing::info!(step, state, detail, "foundry: installing OpenCode");
            };
            let installed = crate::harness_install::install("opencode", log)
                .await
                .map_err(|e| format!("Microsoft Foundry runs on OpenCode, and {e:#}"))?;
            installed["path"].as_str().map(std::path::PathBuf::from).ok_or("no OpenCode path")?
        }
    };
    let login = crate::login_env::path().unwrap_or_default();
    Ok(program_for(&path, &login))
}

fn program_for(path: &std::path::Path, login_path: &std::ffi::OsStr) -> Option<String> {
    let listed = crate::config::which_in(login_path, "opencode");
    (listed.as_deref() != Some(&*path.to_string_lossy())).then(|| path.display().to_string())
}

/// Removes the harness and its Keychain key; the Azure resources stay. Already off is fine.
pub fn disconnect(cfg: &Config, home: &std::path::Path) -> Result<(), String> {
    if user_file(&format!("{HARNESS_ID}.toml")).is_none_or(|p| !p.is_file()) {
        return Ok(());
    }
    let sources = ProfileSources::current();
    let forget = &crate::cli::harness_secret::run_delete;
    harness_admin::remove(HARNESS_ID, cfg, &sources, home, Some(forget))
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// One Settings step (`_acpmux/connections/foundry.set`): `install` OpenCode and the Azure CLI,
/// `login` to Azure in the browser, the harness `on` (connect) or `off`, or `region` to move the
/// cmux account.
pub async fn set(
    step: &str,
    region: Option<&str>,
    cfg: &Config,
    home: &std::path::Path,
) -> Result<(), String> {
    match step {
        "install" => install_deps().await,
        "login" => az(&["login"]).await.map(|_| ()),
        "on" => connect(cfg, region.unwrap_or(DEFAULT_REGION)).await.map(|_| ()),
        "region" => {
            let region = region.ok_or("Microsoft Foundry needs a region")?;
            switch_region(cfg, region).await
        }
        "off" => {
            let (cfg, home) = (cfg.clone(), home.to_path_buf());
            tokio::task::spawn_blocking(move || disconnect(&cfg, &home))
                .await
                .map_err(|e| e.to_string())?
        }
        other => Err(format!("Microsoft Foundry has no step `{other}`")),
    }
}

/// Creates the account in `region`, rewrites the harness, then deletes and purges the old one.
async fn switch_region(cfg: &Config, region: &str) -> Result<(), String> {
    let region = check_region(region)?;
    let old = cfg.profile(HARNESS_ID).and_then(|p| account_of(&p.env));
    let new = connect(cfg, region).await?;
    let Some(old) = old else { return Ok(()) };
    if old == new {
        return Ok(());
    }
    // A Failed account rejects delete until its deployments are gone.
    remove_account(&old, region_of(&old)).await
}

/// One tool's line under its Install bar: `running`, `done` or `error`, and the short status.
struct ToolNote {
    state: &'static str,
    detail: String,
}

struct InstallNotes {
    opencode: ToolNote,
    az: ToolNote,
}

/// Cleared when `install_deps` returns. A state read during the run carries it as `foundry.install`.
static INSTALL: Mutex<Option<InstallNotes>> = Mutex::new(None);

fn install_value(notes: Option<&InstallNotes>) -> Option<Value> {
    let notes = notes?;
    let tool = |note: &ToolNote| json!({"state": note.state, "detail": note.detail});
    Some(json!({"opencode": tool(&notes.opencode), "az": tool(&notes.az)}))
}

/// OpenCode's installer steps, as the short line under its bar.
fn opencode_status(step: &str, state: &str) -> (&'static str, &'static str) {
    match (step, state) {
        ("download", "running") => ("running", "Downloading…"),
        ("download", "done") => ("running", "Downloaded"),
        ("install", "done") | ("check", "done") => ("done", "Installed"),
        _ => ("running", "Installing…"),
    }
}

fn note(tool: &str, state: &'static str, detail: &str) {
    let mut slot = INSTALL.lock().unwrap_or_else(|e| e.into_inner());
    let Some(notes) = slot.as_mut() else { return };
    let tool = if tool == "opencode" { &mut notes.opencode } else { &mut notes.az };
    tool.state = state;
    tool.detail = detail.to_owned();
}

/// Drops the install record when the run ends, including when a tool fails.
struct EndInstall;
impl Drop for EndInstall {
    fn drop(&mut self) {
        *INSTALL.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

/// OpenCode and the Azure CLI together when both are missing. OpenCode then uses its official
/// installer (`~/.opencode/bin`) so it does not share Homebrew's prefix with `brew install azure-cli`.
/// One tool already present is left as it is.
async fn install_deps() -> Result<(), String> {
    let need_opencode = crate::harness_install::opencode_path().is_none();
    let need_az = crate::config::which("az").is_none();
    let ready = |need: bool| ToolNote {
        state: if need { "running" } else { "done" },
        detail: if need { "Installing…".into() } else { "Installed".into() },
    };
    *INSTALL.lock().unwrap_or_else(|e| e.into_inner()) =
        Some(InstallNotes { opencode: ready(need_opencode), az: ready(need_az) });
    let _end = EndInstall;
    let opencode = async {
        if !need_opencode {
            return Ok(());
        }
        let result = if need_az {
            crate::harness_install::install_opencode_official(|step, state, detail| {
                let (phase, text) = opencode_status(step, state);
                note("opencode", phase, text);
                tracing::info!(step, state, detail, "foundry: installing OpenCode");
            })
            .await
            .map(|_| ())
            .map_err(|e| format!("Microsoft Foundry runs on OpenCode, and {e:#}"))
        } else {
            opencode_program().await.map(|_| ())
        };
        match &result {
            Ok(()) => note("opencode", "done", "Installed"),
            Err(e) => note("opencode", "error", e),
        }
        result
    };
    let azure = async {
        if !need_az {
            return Ok(());
        }
        let result = install_azure_cli().await;
        match &result {
            Ok(()) => note("az", "done", "Installed"),
            Err(e) => note("az", "error", e),
        }
        result
    };
    let (opencode, azure) = tokio::join!(opencode, azure);
    match (opencode, azure) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
        (Err(opencode), Err(azure)) => Err(format!("{opencode} {azure}")),
    }
}

async fn install_azure_cli() -> Result<(), String> {
    let brew = crate::config::which("brew")
        .ok_or("The Azure CLI installs with Homebrew (brew.sh), which this Mac does not have")?;
    crate::harness_install::run_tool(&brew, &["install", "azure-cli"])
        .await
        .map_err(|e| format!("{e:#}"))
}

fn check_region(region: &str) -> Result<&str, String> {
    REGIONS
        .iter()
        .copied()
        .find(|&r| r == region)
        .ok_or_else(|| format!("Microsoft Foundry has no region `{region}`"))
}

fn account_name(sub: &str, region: &str) -> String {
    format!("cmux-{}-{region}", &crate::sha256::sha256_hex(sub.as_bytes())[..12])
}

/// The account a Foundry harness calls: `resourceName` in the Azure OpenCode config.
pub fn account_of(profile_env: &std::collections::BTreeMap<String, String>) -> Option<String> {
    let content = profile_env.get("OPENCODE_CONFIG_CONTENT")?;
    let v: Value = serde_json::from_str(content).ok()?;
    v["provider"]["azure"]["options"]["resourceName"].as_str().map(str::to_owned)
}

/// The region encoded in a cmux account name (`cmux-{12 hex}-{region}`), or `eastus2` for the
/// legacy `cmux-{12 hex}` name.
pub fn region_of(account: &str) -> &str {
    account.splitn(3, '-').nth(2).filter(|region| !region.is_empty()).unwrap_or(DEFAULT_REGION)
}

pub async fn deployed(account: &str, model: &str) -> bool {
    az_account(account, &["deployment", "show"], &["--deployment-name", model])
        .await
        .is_ok_and(|d| d["provisioningState"] == "Succeeded")
}

/// A GlobalStandard deployment named as the model, so the picker's `azure/<model>` reaches it, then
/// a wait until Azure serves it (DeploymentNotFound for minutes after the create returns).
pub async fn deploy(account: &str, model: &str) -> Result<(), String> {
    let list = az_account(account, &["list-models"], &[]).await?;
    let entry = list.as_array().and_then(|l| l.iter().find(|m| m["name"] == model));
    let entry = entry.ok_or_else(|| format!("{model} is not offered on this Foundry account"))?;
    let version = entry["version"].as_str().unwrap_or("1").to_owned();
    let format = entry["format"].as_str().unwrap_or("OpenAI").to_owned();
    // 100 first. A refusal is a quota miss, so the search keeps the largest capacity Azure accepts.
    largest(DEPLOY_CAPACITY, |capacity| place(account, model, &version, &format, capacity)).await?;
    let keys = az_account(account, &["keys", "list"], &[]).await?;
    let key = keys["key1"].as_str().ok_or("no key on the Foundry account")?;
    let deadline = tokio::time::Instant::now() + SERVE_WAIT;
    while !serving(account, model, key).await {
        if tokio::time::Instant::now() >= deadline {
            return Err(format!("Azure is not serving {model} yet; send again in a few minutes"));
        }
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
    Ok(())
}

/// Whether Azure's v1 chat endpoint (OpenCode's baseURL) has `model`: a 404 / DeploymentNotFound
/// until it does. The ping uses `max_completion_tokens` (Azure refuses `max_tokens` on these models).
async fn serving(account: &str, model: &str, key: &str) -> bool {
    // The workspace builds reqwest with `rustls-no-provider` (as `harness_install::fetch`).
    let _ = rustls::crypto::ring::default_provider().install_default();
    let url = format!("https://{account}.openai.azure.com/openai/v1/chat/completions");
    // A tiny completion budget still proves the deployment exists; 1 often fails with
    // "max_tokens or model output limit" on reasoning models (still means it is up).
    let body = json!({
        "model": model,
        "messages": [{"role": "user", "content": "ping"}],
        "max_completion_tokens": 16,
    });
    let request = reqwest::Client::new().post(url).header("api-key", key).json(&body);
    let Ok(reply) = request.timeout(Duration::from_secs(60)).send().await else {
        return false;
    };
    let status = reply.status();
    if status == reqwest::StatusCode::NOT_FOUND {
        return false;
    }
    // Some Azure routes answer 400 with DeploymentNotFound in the body instead of 404.
    // A 429 rate limit still means the deployment is up.
    if let Ok(text) = reply.text().await
        && text.contains("DeploymentNotFound")
    {
        return false;
    }
    true
}

fn group_owned(group: &Value) -> bool {
    group["tags"]["managed-by"] == "cmux"
}

fn provisioning_state(account: &Value) -> &str {
    account["properties"]["provisioningState"]
        .as_str()
        .or_else(|| account["provisioningState"].as_str())
        .unwrap_or("")
}

/// A Failed account still answers `show`, then rejects `keys list` with
/// "Operation not allowed on the resource with provisioning state: Failed".
/// Drop it (and a soft-deleted name) so the next create can succeed.
async fn ensure_account(name: &str, region: &str) -> Result<(), String> {
    match az_account(name, &["show"], &[]).await {
        Ok(existing) if provisioning_state(&existing) == "Succeeded" => Ok(()),
        Ok(existing) => {
            let location = existing["location"].as_str().unwrap_or(region).to_owned();
            remove_account(name, &location).await?;
            create_account(name, region).await
        }
        Err(_) => {
            purge(name, region).await;
            create_account(name, region).await
        }
    }
}

async fn create_account(name: &str, region: &str) -> Result<(), String> {
    az_account(
        name,
        &["create"],
        &[
            "--kind",
            "AIServices",
            "--sku",
            "S0",
            "--yes",
            "--custom-domain",
            name,
            "-l",
            region,
            "--tags",
            TAG,
        ],
    )
    .await?;
    let shown = az_account(name, &["show"], &[]).await?;
    let state = provisioning_state(&shown);
    if state != "Succeeded" {
        return Err(format!("Azure left the Foundry account {name} in state {state}"));
    }
    Ok(())
}

async fn remove_account(name: &str, location: &str) -> Result<(), String> {
    if let Ok(list) = az_account(name, &["deployment", "list"], &[]).await {
        for deployment in list.as_array().into_iter().flatten() {
            let Some(dep) = deployment["name"].as_str() else { continue };
            az_account(name, &["deployment", "delete"], &["--deployment-name", dep]).await?;
        }
    }
    az_account(name, &["delete"], &[]).await?;
    purge(name, location).await;
    Ok(())
}

/// `cognitiveservices account <verb> -n NAME -g cmux`, plus any extra flags.
async fn az_account(name: &str, verb: &[&str], extra: &[&str]) -> Result<Value, String> {
    let mut args = vec!["cognitiveservices", "account"];
    args.extend(verb);
    args.extend(["-n", name, "-g", GROUP]);
    args.extend(extra);
    az(&args).await
}

/// A soft-deleted name blocks the next create. Purge failing (nothing to purge) is fine.
async fn purge(name: &str, location: &str) {
    let _ = az_account(name, &["purge"], &["-l", location]).await;
}

/// A profile file under the user dir (`foundry.toml`, `foundry.region`, `foundry.png`).
fn user_file(name: &str) -> Option<std::path::PathBuf> {
    ProfileSources::current().user_dir.map(|dir| dir.join(name))
}

/// The largest capacity in `1..=max` that `place` accepts. `max` is tried first; a refusal narrows
/// to the top of what is still open. The last refusal is the error when nothing fits.
async fn largest<F, Fut>(max: u64, mut place: F) -> Result<u64, String>
where
    F: FnMut(u64) -> Fut,
    Fut: std::future::Future<Output = Result<(), String>>,
{
    let mut ok = 0u64;
    let mut bad = max.saturating_add(1);
    let mut failure = None;
    let mut probe = max;
    loop {
        if probe == 0 || probe > max {
            break;
        }
        match place(probe).await {
            Ok(()) => ok = probe,
            Err(e) => {
                failure = Some(e);
                bad = probe;
            }
        }
        if bad <= ok.saturating_add(1) {
            break;
        }
        let next = ok + (bad - ok + 1) / 2;
        let next = if next >= bad { bad - 1 } else { next };
        if next <= ok {
            break;
        }
        probe = next;
    }
    if ok > 0 {
        Ok(ok)
    } else {
        Err(failure.unwrap_or_else(|| "Azure accepted no capacity".into()))
    }
}

/// Creates the deployment at `capacity` (create-or-update: the same name raises an existing one).
async fn place(
    account: &str,
    model: &str,
    version: &str,
    format: &str,
    capacity: u64,
) -> Result<(), String> {
    let capacity = capacity.to_string();
    az_account(
        account,
        &["deployment", "create"],
        &[
            "--deployment-name",
            model,
            "--model-name",
            model,
            "--model-version",
            version,
            "--model-format",
            format,
            "--sku-name",
            SKU,
            "--sku-capacity",
            &capacity,
        ],
    )
    .await
    .map(|_| ())
}

/// Chat models with a GlobalStandard SKU, not deprecated, not Claude (another API), one per name.
fn chat_models(list: &Value) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for m in list.as_array().into_iter().flatten() {
        let ok = m["capabilities"]["chatCompletion"] == "true"
            && m["lifecycleStatus"] != "Deprecated"
            && m["format"] != "Anthropic"
            && m["skus"].as_array().is_some_and(|s| s.iter().any(|s| s["name"] == SKU));
        if let (true, Some(name)) = (ok, m["name"].as_str())
            && !out.iter().any(|n| n == name)
            && out.len() < crate::byo_endpoint::MAX_MODELS
        {
            out.push(name.to_owned());
        }
    }
    out
}

/// One az call as JSON. The subscription prompt is off for this process only, so `az login`
/// opens the browser and asks nothing in a terminal.
async fn az(args: &[&str]) -> Result<Value, String> {
    let mut cmd = tokio::process::Command::new(crate::config::which("az").ok_or("no az")?);
    crate::login_env::apply_tokio(&mut cmd);
    cmd.args(args).args(["-o", "json", "--only-show-errors"]);
    cmd.env("AZURE_CORE_LOGIN_EXPERIENCE_V2", "off").stdin(Stdio::null()).kill_on_drop(true);
    let out = tokio::time::timeout(AZ_TIMEOUT, cmd.output()).await;
    let out = out.map_err(|_| format!("az {} timed out", args[0]))?.map_err(|e| e.to_string())?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        let line = err.lines().map(str::trim).find(|l| !l.is_empty());
        return Err(line.unwrap_or("az failed").to_owned());
    }
    Ok(serde_json::from_slice(&out.stdout).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_chat_models_on_global_standard() {
        let m = |name: &str, key: &str, value: Value| {
            let mut v = json!({"name": name, "format": "OpenAI", "lifecycleStatus": "GA",
                "capabilities": {"chatCompletion": "true"}, "skus": [{"name": SKU}]});
            v[key] = value;
            v
        };
        let list = json!([
            m("gpt-5-mini", "format", json!("OpenAI")),
            m("embed", "capabilities", json!({"embeddings": "true"})),
            m("old", "lifecycleStatus", json!("Deprecated")),
            m("claude", "format", json!("Anthropic")),
            m("regional", "skus", json!([{"name": "Standard"}])),
            m("gpt-5-mini", "format", json!("OpenAI")),
        ]);
        assert_eq!(chat_models(&list), ["gpt-5-mini"]);
    }

    #[test]
    fn a_failed_account_is_not_ready() {
        assert_eq!(
            provisioning_state(&json!({"properties": {"provisioningState": "Failed"}})),
            "Failed"
        );
        assert_eq!(
            provisioning_state(&json!({"properties": {"provisioningState": "Succeeded"}})),
            "Succeeded"
        );
    }

    #[test]
    fn an_idle_install_is_absent_and_a_running_one_names_each_tool() {
        assert!(install_value(None).is_none());
        let notes = InstallNotes {
            opencode: ToolNote { state: "running", detail: "Downloading…".into() },
            az: ToolNote { state: "done", detail: "Installed".into() },
        };
        let value = install_value(Some(&notes)).unwrap();
        assert_eq!(value["opencode"], json!({"state": "running", "detail": "Downloading…"}));
        assert_eq!(value["az"]["detail"], "Installed");
        assert!(status()["install"].is_null(), "nothing is installing");
    }

    #[test]
    fn status_order_is_the_harness_tokens_place_in_the_order_or_null() {
        assert_eq!(status_with_order(&[])["order"], Value::Null);
        let two = ["anthropic-key".to_owned(), HARNESS_ID.to_owned()];
        assert_eq!(status_with_order(&two)["order"], json!(1));
        let front = [HARNESS_ID.to_owned(), "anthropic-key".to_owned()];
        assert_eq!(status_with_order(&front)["order"], json!(0));
        assert_eq!(status_with_order(&["anthropic-key".to_owned()])["order"], Value::Null);
    }

    #[test]
    fn only_a_group_cmux_tagged_is_used() {
        assert!(!group_owned(&json!({"name": "cmux"})));
        assert!(!group_owned(&json!({"tags": {"managed-by": "someone"}})));
        assert!(group_owned(&json!({"tags": {"managed-by": "cmux"}})));
    }

    /// Icon and program go into the profile, and `account_of` reads the Azure host past `$schema`.
    #[test]
    fn the_profile_carries_icon_program_and_account() {
        let models = ["gpt-4o".to_owned()];
        let mut endpoint = crate::byo_endpoint::Endpoint {
            kind: crate::byo_endpoint::Kind::OpenAi,
            id: "foundry",
            name: "Microsoft Foundry",
            base_url: "https://example.openai.azure.com/openai/v1",
            models: &models,
            keychain_item: None,
            icon: None,
            program: None,
        };
        let plain = crate::byo_endpoint::profile_text(&endpoint);
        assert!(plain.contains("icon = \"opencode\"\n"));
        assert!(plain.contains("command = \"opencode\"\n"));
        endpoint.icon = Some("foundry.png");
        endpoint.program = Some("/Users/me/.opencode/bin/opencode");
        let text = crate::byo_endpoint::profile_text(&endpoint);
        assert!(text.contains("icon = \"foundry.png\"\n"));
        assert!(!text.contains("icon = \"opencode\"\n"));
        assert!(text.contains("command = \"/Users/me/.opencode/bin/opencode\"\n"));
        let env: std::collections::BTreeMap<String, String> =
            toml::from_str::<toml::Table>(&text).unwrap()["env"].clone().try_into().unwrap();
        assert_eq!(account_of(&env).as_deref(), Some("example"));
        // gpt-4o is not a reasoner, so OpenCode gets no effort variants for it.
        let config: Value = serde_json::from_str(&env["OPENCODE_CONFIG_CONTENT"]).unwrap();
        assert_eq!(
            config["provider"]["azure"]["models"]["gpt-4o"],
            json!({"name": "gpt-4o"}),
            "{config}"
        );
    }

    #[test]
    fn account_of_reads_the_resource_name() {
        let mut env = std::collections::BTreeMap::new();
        let content = json!({
            "$schema": "https://opencode.ai/config.json",
            "provider": {"azure": {
                "npm": "@ai-sdk/azure",
                "options": {"resourceName": "cmux-abc123def456-southindia", "apiVersion": "v1"},
            }},
        });
        env.insert("OPENCODE_CONFIG_CONTENT".into(), content.to_string());
        assert_eq!(account_of(&env).as_deref(), Some("cmux-abc123def456-southindia"));
    }

    /// 100 is tried first. Azure refusing anything above 60 leaves the deployment at 60, and a
    /// model nothing will take comes back as Azure's own refusal.
    #[tokio::test]
    async fn the_largest_capacity_azure_accepts_is_kept() {
        let tried = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let log = tried.clone();
        let got = largest(100, move |capacity| {
            let log = log.clone();
            async move {
                log.lock().unwrap().push(capacity);
                if capacity > 60 { Err("quota".into()) } else { Ok(()) }
            }
        })
        .await
        .unwrap();
        assert_eq!(got, 60);
        assert_eq!(tried.lock().unwrap().first().copied(), Some(100));

        let err = largest(100, |_| async { Err("no quota".into()) }).await.unwrap_err();
        assert!(err.contains("no quota"), "{err}");
    }

    #[test]
    fn region_of_reads_suffix_or_defaults() {
        assert_eq!(region_of("cmux-10d7e08108cf-southindia"), "southindia");
        assert_eq!(region_of("cmux-10d7e08108cf-eastus2"), "eastus2");
        assert_eq!(region_of("cmux-10d7e08108cf"), DEFAULT_REGION);
        assert_eq!(region_of("other"), DEFAULT_REGION);
    }

    #[test]
    fn an_unknown_region_is_refused() {
        assert!(check_region("eastus2").is_ok());
        assert!(check_region("not-a-region").unwrap_err().contains("not-a-region"));
    }

    /// A Foundry chat spawned `opencode` on a Mac without it: "spawn harness process opencode: No
    /// such file or directory". The profile names OpenCode by name when the login PATH finds that
    /// one, else by its path (OpenCode's own installer puts it in `~/.opencode/bin`).
    #[cfg(unix)]
    #[test]
    fn the_profile_names_opencode_by_path_only_off_the_login_path() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let [on_path, off_path] =
            ["bin", ".opencode/bin"].map(|d| dir.path().join(d).join("opencode"));
        for file in [&on_path, &off_path] {
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let login = std::env::join_paths([on_path.parent().unwrap()]).unwrap();
        assert_eq!(program_for(&on_path, &login), None);
        assert_eq!(program_for(&off_path, &login), Some(off_path.display().to_string()));
        assert_eq!(
            program_for(&off_path, std::ffi::OsStr::new("")),
            Some(off_path.display().to_string())
        );
    }
}
