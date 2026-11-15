//! `cmux customize use pr:N`: an unmerged pull request as a library entry
//! (cmuxterm-hq `docs/design/experiments-shelf.md`).
//!
//! CI publishes a PR's web layer on dispatch (cmux-next-web-bundle-publish.yml
//! with `pr=N`): the PR head merged onto a base, built, and a pointer at
//! `files.cmux.com/cmux-next-web/pr/N/latest.json` (and `<head>-<base>.json`)
//! naming its web bundle key, the web ABI it needs and what else the PR
//! changes. `use pr:N` reads the pointer for this app's own commit first,
//! fetches and checks the bundles into a layer folder, and puts the PR on top
//! of the library, on. `library off pr-N` puts back what was under it.
//! `library refresh` follows each PR: a newer head is fetched, a merge that
//! is in this app's build turns the entry off, a web ABI the app no longer
//! has turns it off and says so.
//!
//! What a PR changes that a running app cannot take (Swift, resources, Rust
//! the app links) is listed on the entry as "needs a build".

use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use cmux_customize::library::{CodeLayer, code};
use cmux_customize::{Customize, Error};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::Failure;
use super::render::Answer;

const DEFAULT_BASE: &str = "https://files.cmux.com/cmux-next-web";
const REPO: &str = "manaflow-ai/cmux";
/// The largest web bundle archive a layer fetches (they are about 30 MB).
const MAX_ARCHIVE: u64 = 256 * 1024 * 1024;
/// Where each overlay surface sits in a published archive.
const SURFACES: [(&str, &str); 3] = [
    ("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/", "agent-pane"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/", "pages"),
    ("Resources/markdown-viewer/webviews-app/", "webviews-app"),
];
const APP_ABI: &str =
    "Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages/web-abi.json";

/// The PR a `use` source names: `pr:N`, `#N` or a pull request link (a
/// profile may be called `pr-N`, so that is not one).
pub(super) fn pr_number(source: &str) -> Option<u64> {
    let number = source.strip_prefix("pr:").or_else(|| source.strip_prefix('#')).or_else(|| {
        let rest = source
            .strip_prefix("https://github.com/")
            .and_then(|rest| rest.strip_prefix(REPO))
            .and_then(|rest| rest.strip_prefix("/pull/"))?;
        Some(rest.split(['/', '#', '?']).next().unwrap_or(rest))
    })?;
    number.parse::<u64>().ok().filter(|n| *n > 0)
}

/// The app this CLI changes: its commit and the web ABI its pages need.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct App {
    pub path: Option<PathBuf>,
    pub commit: Option<String>,
    pub abi: Option<u32>,
}

impl App {
    /// `CMUX_CUSTOMIZE_APP` names the app; else the app this CLI is inside.
    pub(super) fn find() -> App {
        let path = std::env::var_os("CMUX_CUSTOMIZE_APP")
            .filter(|path| !path.is_empty())
            .map(PathBuf::from)
            .or_else(|| {
                std::env::current_exe()
                    .ok()
                    .and_then(|exe| crate::app_identity::containing_app_bundle(&exe))
            });
        let Some(path) = path else { return App::default() };
        let commit = plist::Value::from_file(path.join("Contents/Info.plist"))
            .ok()
            .and_then(|plist| {
                plist.as_dictionary()?.get("CMUXCommit")?.as_string().map(str::to_owned)
            })
            // A NIGHTLY stamps a short commit; [`App::full_commit`] resolves it.
            .filter(|commit| is_hex_commit(commit));
        let abi = std::fs::read(path.join(APP_ABI))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .and_then(|value| value.get("abi").and_then(Value::as_u64))
            .map(|abi| abi as u32);
        App { path: Some(path), commit, abi }
    }
}

impl App {
    /// The app's commit in full: a short one is resolved on GitHub.
    fn full_commit(&mut self, http: &Http) {
        let Some(commit) = self.commit.clone().filter(|commit| !is_sha(commit)) else { return };
        let url = format!("https://api.github.com/repos/{REPO}/commits/{commit}");
        self.commit = http
            .get_json(&url)
            .ok()
            .flatten()
            .and_then(|value| value.get("sha").and_then(Value::as_str).map(str::to_owned))
            .filter(|sha| is_sha(sha) && sha.starts_with(&commit));
    }
}

fn is_hex_commit(text: &str) -> bool {
    (7..=40).contains(&text.len())
        && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn is_sha(text: &str) -> bool {
    text.len() == 40 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn base_url() -> String {
    std::env::var("CMUX_WEB_BUNDLES_BASE")
        .ok()
        .filter(|base| !base.is_empty())
        .unwrap_or_else(|| DEFAULT_BASE.to_owned())
        .trim_end_matches('/')
        .to_owned()
}

fn failure(why: String) -> Failure {
    Failure::from(Error::Library(why))
}

/// GETs, one current-thread runtime per verb.
struct Http {
    runtime: tokio::runtime::Runtime,
    client: reqwest::Client,
}

impl Http {
    fn new() -> Result<Http, Failure> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| failure(format!("could not start a network runtime: {error}")))?;
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(300))
            .user_agent(concat!("cmux-customize/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|error| failure(format!("could not start an HTTP client: {error}")))?;
        Ok(Http { runtime, client })
    }

    /// The body of `url`, `None` on a 404.
    fn get(&self, url: &str, limit: u64) -> Result<Option<Vec<u8>>, Failure> {
        self.runtime.block_on(async {
            let mut response = self
                .client
                .get(url)
                .header(reqwest::header::ACCEPT, "application/json, application/gzip")
                .send()
                .await
                .map_err(|error| failure(format!("{url}: {error}")))?;
            if response.status() == reqwest::StatusCode::NOT_FOUND {
                return Ok(None);
            }
            if !response.status().is_success() {
                return Err(failure(format!("{url}: HTTP {}", response.status())));
            }
            let mut body = Vec::new();
            while let Some(chunk) =
                response.chunk().await.map_err(|error| failure(format!("{url}: {error}")))?
            {
                body.extend_from_slice(&chunk);
                if body.len() as u64 > limit {
                    return Err(failure(format!("{url}: larger than {limit} bytes")));
                }
            }
            Ok(Some(body))
        })
    }

    fn get_json(&self, url: &str) -> Result<Option<Value>, Failure> {
        match self.get(url, 4 * 1024 * 1024)? {
            None => Ok(None),
            Some(bytes) => serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|_| failure(format!("{url}: not JSON"))),
        }
    }
}

/// The published pointer for PR `pr`: the one built on `commit` when there
/// is one, else the newest.
fn pointer(http: &Http, pr: u64, commit: Option<&str>) -> Result<Option<Value>, Failure> {
    let base = base_url();
    let latest = http.get_json(&format!("{base}/pr/{pr}/latest.json"))?;
    if let (Some(latest), Some(commit)) = (&latest, commit)
        && latest.get("base").and_then(Value::as_str) != Some(commit)
        && let Some(head) = latest.get("head").and_then(Value::as_str).filter(|head| is_sha(head))
        && let Some(exact) = http.get_json(&format!("{base}/pr/{pr}/{head}-{commit}.json"))?
    {
        return Ok(Some(exact));
    }
    Ok(latest)
}

/// What the pointer's live_apply verdict says needs a build, one line each.
pub(super) fn needs_build(classify: &Value) -> Vec<String> {
    let files = |kind: &str| {
        classify.pointer(&format!("/files/{kind}")).and_then(Value::as_array).map_or(0, Vec::len)
    };
    let mut out = Vec::new();
    if let Some(reasons) = classify.get("reasons").and_then(Value::as_object) {
        for (reason, paths) in reasons {
            let first = paths.as_array().and_then(|p| p.first()).and_then(Value::as_str);
            out.push(match first {
                Some(path) => format!("{reason} ({path})"),
                None => reason.clone(),
            });
        }
    }
    if files("swift-live") > 0 {
        out.push(format!(
            "Swift in {} (a live code build or a new build)",
            cmux_customize::count(files("swift-live"), "file")
        ));
    }
    if files("daemon") > 0 {
        out.push(format!(
            "Rust in {} (scripts/cmux-next/hot-apply.py from a checkout, or a new build)",
            cmux_customize::count(files("daemon"), "file")
        ));
    }
    out
}

/// The layer a pointer describes, for an app with `app`.
pub(super) fn layer_of(pointer: &Value, app: &App) -> Result<CodeLayer, Failure> {
    let field =
        |name: &str| pointer.get(name).and_then(Value::as_str).unwrap_or_default().to_owned();
    let pr = pointer
        .get("pr")
        .and_then(Value::as_u64)
        .ok_or_else(|| failure("the PR pointer has no pr".into()))?;
    let head = field("head");
    if !is_sha(&head) {
        return Err(failure(format!("the pointer for #{pr} names no head")));
    }
    let classify = pointer.get("classify").unwrap_or(&Value::Null);
    let has_web = classify
        .pointer("/files/web-live")
        .and_then(Value::as_array)
        .is_some_and(|files| !files.is_empty());
    let key = field("key");
    let abi = pointer.get("abi").and_then(Value::as_u64).map(|abi| abi as u32);
    let mut needs = needs_build(classify);
    let mut web = if has_web && code::valid_key(&key) { key } else { String::new() };
    if !web.is_empty()
        && let (Some(want), Some(have)) = (abi, app.abi)
        && want != have
    {
        needs.insert(0, format!("its web part needs web ABI {want}; this app has {have}"));
        web.clear();
    }
    Ok(CodeLayer {
        repo: pointer.get("repo").and_then(Value::as_str).unwrap_or(REPO).to_owned(),
        pr,
        title: field("title"),
        head,
        base: field("base"),
        web,
        abi,
        needs_build: needs,
        note: String::new(),
    })
}

/// Fetches layer `layer`'s web bundles into its folder, checked, unless it
/// is there already.
fn install(customize: &Customize, http: &Http, layer: &CodeLayer) -> Result<(), Failure> {
    if !layer.has_web() || customize.layer_ready(&layer.web) {
        return Ok(());
    }
    let base = base_url();
    let manifest_url = format!("{base}/{}/manifest.json", layer.web);
    let manifest = http
        .get_json(&manifest_url)?
        .ok_or_else(|| failure(format!("{manifest_url}: not published")))?;
    let archive = manifest.get("archive").and_then(Value::as_str).unwrap_or_default();
    let sha = manifest.get("sha256").and_then(Value::as_str).unwrap_or_default();
    if !archive.starts_with("web-bundles-") || !archive.ends_with(".tar.gz") || sha.len() != 64 {
        return Err(failure(format!("{manifest_url}: no archive and sha256")));
    }
    let url = format!("{base}/{}/{archive}", layer.web);
    let bytes = http.get(&url, MAX_ARCHIVE)?.ok_or_else(|| failure(format!("{url}: not found")))?;
    let got = hex(&Sha256::digest(&bytes));
    if got != sha {
        return Err(failure(format!("{url}: sha256 {got}, the manifest says {sha}")));
    }
    let dir = customize.layer_dir(&layer.web);
    unpack(&bytes, &dir, layer).map_err(|error| failure(format!("{url}: {error}")))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Unpacks the overlay surfaces of a published archive into `dir`, through a
/// sibling folder renamed into place, with manifest.json written last.
/// Refuses links, absolute paths and `..`.
pub(super) fn unpack(bytes: &[u8], dir: &Path, layer: &CodeLayer) -> std::io::Result<()> {
    let parent = dir.parent().ok_or_else(|| std::io::Error::other("no layers folder"))?;
    std::fs::create_dir_all(parent)?;
    let part = parent.join(format!(
        ".{}.part-{}",
        dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&part);
    let result = (|| {
        let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(bytes));
        let mut surfaces: Vec<&str> = Vec::new();
        for entry in archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?.into_owned();
            if path.is_absolute() || path.components().any(|c| !matches!(c, Component::Normal(_))) {
                return Err(std::io::Error::other(format!(
                    "{} is not a plain path",
                    path.display()
                )));
            }
            let kind = entry.header().entry_type();
            if !(kind.is_file() || kind.is_dir()) {
                return Err(std::io::Error::other(format!("{} is not a file", path.display())));
            }
            let text = path.to_string_lossy().replace('\\', "/");
            let Some((prefix, surface)) =
                SURFACES.iter().find(|(prefix, _)| text.starts_with(prefix))
            else {
                continue;
            };
            let Some(rest) = text.strip_prefix(prefix) else { continue };
            let target = part.join(surface).join(rest);
            if kind.is_dir() {
                std::fs::create_dir_all(&target)?;
                continue;
            }
            if let Some(dir) = target.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let mut out = Vec::new();
            entry.read_to_end(&mut out)?;
            std::fs::write(&target, out)?;
            if !surfaces.contains(surface) {
                surfaces.push(surface);
            }
        }
        if surfaces.is_empty() {
            return Err(std::io::Error::other("the archive holds no web bundles"));
        }
        // The app reads `abi` and `commit` (WebDevOverride.abiRefusal).
        let manifest = json!({
            "stamp": format!("pr-{}-{}", layer.pr, layer.head.get(..12).unwrap_or(&layer.head)),
            "commit": layer.head,
            "bundles": surfaces,
            "abi": layer.abi,
            "pr": layer.pr,
            "base": layer.base,
        });
        std::fs::write(part.join(code::LAYER_MANIFEST), format!("{manifest}\n"))?;
        let _ = std::fs::remove_dir_all(dir);
        std::fs::rename(&part, dir)
    })();
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&part);
    }
    result
}

/// Asks CI to publish PR `pr`'s layer on `commit`, when `gh` is here.
fn request_publish(pr: u64, commit: Option<&str>) -> Option<String> {
    let mut args = vec![
        "workflow".to_owned(),
        "run".to_owned(),
        "cmux-next-web-bundle-publish.yml".to_owned(),
        "-R".to_owned(),
        REPO.to_owned(),
        "--ref".to_owned(),
        "feat-cmux-next".to_owned(),
        "-f".to_owned(),
        format!("pr={pr}"),
    ];
    if let Some(commit) = commit {
        args.extend(["-f".to_owned(), format!("base={commit}")]);
    }
    let shown = format!("gh {}", args.join(" "));
    let ran = cmux_process::Command::new("gh")
        .args(&args)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    Some(if ran { format!("asked CI to publish it ({shown})") } else { format!("run `{shown}`") })
}

/// `cmux customize use pr:N`.
pub(super) fn use_pr(
    customize: &Customize,
    pr: u64,
    origin: &str,
    now_ms: u64,
) -> Result<Answer, Failure> {
    let mut app = App::find();
    let http = Http::new()?;
    app.full_commit(&http);
    let Some(pointer) = pointer(&http, pr, app.commit.as_deref())? else {
        let next = request_publish(pr, app.commit.as_deref()).unwrap_or_default();
        return Err(Failure {
            code: "customize.pr_unpublished".to_owned(),
            message: format!(
                "#{pr} has no published layer yet; {next}, then run `cmux customize use pr:{pr}` again in a few minutes"
            ),
            details: json!({ "pr": pr }),
            exit: 1,
        });
    };
    let layer = layer_of(&pointer, &app)?;
    let mut lines = Vec::new();
    if let Some(commit) = &app.commit
        && layer.has_web()
        && &layer.base != commit
    {
        lines.push(format!(
            "built on {}, not this app's {}: other web changes since may be missing; {}",
            short(&layer.base),
            short(commit),
            request_publish(pr, Some(commit)).unwrap_or_default()
        ));
    }
    install(customize, &http, &layer)?;
    let words = vec![format!("#{pr} {}", layer.title)];
    let change = customize.library_use_code(layer.clone(), words, origin, now_ms)?;
    let mut human = if layer.has_web() {
        format!(
            "pr-{pr} is on: #{pr} {} ({} on {}); open pages reload onto it now\n",
            layer.title,
            short(&layer.head),
            short(&layer.base)
        )
    } else {
        format!(
            "pr-{pr} is in your library, off: #{pr} {} has nothing a running cmux can take\n",
            layer.title
        )
    };
    for line in &layer.needs_build {
        human.push_str(&format!("  needs a build: {line}\n"));
    }
    for line in &lines {
        human.push_str(&format!("  {line}\n"));
    }
    if dev_server_wins(customize) {
        human.push_str("  web-dev.json names a dev server, and a server wins over a layer: `scripts/cmux-next/web-overlay.sh server off` stops it\n");
    }
    human.push_str(&format!("  cmux customize library off pr-{pr}   put back what was under it\n"));
    Ok(Answer::Library { json: json!({ "pr": pr, "layer": layer, "change": change }), human })
}

fn dev_server_wins(customize: &Customize) -> bool {
    std::fs::read(customize.roots().config_dir.join(code::WEB_DEV))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .is_some_and(|value| value.get("server").is_some_and(Value::is_string))
}

fn short(sha: &str) -> &str {
    sha.get(..12).unwrap_or(sha)
}

/// What GitHub says of a PR: merged, and its merge commit.
fn merged(http: &Http, repo: &str, pr: u64) -> Option<String> {
    let value =
        http.get_json(&format!("https://api.github.com/repos/{repo}/pulls/{pr}")).ok()??;
    value.get("merged").and_then(Value::as_bool).filter(|merged| *merged)?;
    value
        .get("merge_commit_sha")
        .and_then(Value::as_str)
        .filter(|sha| is_sha(sha))
        .map(str::to_owned)
}

/// Whether `commit` has `merge` in its history (GitHub compare).
fn contains(http: &Http, repo: &str, merge: &str, commit: &str) -> Option<bool> {
    let url = format!("https://api.github.com/repos/{repo}/compare/{merge}...{commit}");
    let value = http.get_json(&url).ok()??;
    Some(matches!(value.get("status").and_then(Value::as_str), Some("ahead" | "identical")))
}

/// `cmux customize library refresh`: every PR entry against what is
/// published and what this app is.
pub(super) fn refresh(customize: &Customize, origin: &str, now_ms: u64) -> Result<Answer, Failure> {
    let mut app = App::find();
    let http = Http::new()?;
    app.full_commit(&http);
    let listing = customize.library()?;
    let mut human = String::new();
    let mut results = Vec::new();
    for entry in listing.entries.iter().filter(|entry| entry.code.is_some()) {
        let Some(code) = entry.code.clone() else { continue };
        let name = entry.name.clone();
        let (note, on) = if let Some(merge) = merged(&http, &code.repo, code.pr) {
            match app
                .commit
                .as_deref()
                .and_then(|commit| contains(&http, &code.repo, &merge, commit))
            {
                Some(true) => ("merged: in your build".to_owned(), Some(false)),
                _ => ("merged: not in your build yet".to_owned(), None),
            }
        } else if let Some(pointer) = pointer(&http, code.pr, app.commit.as_deref())? {
            let layer = layer_of(&pointer, &app)?;
            if !layer.same(&code) || layer.base != code.base || layer.web != code.web {
                install(customize, &http, &layer)?;
                let was_on = entry.on;
                customize.library_use_code(layer.clone(), Vec::new(), origin, now_ms)?;
                if !was_on {
                    customize.library_settle_code(&name, "", Some(false), origin, now_ms)?;
                }
                (format!("now at {} on {}", short(&layer.head), short(&layer.base)), None)
            } else if code.has_web() && !layer.has_web() {
                (
                    format!(
                        "no longer applies: {}",
                        layer.needs_build.first().cloned().unwrap_or_default()
                    ),
                    Some(false),
                )
            } else {
                (String::new(), None)
            }
        } else {
            ("no published layer".to_owned(), None)
        };
        customize.library_settle_code(&name, &note, on, origin, now_ms)?;
        human.push_str(&format!(
            "{name}: {}\n",
            if note.is_empty() { "up to date" } else { note.as_str() }
        ));
        results.push(json!({ "name": name, "note": note, "turned_off": on == Some(false) }));
    }
    if results.is_empty() {
        human.push_str("no pull request entries; `cmux customize use pr:N` adds one\n");
    }
    Ok(Answer::Library { json: json!({ "refreshed": results }), human })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sources_that_name_a_pr() {
        for source in [
            "pr:43496",
            "#43496",
            "https://github.com/manaflow-ai/cmux/pull/43496",
            "https://github.com/manaflow-ai/cmux/pull/43496/files",
        ] {
            assert_eq!(pr_number(source), Some(43496), "{source}");
        }
        for source in
            ["night", "night.json", "pr-43496", "pr:", "#0", "https://github.com/other/repo/pull/1"]
        {
            assert_eq!(pr_number(source), None, "{source}");
        }
    }

    fn pointer_json(web: bool, abi: u64) -> Value {
        let mut files = json!({"no-app": ["docs/x.md"]});
        if web {
            files["web-live"] = json!(["webviews/src/a.ts"]);
        }
        files["rebuild"] = json!(["Packages/macOS/CmuxNext/Sources/X/Resources/icon.png"]);
        json!({
            "schema": 1, "repo": REPO, "pr": 7, "title": "cat",
            "head": "a".repeat(40), "base": "b".repeat(40), "merge": "c".repeat(40),
            "key": "d".repeat(64), "abi": abi,
            "classify": {"verdict": "rebuild", "files": files,
                         "reasons": {"resource or manifest": ["Packages/macOS/CmuxNext/Sources/X/Resources/icon.png"]}}
        })
    }

    #[test]
    fn a_pointer_becomes_a_layer_with_what_needs_a_build() {
        let app = App { path: None, commit: None, abi: Some(3) };
        let layer = layer_of(&pointer_json(true, 3), &app).unwrap();
        assert_eq!(layer.web, "d".repeat(64));
        assert_eq!(
            layer.needs_build,
            vec![
                "resource or manifest (Packages/macOS/CmuxNext/Sources/X/Resources/icon.png)"
                    .to_owned()
            ]
        );
        let none = layer_of(&pointer_json(false, 3), &app).unwrap();
        assert!(!none.has_web());
    }

    #[test]
    fn another_web_abi_keeps_the_web_part_out() {
        let app = App { path: None, commit: None, abi: Some(4) };
        let layer = layer_of(&pointer_json(true, 3), &app).unwrap();
        assert!(!layer.has_web());
        assert!(layer.needs_build[0].contains("web ABI 3; this app has 4"));
    }

    fn archive(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(
            Vec::new(),
            flate2::Compression::fast(),
        ));
        for (path, body) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(body.len() as u64);
            header.set_mode(0o644);
            header.set_entry_type(tar::EntryType::Regular);
            builder.append_data(&mut header, path, *body).unwrap();
        }
        builder.into_inner().unwrap().finish().unwrap()
    }

    #[test]
    fn unpack_places_the_surfaces_and_writes_the_manifest_last() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("layers").join("k");
        let layer = layer_of(&pointer_json(true, 3), &App::default()).unwrap();
        let bytes = archive(&[
            (
                "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/index.html",
                b"<p>pr</p>",
            ),
            (
                "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html",
                b"pane",
            ),
            ("Resources/markdown-viewer/webviews-app/index.html", b"app"),
            ("other/ignored.txt", b"x"),
        ]);
        unpack(&bytes, &dir, &layer).unwrap();
        assert_eq!(std::fs::read(dir.join("pages/settings/index.html")).unwrap(), b"<p>pr</p>");
        assert!(dir.join("agent-pane/index.html").is_file());
        assert!(dir.join("webviews-app/index.html").is_file());
        assert!(!dir.join("other").exists());
        let manifest: Value =
            serde_json::from_slice(&std::fs::read(dir.join("manifest.json")).unwrap()).unwrap();
        assert_eq!(manifest["abi"], json!(3));
        assert_eq!(manifest["commit"], json!("a".repeat(40)));
    }

    #[test]
    fn unpack_refuses_a_path_that_climbs_out() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("layers").join("k");
        let layer = layer_of(&pointer_json(true, 3), &App::default()).unwrap();
        // tar::Builder refuses `..` itself, so write the name by hand.
        let mut header = tar::Header::new_gnu();
        header.set_size(1);
        header.set_mode(0o644);
        header.set_entry_type(tar::EntryType::Regular);
        let name = b"Resources/markdown-viewer/webviews-app/../../../x";
        header.as_old_mut().name[..name.len()].copy_from_slice(name);
        header.set_cksum();
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(
            Vec::new(),
            flate2::Compression::fast(),
        ));
        builder.append(&header, &b"x"[..]).unwrap();
        let bytes = builder.into_inner().unwrap().finish().unwrap();
        assert!(unpack(&bytes, &dir, &layer).is_err());
        assert!(!dir.exists());
    }
}
