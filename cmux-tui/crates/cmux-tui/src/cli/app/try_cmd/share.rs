//! `cmux app share`: share the cmux build you run as one `cmux app try <link>` line, and the share-link
//! form of `cmux app try` that opens it on another Mac.
//!
//! Leo (2026-11-19), on a teammate's signed-in dev build: "how can he find the thing in his finder then give
//! me the build? / and how do we improve this process in teh future?"
//!
//! A zipped `.app` sent by AirDrop is the old way, and it breaks twice: most dev builds are signed ad hoc, so
//! Gatekeeper blocks the quarantined copy on the other Mac, and the sign-in never goes with it (it lives in
//! the sender's keychain). So:
//! 1. **A SHA first.** When the build is a clean commit that is on feat-cmux-next, the line is
//!    `cmux app try <sha>`: nothing is uploaded, and the other Mac runs that commit the cheapest way there is.
//! 2. **Otherwise the build itself** (`--bundle` forces it): the running `.app`, zipped, goes to the team
//!    build cache (`PUT <store>/v1/tags/<tag>`, the store HQ's builds use), and the line is
//!    `cmux app try <store>/v1/tags/<tag>?backend=<env>`. The receiving CLI downloads it (no quarantine, so
//!    an ad hoc build runs), checks its sha256 and signature, unpacks it under `~/Applications/cmux Shared/`
//!    beside the person's own cmux (its own bundle id and data: nothing of theirs changes), points a DEV
//!    build at the sender's Cloud backend (`backend.json`) and opens it. Each person signs in with their own
//!    account: no login, token or keychain item is ever read or sent, and an Info.plist that carries a
//!    secret-looking value is refused.
//!
//! The store is `--store URL`, else `CMUX_APP_SHARE_STORE`, else `~/.config/cmux/app-share.json`
//! (`{"store": "https://..."}`, which the team's HQ menu bar app writes).

use std::fs;
use std::path::{Path, PathBuf};

use cmux_json::JsonGet as _;
use serde_json::{Value, json};

use super::super::super::{GlobalArgs, OutputMode};
use super::super::UsageError;
use super::live::{curl_get, sha256_file};
use super::resolve::REPO;
use crate::localization::ShareMessages;

/// The share store when `--store` names none.
pub(super) const STORE_ENV: &str = "CMUX_APP_SHARE_STORE";
/// `~/.config/cmux/app-share.json`, relative to HOME.
const STORE_FILE: &str = ".config/cmux/app-share.json";
/// Where shared builds are unpacked, relative to HOME.
const SHARED_DIR: &str = "Applications/cmux Shared";
/// The branch whose commits CI publishes builds of.
const BASE_BRANCH: &str = "feat-cmux-next";
/// A shared build's zip: the cache's own default artifact limit.
const MAX_ZIP_BYTES: u64 = 8 << 30;
const MANIFEST_MAX_BYTES: u64 = 64 << 10;

fn messages() -> &'static ShareMessages {
    &crate::localization::catalog().app_control.app_share
}

/// A parsed `cmux app share` command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Command {
    Help,
    Share { app: Option<PathBuf>, bundle: bool, store: Option<String>, dry_run: bool },
}

/// Parses the words after `app share`.
pub(in super::super) fn parse(rest: &[String]) -> Result<Command, UsageError> {
    let usage = || UsageError::new(messages().usage);
    let mut app = None;
    let mut bundle = false;
    let mut store = None;
    let mut dry_run = false;
    let mut iter = rest.iter();
    while let Some(word) = iter.next() {
        match word.as_str() {
            "help" | "--help" | "-h" => return Ok(Command::Help),
            "--bundle" => bundle = true,
            "--dry-run" => dry_run = true,
            "--app" => app = Some(PathBuf::from(iter.next().ok_or_else(usage)?)),
            "--store" => store = Some(iter.next().ok_or_else(usage)?.clone()),
            other if other.starts_with("--app=") => {
                app = other.strip_prefix("--app=").map(PathBuf::from);
            }
            other if other.starts_with("--store=") => {
                store = other.strip_prefix("--store=").map(str::to_owned);
            }
            other => {
                return Err(UsageError::new(
                    crate::localization::catalog()
                        .app_control
                        .unexpected_argument
                        .replace("{value}", other),
                ));
            }
        }
    }
    Ok(Command::Share { app, bundle, store, dry_run })
}

// ------------------------------------------------------------------ the link

/// A share link: `https://HOST/PREFIX/v1/tags/<tag>[?backend=<env>]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Link {
    /// Everything before `/v1/tags/`.
    pub store: String,
    pub tag: String,
    pub backend: Option<String>,
}

impl Link {
    pub(super) fn url(&self) -> String {
        let mut url = format!("{}/v1/tags/{}", self.store, self.tag);
        if let Some(backend) = &self.backend {
            url.push_str("?backend=");
            url.push_str(
                &url::form_urlencoded::byte_serialize(backend.as_bytes()).collect::<String>(),
            );
        }
        url
    }

    fn manifest_url(&self) -> String {
        format!("{}/v1/tags/{}", self.store, self.tag)
    }
}

/// Whether `tag` is a name the cache takes (`[A-Za-z0-9][A-Za-z0-9._-]{0,63}`).
fn valid_tag(tag: &str) -> bool {
    (1..=64).contains(&tag.len())
        && tag.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric())
        && tag.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

/// `text` as a share link: https only, a path ending `/v1/tags/<tag>`, at most a `backend` query.
pub(super) fn parse_link(text: &str) -> Option<Link> {
    let url = url::Url::parse(text.trim()).ok()?;
    if url.scheme() != "https" || url.host_str().is_none() || !url.username().is_empty() {
        return None;
    }
    let path = url.path();
    let (prefix, tag) = path.rsplit_once("/v1/tags/")?;
    if !valid_tag(tag) {
        return None;
    }
    let mut backend = None;
    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "backend" => backend = Some(value.into_owned()).filter(|v| !v.trim().is_empty()),
            _ => return None,
        }
    }
    let origin = url.origin().ascii_serialization();
    Some(Link { store: format!("{origin}{prefix}"), tag: tag.to_owned(), backend })
}

/// The store base: `flag`, else `env`, else the `store` of `file` (app-share.json's text). https only.
pub(super) fn store_from(
    flag: Option<&str>,
    env: Option<&str>,
    file: Option<&str>,
) -> Result<String, String> {
    let from_file = file
        .and_then(|text| serde_json::from_str::<Value>(text).ok())
        .and_then(|value| value.get_nonempty_str("store").map(str::to_owned));
    let chosen = [flag.map(str::to_owned), env.map(str::to_owned), from_file]
        .into_iter()
        .flatten()
        .map(|value| value.trim().trim_end_matches('/').to_owned())
        .find(|value| !value.is_empty())
        .ok_or_else(|| messages().no_store.to_owned())?;
    match url::Url::parse(&chosen) {
        Ok(url) if url.scheme() == "https" && url.host_str().is_some() => Ok(chosen),
        _ => Err(messages().store_not_https.replace("{store}", &chosen)),
    }
}

/// A Cloud backend the other Mac can reach: a named deployment or a tailnet stack, never this Mac's own
/// `local` one.
pub(super) fn shareable_backend(name: &str) -> Option<String> {
    match cmux_cloud_environment::Environment::parse(name).ok()? {
        cmux_cloud_environment::Environment::Local
        | cmux_cloud_environment::Environment::LocalOrigin(_) => None,
        environment => Some(environment.name()),
    }
}

// ------------------------------------------------------------------ the build

/// What a cmux `.app` says about itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Build {
    pub app: PathBuf,
    pub bundle_id: String,
    pub name: String,
    pub commit: Option<String>,
    pub dirty: bool,
    pub tag: Option<String>,
}

/// LSEnvironment keys whose value must never leave the Mac.
pub(super) fn secret_key(key: &str) -> bool {
    let upper = key.to_ascii_uppercase();
    ["TOKEN", "SECRET", "PASSWORD", "API_KEY", "PRIVATE_KEY", "CREDENTIAL"]
        .iter()
        .any(|word| upper.contains(word))
        && !upper.ends_with("_FILE")
}

fn read_build(app: &Path) -> Result<Build, String> {
    let plist_path = app.join("Contents/Info.plist");
    let info = plist::Value::from_file(&plist_path)
        .map_err(|e| format!("{}: {e}", plist_path.display()))?;
    let info = info.as_dictionary().ok_or("Info.plist is not a dictionary")?;
    let text = |key: &str| info.get(key).and_then(plist::Value::as_string).map(str::to_owned);
    let env = info.get("LSEnvironment").and_then(plist::Value::as_dictionary);
    if let Some(env) = env {
        for (key, value) in env {
            let set = value.as_string().is_some_and(|value| !value.trim().is_empty());
            if set && secret_key(key) {
                return Err(messages().secret_in_bundle.replace("{key}", key));
            }
        }
    }
    let commit = text("CMUXCommit")
        .map(|c| c.trim().to_ascii_lowercase())
        .filter(|c| (7..=40).contains(&c.len()) && c.bytes().all(|b| b.is_ascii_hexdigit()));
    Ok(Build {
        app: app.to_path_buf(),
        bundle_id: text("CFBundleIdentifier").unwrap_or_default(),
        name: text("CFBundleName").unwrap_or_else(|| app_name(app)),
        commit,
        dirty: info.get("CMUXCommitDirty").and_then(plist::Value::as_boolean).unwrap_or(false),
        tag: env
            .and_then(|env| env.get("CMUX_TAG"))
            .and_then(plist::Value::as_string)
            .map(str::to_owned),
    })
}

fn app_name(app: &Path) -> String {
    app.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").filter(|value| !value.is_empty()).map(PathBuf::from)
}

fn is_dev(bundle_id: &str, home: &Path) -> bool {
    cmux_cloud_environment::Resolver::new(bundle_id, home).is_ok_and(|r| r.dev_build())
}

/// A tagged DEV build's control socket: `cmux-debug-<tag>.sock`.
pub(super) fn debug_socket(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with("cmux-debug-") && name.ends_with(".sock"))
}

/// The DEV builds among the apps that answered (`answered`, in order), each once.
pub(super) fn dev_apps(answered: Vec<PathBuf>, is_dev_app: impl Fn(&Path) -> bool) -> Vec<PathBuf> {
    let mut apps: Vec<PathBuf> = Vec::new();
    for app in answered {
        if !apps.contains(&app) && is_dev_app(&app) {
            apps.push(app);
        }
    }
    apps
}

/// The `.app` of every DEV build that answers `system.identify` on its own socket (`/tmp`,
/// `~/.local/state/cmux-next`, where tagged builds put them, and classic's `~/.local/state/cmux`,
/// where builds before put them): the builds register themselves, nothing is scanned.
fn answering_apps(home: Option<&Path>) -> Vec<PathBuf> {
    let mut dirs = vec![PathBuf::from("/tmp")];
    if let Some(home) = home {
        dirs.push(cmux_agent_pane_policy::build_identity::socket_state_dir(home));
        dirs.push(home.join(cmux_agent_pane_policy::build_identity::SOCKET_STATE_DIR_BEFORE));
    }
    let mut apps = Vec::new();
    for dir in dirs {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for socket in entries.filter_map(|entry| entry.ok().map(|entry| entry.path())) {
            if !debug_socket(&socket) {
                continue;
            }
            let Ok(mut stream) = super::super::connect(&socket) else { continue };
            let reply = super::super::exchange(
                &mut stream,
                "system.identify",
                json!({}),
                std::time::Duration::from_secs(2),
            );
            if let Ok(Ok(value)) = reply
                && let Some(app) = value.get_nonempty_str("app_bundle_path")
            {
                apps.push(PathBuf::from(app));
            }
        }
    }
    apps
}

/// The build to share: `--app`, else the one cmux DEV build running, else the app behind the socket.
fn pick_app(global: &GlobalArgs, named: Option<&Path>) -> Result<PathBuf, String> {
    if let Some(app) = named {
        return Ok(app.to_path_buf());
    }
    let home = home();
    let dev = dev_apps(answering_apps(home.as_deref()), |app| {
        home.as_deref()
            .is_some_and(|home| read_build(app).is_ok_and(|build| is_dev(&build.bundle_id, home)))
    });
    match dev.as_slice() {
        [one] => Ok(one.clone()),
        [] => super::find_app(global, None).0.ok_or_else(|| messages().no_app.to_owned()),
        many => {
            let lines: Vec<String> = many
                .iter()
                .map(|app| {
                    format!(
                        "  cmux app share --app {}",
                        super::copy::shell_word(&app.to_string_lossy())
                    )
                })
                .collect();
            Err(messages().many_dev.replace("{apps}", &lines.join("\n")))
        }
    }
}

/// Whether `commit` is on feat-cmux-next, and its full sha: GitHub's compare of the branch with it says
/// `behind` or `identical`.
pub(super) fn merged_commit(status: u16, body: &[u8]) -> Result<Option<String>, String> {
    if matches!(status, 404 | 422) {
        return Ok(None);
    }
    if status != 200 {
        return Err(format!("GitHub answered HTTP {status}"));
    }
    let value: Value = serde_json::from_slice(body).map_err(|_| "GitHub's answer is not JSON")?;
    let merged = matches!(value.get_str("status"), Some("behind" | "identical"));
    let sha = value.pointer("/merge_base_commit/sha").and_then(Value::as_str).unwrap_or_default();
    Ok((merged && cmux_host::updater::channel::lower_hex(sha, 40)).then(|| sha.to_owned()))
}

fn lookup_merged(commit: &str) -> Result<Option<String>, String> {
    let base = std::env::var(super::resolve::API_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "https://api.github.com".to_owned());
    let url =
        format!("{}/repos/{REPO}/compare/{BASE_BRANCH}...{commit}", base.trim_end_matches('/'));
    let headers = ["Accept: application/vnd.github+json", "X-GitHub-Api-Version: 2022-11-28"];
    let (status, body) = curl_get(&url, &headers, 8 << 20)?;
    merged_commit(status, &body)
}

/// How the build goes to the other Mac.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Way {
    /// Its commit, on feat-cmux-next and clean: `cmux app try <sha>`.
    Sha(String),
    /// The `.app` itself, and why not the SHA.
    Bundle(&'static str),
}

pub(super) fn choose(
    build: &Build,
    force_bundle: bool,
    merged: impl FnOnce(&str) -> Result<Option<String>, String>,
) -> Way {
    let messages = messages();
    if force_bundle {
        return Way::Bundle(messages.why_asked);
    }
    let Some(commit) = &build.commit else { return Way::Bundle(messages.why_no_commit) };
    if build.dirty {
        return Way::Bundle(messages.why_dirty);
    }
    match merged(commit) {
        Ok(Some(full)) => Way::Sha(full),
        Ok(None) => Way::Bundle(messages.why_unmerged),
        Err(_) => Way::Bundle(messages.why_unknown),
    }
}

/// The cache tag of a shared zip: `share-<tag or app name>-<sha256 prefix>`.
pub(super) fn share_tag(build: &Build, sha256: &str) -> String {
    let source = build.tag.clone().unwrap_or_else(|| build.name.clone()).to_ascii_lowercase();
    let mut slug = String::new();
    for c in source.chars() {
        let c = if c.is_ascii_alphanumeric() { c } else { '-' };
        if !(c == '-' && (slug.is_empty() || slug.ends_with('-'))) {
            slug.push(c);
        }
    }
    let slug: String = slug.trim_end_matches('-').chars().take(40).collect();
    let slug = slug.trim_end_matches('-');
    let digest = sha256.get(..12).unwrap_or(sha256);
    if slug.is_empty() { format!("share-{digest}") } else { format!("share-{slug}-{digest}") }
}

/// The Cloud backend the build uses now, when the other Mac can reach it.
fn backend_of(build: &Build) -> Option<String> {
    let home = home()?;
    let resolver = cmux_cloud_environment::Resolver::new(&build.bundle_id, &home).ok()?;
    let selection = resolver.resolve(None).ok()?;
    shareable_backend(&selection.name)
}

// ------------------------------------------------------------------ share

pub(in super::super) fn run(global: &GlobalArgs, command: &Command) -> i32 {
    let messages = messages();
    let Command::Share { app, bundle, store, dry_run } = command else {
        println!("{}", messages.usage);
        return 0;
    };
    if !cfg!(target_os = "macos") {
        return failure("share.not_mac", messages.not_mac, global.output);
    }
    let app = match pick_app(global, app.as_deref()) {
        Ok(app) => app,
        Err(error) => return failure("share.no_app", &error, global.output),
    };
    let build = match read_build(&app) {
        Ok(build) => build,
        Err(error) => return failure("share.refused", &error, global.output),
    };
    let backend = backend_of(&build);
    let way = choose(&build, *bundle, lookup_merged);
    if let Way::Sha(commit) = &way {
        let command = format!("cmux app try {commit}");
        let mut note =
            messages.sha_note.replace("{name}", &build.name).replace("{commit}", short(commit));
        if let Some(backend) = backend.as_deref().filter(|b| *b != "prod") {
            note.push('\n');
            note.push_str(&messages.sha_backend.replace("{backend}", backend));
        }
        return report(
            global,
            &command,
            None,
            &note,
            json!({ "way": "sha", "commit": commit, "backend": backend }),
        );
    }
    let Way::Bundle(why) = way else { return 1 };
    let file = home().and_then(|home| fs::read_to_string(home.join(STORE_FILE)).ok());
    let env = std::env::var(STORE_ENV).ok();
    let store = match store_from(store.as_deref(), env.as_deref(), file.as_deref()) {
        Ok(store) => store,
        Err(error) => return failure("share.no_store", &error, global.output),
    };
    if *dry_run {
        let text = messages
            .plan_bundle
            .replace("{name}", &build.name)
            .replace("{why}", why)
            .replace("{store}", &store);
        if global.output == OutputMode::Human {
            eprintln!("{text}\n{}", super::messages().dry_run);
            return 0;
        }
        return super::super::super::wire::print_local_success(
            &json!({ "way": "bundle", "why": why, "store": store, "app": app.to_string_lossy(), "dry_run": true }),
            global.output,
        );
    }
    if global.output == OutputMode::Human {
        eprintln!("{}", messages.uploading.replace("{name}", &build.name).replace("{why}", why));
    }
    let (tag, size) = match upload(&build, &store) {
        Ok(done) => done,
        Err(error) => return failure("share.upload_failed", &error, global.output),
    };
    let link = Link { store, tag, backend };
    let command = format!("cmux app try {}", link.url());
    let note = messages
        .bundle_note
        .replace("{name}", &build.name)
        .replace("{why}", why)
        .replace("{size}", &format!("{:.0}", size as f64 / 1_048_576.0));
    report(
        global,
        &command,
        Some(&link.url()),
        &note,
        json!({ "way": "bundle", "why": why, "tag": link.tag, "backend": link.backend, "size": size }),
    )
}

/// Zips `build.app`, checks it, and PUTs it to the store: the tag and the zip's size.
fn upload(build: &Build, store: &str) -> Result<(String, u64), String> {
    let dir = tempfile::tempdir().map_err(|e| e.to_string())?;
    let zip = dir.path().join("build.zip");
    let output = cmux_process::Command::new("/usr/bin/ditto")
        .args(["-c", "-k", "--sequesterRsrc", "--keepParent"])
        .arg(&build.app)
        .arg(&zip)
        .output()
        .map_err(|e| format!("ditto: {e}"))?;
    if !output.status.success() {
        return Err(format!("ditto: {}", String::from_utf8_lossy(&output.stderr).trim()));
    }
    let size = fs::metadata(&zip).map_err(|e| e.to_string())?.len();
    if size > MAX_ZIP_BYTES {
        return Err(format!("the zipped build is {size} bytes, over {MAX_ZIP_BYTES}"));
    }
    let sha256 = sha256_file(&zip)?;
    let tag = share_tag(build, &sha256);
    let url = format!("{store}/v1/tags/{tag}");
    let output = cmux_process::Command::new("curl")
        .args([
            "-fsS",
            "--proto",
            "=https",
            "--max-time",
            "1800",
            "-A",
            "cmux-app-share/1",
            "-X",
            "PUT",
        ])
        .args(["-H", &format!("X-Cmux-SHA256: {sha256}"), "-H", "Content-Type: application/zip"])
        .arg("-T")
        .arg(&zip)
        .arg(&url)
        .output()
        .map_err(|e| format!("curl: {e}"))?;
    if !output.status.success() {
        return Err(format!("{url}: {}", String::from_utf8_lossy(&output.stderr).trim()));
    }
    Ok((tag, size))
}

/// The one line to send goes to stdout; what it is goes to stderr, so `cmux app share | pbcopy` copies the line.
fn report(
    global: &GlobalArgs,
    command: &str,
    link: Option<&str>,
    note: &str,
    mut value: Value,
) -> i32 {
    if global.output == OutputMode::Human {
        eprintln!("{note}\n{}", messages().send_this);
        println!("{command}");
        eprintln!("{}", messages().habit);
        return 0;
    }
    if let Some(object) = value.as_object_mut() {
        object.insert("command".to_owned(), json!(command));
        object.insert(
            "link".to_owned(),
            json!(link.unwrap_or(command.trim_start_matches("cmux app try "))),
        );
    }
    super::super::super::wire::print_local_success(&value, global.output)
}

fn short(commit: &str) -> &str {
    commit.get(..12).unwrap_or(commit)
}

fn failure(code: &str, message: &str, output: OutputMode) -> i32 {
    super::super::super::wire::print_local_error(
        &json!({ "code": code, "message": message }),
        output,
        1,
    )
}

// ------------------------------------------------------------------ open a link

/// `cmux app try <share link>`: download the shared build, check it, unpack it beside the person's cmux,
/// point a DEV build at the link's backend, open it.
pub(super) fn open_link(global: &GlobalArgs, link: &Link, dry_run: bool) -> i32 {
    let messages = messages();
    if !cfg!(target_os = "macos") {
        return failure("share.not_mac", messages.not_mac, global.output);
    }
    let Some(home) = home() else {
        return failure("try.no_state", super::messages().no_state, global.output);
    };
    let manifest = match curl_get(&link.manifest_url(), &[], MANIFEST_MAX_BYTES) {
        Ok((200, body)) => serde_json::from_slice::<Value>(&body).ok(),
        Ok((404, _)) => {
            return failure(
                "share.not_found",
                &messages.link_gone.replace("{tag}", &link.tag),
                global.output,
            );
        }
        Ok((status, _)) => {
            let error = format!("HTTP {status}");
            return failure(
                "share.fetch_failed",
                &messages.link_failed.replace("{error}", &error),
                global.output,
            );
        }
        Err(error) => {
            return failure(
                "share.fetch_failed",
                &messages.link_failed.replace("{error}", &error),
                global.output,
            );
        }
    };
    let sha256 = manifest.as_ref().and_then(|m| m.get_nonempty_str("sha256")).map(str::to_owned);
    let size = manifest.as_ref().and_then(|m| m.get("sizeBytes")).and_then(Value::as_u64);
    let (Some(sha256), Some(size)) =
        (sha256.filter(|s| cmux_host::updater::channel::lower_hex(s, 64)), size)
    else {
        return failure(
            "share.bad_manifest",
            &messages.link_failed.replace("{error}", "no sha256 and size"),
            global.output,
        );
    };
    let dest = home.join(SHARED_DIR).join(&link.tag);
    if dry_run {
        let text = messages
            .plan_open
            .replace("{tag}", &link.tag)
            .replace("{dest}", &dest.to_string_lossy());
        if global.output == OutputMode::Human {
            println!("{text}\n{}", super::messages().dry_run);
            return 0;
        }
        return super::super::super::wire::print_local_success(
            &json!({ "tag": link.tag, "sha256": sha256, "size": size, "dest": dest.to_string_lossy(), "backend": link.backend, "dry_run": true }),
            global.output,
        );
    }
    let app = match unpack(link, &sha256, size, &dest) {
        Ok(app) => app,
        Err(error) => {
            return failure(
                "share.failed",
                &messages.link_failed.replace("{error}", &error),
                global.output,
            );
        }
    };
    let build = match read_build(&app) {
        Ok(build) => build,
        Err(error) => return failure("share.refused", &error, global.output),
    };
    let signature = match signature(&app) {
        Ok(signature) => signature,
        Err(error) => {
            return failure(
                "share.unsigned",
                &messages.bad_signature.replace("{error}", &error),
                global.output,
            );
        }
    };
    let backend = link.backend.as_deref().and_then(shareable_backend);
    let mut notes = Vec::new();
    match backend.as_deref() {
        Some(backend) if is_dev(&build.bundle_id, &home) => {
            if let Err(error) = write_backend(&build.bundle_id, &home, backend) {
                notes.push(messages.backend_failed.replace("{error}", &error));
            } else {
                notes.push(messages.backend_set.replace("{backend}", backend));
            }
        }
        Some(backend) => notes.push(messages.backend_ignored.replace("{backend}", backend)),
        None => {}
    }
    let opened = cmux_process::Command::new("/usr/bin/open").arg("-g").arg(&app).output();
    if let Err(error) = opened.as_ref().map_err(ToString::to_string).and_then(|out| {
        out.status
            .success()
            .then_some(())
            .ok_or_else(|| String::from_utf8_lossy(&out.stderr).trim().to_owned())
    }) {
        notes.push(messages.open_failed.replace("{error}", &error));
    }
    let value = json!({
        "tag": link.tag, "app": app.to_string_lossy(), "bundle_id": build.bundle_id,
        "commit": build.commit, "signature": signature, "backend": backend, "notes": notes,
    });
    if global.output != OutputMode::Human {
        return super::super::super::wire::print_local_success(&value, global.output);
    }
    let signed = match &signature {
        Value::String(team) => messages.signed_team.replace("{team}", team),
        _ => messages.signed_adhoc.to_owned(),
    };
    println!(
        "{}",
        messages
            .opened
            .replace("{name}", &build.name)
            .replace("{commit}", build.commit.as_deref().map(short).unwrap_or("?"))
            .replace("{signed}", &signed)
            .replace("{app}", &app.to_string_lossy())
    );
    for note in notes {
        println!("  {note}");
    }
    0
}

/// The shared `.app` under `dest`: reused when `dest` already holds this zip's build, else downloaded,
/// checked (size, sha256) and unpacked; exactly one `.app` at the zip's top.
fn unpack(link: &Link, sha256: &str, size: u64, dest: &Path) -> Result<PathBuf, String> {
    let marker = dest.join(".sha256");
    if fs::read_to_string(&marker).is_ok_and(|have| have.trim() == sha256)
        && let Some(app) = only_app(dest)
    {
        return Ok(app);
    }
    let parent = dest.parent().ok_or("no folder for shared builds")?;
    fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    let work = tempfile::tempdir_in(parent).map_err(|e| e.to_string())?;
    let zip = work.path().join("build.zip");
    let url = format!("{}/v1/artifacts/{sha256}.zip", link.store);
    let output = cmux_process::Command::new("curl")
        .args(["-fsS", "--proto", "=https", "--max-time", "1800", "-A", "cmux-app-try/1"])
        .args(["--max-filesize", &size.to_string(), "-o"])
        .arg(&zip)
        .arg(&url)
        .output()
        .map_err(|e| format!("curl: {e}"))?;
    if !output.status.success() {
        return Err(format!("{url}: {}", String::from_utf8_lossy(&output.stderr).trim()));
    }
    let have = fs::metadata(&zip).map_err(|e| e.to_string())?.len();
    if have != size {
        return Err(format!("{url} is {have} bytes, not {size}"));
    }
    let digest = sha256_file(&zip)?;
    if digest != sha256 {
        return Err(format!("{url} hashes to {digest}, not {sha256}"));
    }
    let out = work.path().join("out");
    let output = cmux_process::Command::new("/usr/bin/ditto")
        .args(["-x", "-k"])
        .arg(&zip)
        .arg(&out)
        .output()
        .map_err(|e| format!("ditto: {e}"))?;
    if !output.status.success() {
        return Err(format!("ditto: {}", String::from_utf8_lossy(&output.stderr).trim()));
    }
    let app = only_app(&out).ok_or("the shared zip does not hold exactly one .app")?;
    fs::write(out.join(".sha256"), sha256).map_err(|e| e.to_string())?;
    if dest.exists() {
        fs::remove_dir_all(dest).map_err(|e| format!("{}: {e}", dest.display()))?;
    }
    fs::rename(&out, dest).map_err(|e| format!("{}: {e}", dest.display()))?;
    Ok(dest.join(app.file_name().ok_or("no app name")?))
}

fn only_app(dir: &Path) -> Option<PathBuf> {
    let entries: Vec<PathBuf> = fs::read_dir(dir)
        .ok()?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| !path.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')))
        .collect();
    match entries.as_slice() {
        [app] if app.extension().is_some_and(|ext| ext == "app") && app.is_dir() => {
            Some(app.clone())
        }
        _ => None,
    }
}

/// `codesign` says the bundle is whole: its team id, or null for an ad hoc signature.
fn signature(app: &Path) -> Result<Value, String> {
    let verify = cmux_process::Command::new("/usr/bin/codesign")
        .args(["--verify", "--deep", "--strict"])
        .arg(app)
        .output()
        .map_err(|e| format!("codesign: {e}"))?;
    if !verify.status.success() {
        return Err(String::from_utf8_lossy(&verify.stderr).trim().to_owned());
    }
    let shown = cmux_process::Command::new("/usr/bin/codesign")
        .args(["-dv"])
        .arg(app)
        .output()
        .map_err(|e| format!("codesign: {e}"))?;
    Ok(team_of(&String::from_utf8_lossy(&shown.stderr)).map_or(Value::Null, Value::String))
}

/// `TeamIdentifier=` of `codesign -dv`'s output, unless it is not set (an ad hoc signature).
pub(super) fn team_of(text: &str) -> Option<String> {
    text.lines()
        .find_map(|line| line.strip_prefix("TeamIdentifier="))
        .map(str::trim)
        .filter(|team| !team.is_empty() && *team != "not set")
        .map(str::to_owned)
}

fn write_backend(bundle_id: &str, home: &Path, backend: &str) -> Result<(), String> {
    let resolver = cmux_cloud_environment::Resolver::new(bundle_id, home)?;
    let path = resolver.backend_path();
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let body = serde_json::to_string(&json!({ "backend": backend })).map_err(|e| e.to_string())?;
    fs::write(&path, body).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests;
