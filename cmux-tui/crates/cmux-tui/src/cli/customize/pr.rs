//! `cmux customize use pr:N | branch:NAME | sha:SHA | OWNER/REPO@REF`: code
//! someone published as a library entry (cmuxterm-hq
//! `docs/design/experiments-shelf.md`; `dir:PATH`, built here, is dir.rs).
//!
//! CI publishes the web layer of a PR, a branch or a commit of
//! manaflow-ai/cmux on dispatch (cmux-next-web-bundle-publish.yml with `pr=N`
//! or `ref=NAME`): its own change applied onto a base, built, and a pointer at
//! `files.cmux.com/cmux-next-web/pr/N/latest.json` or `.../ref/<slug>/...`
//! (and `<head>-<base>.json`) naming its web bundle key, the web ABI it needs
//! and what else it changes. A fork's code never builds on our CI: the fork's
//! own CI (cmux-web-layer-fork.yml, run in the fork) publishes the same
//! pointer and archive as a release of the fork, and `use OWNER/REPO@REF`
//! reads it there, with the same sha256, ABI and commit checks.
//!
//! `use` reads the pointer for this app's own commit first, fetches and checks
//! the bundles into a layer folder, and puts the code on top of the library,
//! on. `library off NAME` puts back what was under it. `library refresh`
//! follows each entry: a newer head (a PR's push, a branch's tip) is fetched,
//! code that is in this app's build turns the entry off, a web ABI the app no
//! longer has turns it off and says so. A fork's newer layer is only named:
//! fork code changes in someone's cmux when they run `use` again.
//!
//! What the code changes that a running app cannot take (Swift, resources,
//! Rust the app links) is listed on the entry as "needs a build".

use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use cmux_customize::library::{CodeKind, CodeLayer, code};
use cmux_customize::{Customize, Error};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::Failure;
use super::render::Answer;
use super::source::{Source, ref_slug};

const DEFAULT_BASE: &str = "https://files.cmux.com/cmux-next-web";
pub(super) const REPO: &str = "manaflow-ai/cmux";
/// A fork's layer is a release of the fork with this tag prefix
/// (cmux-web-layer-fork.yml).
const FORK_TAG: &str = "cmux-web-layer-";
/// The largest web bundle archive a layer fetches (they are about 30 MB).
const MAX_ARCHIVE: u64 = 256 * 1024 * 1024;
/// Where each overlay surface sits in a published archive.
pub(super) const SURFACES: [(&str, &str); 3] = [
    ("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/", "agent-pane"),
    ("Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/", "pages"),
    ("Resources/markdown-viewer/webviews-app/", "webviews-app"),
];
pub(super) const APP_ABI: &str =
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
        let abi = web_abi_of(&path);
        App { path: Some(path), commit, abi }
    }
}

/// The web ABI app `bundle`'s own pages need (pages/web-abi.json).
pub(super) fn web_abi_of(bundle: &Path) -> Option<u32> {
    std::fs::read(bundle.join(APP_ABI))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value.get("abi").and_then(Value::as_u64))
        .map(|abi| abi as u32)
}

impl App {
    /// The app's commit in full: a short one is resolved on GitHub.
    pub(super) fn full_commit(&mut self, http: &Http) {
        let Some(commit) = self.commit.clone().filter(|commit| !is_sha(commit)) else { return };
        self.commit = full_sha(http, &commit).ok().flatten();
    }
}

/// A commit of manaflow-ai/cmux in full, from 7 or more hex: `Ok(None)` when
/// GitHub says there is no such commit, `Err` when it could not be asked. The
/// anonymous API allows 60 calls an hour per IP, which a shared office or
/// fleet address runs out of, so a refusal is asked again through `gh`
/// (signed in) when it is installed.
fn full_sha(http: &Http, commit: &str) -> Result<Option<String>, String> {
    let url = format!("https://api.github.com/repos/{REPO}/commits/{commit}");
    let found = match http.get_json(&url) {
        Ok(answer) => {
            answer.and_then(|value| value.get("sha").and_then(Value::as_str).map(str::to_owned))
        }
        // GitHub's answer for hex that names no commit.
        Err(error) if error.message.contains("HTTP 422") => None,
        Err(error) => match gh_sha(commit) {
            Some(sha) => Some(sha),
            None => return Err(error.message),
        },
    };
    Ok(found.filter(|sha| is_sha(sha) && sha.starts_with(commit)))
}

/// `full_sha`'s question through `gh api`, signed in.
fn gh_sha(commit: &str) -> Option<String> {
    let output = cmux_process::Command::new("gh")
        .args(["api", &format!("repos/{REPO}/commits/{commit}"), "--jq", ".sha"])
        .stdin(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    Some(String::from_utf8_lossy(&output.stdout).trim().to_owned()).filter(|sha| is_sha(sha))
}

fn is_hex_commit(text: &str) -> bool {
    (7..=40).contains(&text.len())
        && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub(super) fn is_sha(text: &str) -> bool {
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

pub(super) fn failure(why: String) -> Failure {
    Failure::from(Error::Library(why))
}

/// GETs, one current-thread runtime per verb.
pub(super) struct Http {
    runtime: tokio::runtime::Runtime,
    client: reqwest::Client,
}

impl Http {
    pub(super) fn new() -> Result<Http, Failure> {
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

    pub(super) fn get_json(&self, url: &str) -> Result<Option<Value>, Failure> {
        match self.get(url, 4 * 1024 * 1024)? {
            None => Ok(None),
            Some(bytes) => serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|_| failure(format!("{url}: not JSON"))),
        }
    }
}

/// A source someone published: what `use` fetches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Published {
    Pr(u64),
    /// A branch or a full commit of manaflow-ai/cmux.
    Ref {
        kind: CodeKind,
        name: String,
    },
    Fork {
        repo: String,
        reference: String,
    },
}

impl Published {
    /// The published source of a code entry; `None` for a folder.
    pub(super) fn of(code: &CodeLayer) -> Option<Published> {
        match code.kind {
            CodeKind::Pr => Some(Published::Pr(code.pr)),
            CodeKind::Branch | CodeKind::Sha => {
                Some(Published::Ref { kind: code.kind, name: code.source.clone() })
            }
            CodeKind::Fork => {
                let (repo, reference) = code.source.split_once('@')?;
                Some(Published::Fork { repo: repo.to_owned(), reference: reference.to_owned() })
            }
            CodeKind::Dir => None,
        }
    }

    /// What `use` takes to name it again.
    fn source_text(&self) -> String {
        match self {
            Published::Pr(pr) => format!("pr:{pr}"),
            Published::Ref { kind: CodeKind::Sha, name } => format!("sha:{name}"),
            Published::Ref { name, .. } => format!("branch:{name}"),
            Published::Fork { repo, reference } => format!("{repo}@{reference}"),
        }
    }

    /// Where our CI writes its pointers, under the web bundle base.
    fn ours(&self) -> Option<String> {
        match self {
            Published::Pr(pr) => Some(format!("pr/{pr}")),
            Published::Ref { name, .. } => Some(format!("ref/{}", ref_slug(name))),
            Published::Fork { .. } => None,
        }
    }

    /// A fork's release download folder.
    fn fork_release(&self) -> Option<String> {
        match self {
            Published::Fork { repo, reference } => Some(format!(
                "https://github.com/{repo}/releases/download/{FORK_TAG}{}",
                ref_slug(reference)
            )),
            _ => None,
        }
    }
}

/// The published pointer for `source`: the one built on `commit` when there
/// is one, else the newest.
fn pointer(
    http: &Http,
    source: &Published,
    commit: Option<&str>,
) -> Result<Option<Value>, Failure> {
    if let Some(release) = source.fork_release() {
        return http.get_json(&format!("{release}/layer.json"));
    }
    let base = base_url();
    let prefix = source.ours().unwrap_or_default();
    let latest = http.get_json(&format!("{base}/{prefix}/latest.json"))?;
    if let (Some(latest), Some(commit)) = (&latest, commit)
        && latest.get("base").and_then(Value::as_str) != Some(commit)
        && let Some(head) = latest.get("head").and_then(Value::as_str).filter(|head| is_sha(head))
        && let Some(exact) = http.get_json(&format!("{base}/{prefix}/{head}-{commit}.json"))?
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

/// The layer a pointer describes, for an app with `app`. A PR pointer names
/// its `pr`; a branch or commit pointer its `kind` and `ref`; a fork's pointer
/// is read as `source` says, whatever it claims.
#[cfg(test)]
pub(super) fn layer_of(pointer: &Value, app: &App) -> Result<CodeLayer, Failure> {
    layer_from(pointer, app, None)
}

fn layer_from(
    pointer: &Value,
    app: &App,
    source: Option<&Published>,
) -> Result<CodeLayer, Failure> {
    let field =
        |name: &str| pointer.get(name).and_then(Value::as_str).unwrap_or_default().to_owned();
    let (kind, pr, source, repo) = match source {
        Some(Published::Fork { repo, reference }) => {
            (CodeKind::Fork, 0, format!("{repo}@{reference}"), repo.clone())
        }
        _ => match pointer.get("pr").and_then(Value::as_u64) {
            Some(pr) => (CodeKind::Pr, pr, String::new(), REPO.to_owned()),
            None => {
                let kind = match field("kind").as_str() {
                    "branch" => CodeKind::Branch,
                    "sha" => CodeKind::Sha,
                    _ => {
                        return Err(failure(
                            "the pointer names no pr and no branch or commit".into(),
                        ));
                    }
                };
                let name = field("ref");
                if !super::source::valid_ref(&name) {
                    return Err(failure("the pointer names no ref".into()));
                }
                (kind, 0, name, REPO.to_owned())
            }
        },
    };
    let head = field("head");
    if !is_sha(&head) {
        return Err(failure("the pointer names no head".into()));
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
        kind,
        source,
        repo,
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
/// is there already. A fork's archive is its release's, named by its sha256.
fn install(customize: &Customize, http: &Http, layer: &CodeLayer) -> Result<(), Failure> {
    if !layer.has_web() || customize.layer_ready(&layer.web) {
        return Ok(());
    }
    if let Some(release) = Published::of(layer).and_then(|source| source.fork_release()) {
        let url = format!("{release}/web-bundles.tar.gz");
        let bytes =
            http.get(&url, MAX_ARCHIVE)?.ok_or_else(|| failure(format!("{url}: not found")))?;
        let got = hex(&Sha256::digest(&bytes));
        if got != layer.web {
            return Err(failure(format!(
                "{url}: sha256 {got}, the fork's layer.json says {}",
                layer.web
            )));
        }
        let dir = customize.layer_dir(&layer.web);
        return unpack(&bytes, &dir, layer).map_err(|error| failure(format!("{url}: {error}")));
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

pub(super) fn hex(bytes: &[u8]) -> String {
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
        write_manifest(&part, layer, &surfaces)?;
        let _ = std::fs::remove_dir_all(dir);
        std::fs::rename(&part, dir)
    })();
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&part);
    }
    result
}

/// The layer folder's manifest.json, written last: the app reads `abi` and
/// `commit` (WebDevOverride.abiRefusal).
pub(super) fn write_manifest(
    part: &Path,
    layer: &CodeLayer,
    surfaces: &[&str],
) -> std::io::Result<()> {
    let manifest = json!({
        "stamp": format!("{}-{}", layer.name(), layer.head.get(..12).unwrap_or(&layer.head)),
        "commit": layer.head,
        "bundles": surfaces,
        "abi": layer.abi,
        "kind": layer.kind,
        "source": layer.source_label(),
        "base": layer.base,
    });
    std::fs::write(part.join(code::LAYER_MANIFEST), format!("{manifest}\n"))
}

/// Asks our CI to publish `source`'s layer on `commit`, when `gh` is here; a
/// fork's is the fork's to publish, so it says how.
fn request_publish(source: &Published, commit: Option<&str>) -> Option<String> {
    let field = match source {
        Published::Pr(pr) => format!("pr={pr}"),
        Published::Ref { name, .. } => format!("ref={name}"),
        Published::Fork { repo, reference } => {
            let base = commit.map(|commit| format!(" -f base={commit}")).unwrap_or_default();
            return Some(format!(
                "the fork publishes its own layer (our CI never builds fork code): in {repo}, run `gh workflow run cmux-web-layer-fork.yml -R {repo} --ref {reference}{base}`, or use `dir:` on a clone of it"
            ));
        }
    };
    let mut args = vec![
        "workflow".to_owned(),
        "run".to_owned(),
        "cmux-next-web-bundle-publish.yml".to_owned(),
        "-R".to_owned(),
        REPO.to_owned(),
        "--ref".to_owned(),
        "feat-cmux-next".to_owned(),
        "-f".to_owned(),
        field,
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

/// `cmux customize use SOURCE` for every source but a folder.
pub(super) fn use_code(
    customize: &Customize,
    source: Source,
    origin: &str,
    now_ms: u64,
) -> Result<Answer, Failure> {
    let mut app = App::find();
    let http = Http::new()?;
    app.full_commit(&http);
    let published = match source {
        Source::Pr(pr) => Published::Pr(pr),
        Source::Branch(name) => Published::Ref { kind: CodeKind::Branch, name },
        Source::Sha(sha) => {
            let full = if is_sha(&sha) { Ok(Some(sha.clone())) } else { full_sha(&http, &sha) };
            let name = match full {
                Ok(Some(name)) => name,
                Ok(None) => {
                    return Err(failure(format!(
                        "{sha} is no commit of {REPO} (a fork's commit: use OWNER/REPO@BRANCH)"
                    )));
                }
                Err(why) => {
                    return Err(failure(format!(
                        "could not look {sha} up on GitHub ({why}); give the whole commit: cmux customize use sha:<40 hex>"
                    )));
                }
            };
            Published::Ref { kind: CodeKind::Sha, name }
        }
        Source::Fork { repo, reference } => Published::Fork { repo, reference },
        Source::Dir(path) => return super::dir::use_dir(customize, &path, false, origin, now_ms),
    };
    let shown = published.source_text();
    let Some(pointer) = pointer(&http, &published, app.commit.as_deref())? else {
        let next = request_publish(&published, app.commit.as_deref()).unwrap_or_default();
        return Err(Failure {
            code: "customize.code_unpublished".to_owned(),
            message: format!(
                "{shown} has no published layer yet; {next}, then run `cmux customize use {shown}` again in a few minutes"
            ),
            details: json!({ "source": shown }),
            exit: 1,
        });
    };
    let layer = layer_from(
        &pointer,
        &app,
        Some(&published).filter(|p| matches!(p, Published::Fork { .. })),
    )?;
    let mut lines = Vec::new();
    if matches!(published, Published::Fork { .. }) {
        lines.push(format!(
            "a fork layer runs {}'s code in your cmux: its pages see what cmux pages see",
            layer.source
        ));
    }
    if let Published::Ref { kind: CodeKind::Branch, name } = &published
        && let Some(tip) = branch_tip(&http, name)
        && tip != layer.head
    {
        lines.push(format!(
            "the branch is at {} now, this layer is {}; {}",
            short(&tip),
            short(&layer.head),
            request_publish(&published, app.commit.as_deref()).unwrap_or_default()
        ));
    }
    if let Some(commit) = &app.commit
        && layer.has_web()
        && &layer.base != commit
    {
        lines.push(format!(
            "built on {}, not this app's {}: other web changes since may be missing; {}",
            short(&layer.base),
            short(commit),
            request_publish(&published, Some(commit)).unwrap_or_default()
        ));
    }
    install(customize, &http, &layer)?;
    let answer = put_on(customize, layer, lines, origin, now_ms)?;
    Ok(answer)
}

/// Puts `layer` on top of the library and says what happened.
pub(super) fn put_on(
    customize: &Customize,
    layer: CodeLayer,
    lines: Vec<String>,
    origin: &str,
    now_ms: u64,
) -> Result<Answer, Failure> {
    let name = layer.name();
    let label = layer.label();
    let words = vec![label.clone()];
    let change = customize.library_use_code(layer.clone(), words, origin, now_ms)?;
    let mut human = if layer.has_web() {
        let at = if layer.base.is_empty() || layer.base == layer.head {
            format!("at {}", short(&layer.head))
        } else {
            format!("{} on {}", short(&layer.head), short(&layer.base))
        };
        format!("{name} is on: {label} ({at}); open pages reload onto it now\n")
    } else {
        format!("{name} is in your library, off: {label} has nothing a running cmux can take\n")
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
    human.push_str(&format!("  cmux customize library off {name}   put back what was under it\n"));
    human.push_str(
        "  cmux customize library reset       if cmux breaks: every layer off, no app needed\n",
    );
    Ok(Answer::Library { json: json!({ "name": name, "layer": layer, "change": change }), human })
}

fn dev_server_wins(customize: &Customize) -> bool {
    std::fs::read(customize.roots().config_dir.join(code::WEB_DEV))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .is_some_and(|value| value.get("server").is_some_and(Value::is_string))
}

pub(super) fn short(sha: &str) -> &str {
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

/// A branch of manaflow-ai/cmux's tip, `None` when it is gone or GitHub does
/// not answer.
fn branch_tip(http: &Http, name: &str) -> Option<String> {
    let url = format!("https://api.github.com/repos/{REPO}/branches/{name}");
    let value = http.get_json(&url).ok()??;
    value
        .pointer("/commit/sha")
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

/// What refresh says instead of installing a fork's newer layer. Someone who
/// ran `use OWNER/REPO@REF` agreed to the code they got then; the fork's owner
/// can publish anything later (its layer.json and archive are the fork's own),
/// so new fork code goes in only when the person runs `use` again. Our own
/// PRs, branches and commits come from people with write access here and
/// follow their head.
fn fork_update_waits(published: &Published, layer: &CodeLayer) -> Option<String> {
    let Published::Fork { .. } = published else { return None };
    Some(format!(
        "the fork published {} (on {}); fork code changes only when you take it: `cmux customize use {}`",
        short(&layer.head),
        short(&layer.base),
        published.source_text()
    ))
}

/// `cmux customize library refresh`: every code entry against what is
/// published (a folder: built again) and what this app is.
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
        let Some(published) = Published::of(&code) else {
            let note = super::dir::refresh_entry(customize, &code, origin, now_ms)?;
            human.push_str(&format!("{name}: {note}\n"));
            results.push(json!({ "name": name, "note": note, "turned_off": false }));
            continue;
        };
        let merge = match &published {
            Published::Pr(pr) => merged(&http, &code.repo, *pr),
            // A branch or a commit is in the build once the build has its head.
            Published::Ref { kind, name } => {
                let head = if *kind == CodeKind::Branch {
                    branch_tip(&http, name).unwrap_or_else(|| code.head.clone())
                } else {
                    code.head.clone()
                };
                Some(head)
            }
            Published::Fork { .. } => None,
        };
        let in_build = match (&merge, app.commit.as_deref()) {
            (Some(merge), Some(commit)) => contains(&http, &code.repo, merge, commit),
            _ => None,
        };
        let (note, on) = if code.kind == CodeKind::Pr && merge.is_some() {
            match in_build {
                Some(true) => ("merged: in your build".to_owned(), Some(false)),
                _ => ("merged: not in your build yet".to_owned(), None),
            }
        } else if code.kind != CodeKind::Pr && in_build == Some(true) {
            ("in your build".to_owned(), Some(false))
        } else if let Some(pointer) = pointer(&http, &published, app.commit.as_deref())? {
            let fork = Some(&published).filter(|p| matches!(p, Published::Fork { .. }));
            let layer = layer_from(&pointer, &app, fork)?;
            let tip = match &published {
                Published::Ref { kind: CodeKind::Branch, name } => branch_tip(&http, name),
                _ => None,
            };
            let changed = !layer.same(&code) || layer.base != code.base || layer.web != code.web;
            if let Some(tip) = tip.filter(|tip| *tip != layer.head) {
                let asked = request_publish(&published, app.commit.as_deref()).unwrap_or_default();
                (format!("the branch is at {}; {asked}", short(&tip)), None)
            } else if changed && let Some(waits) = fork_update_waits(&published, &layer) {
                (waits, None)
            } else if changed {
                install(customize, &http, &layer)?;
                customize.library_update_code(layer.clone(), origin, now_ms)?;
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
        human.push_str("no code entries; `cmux customize use pr:N|branch:NAME|sha:SHA|dir:PATH|OWNER/REPO@REF` adds one\n");
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
    fn refresh_takes_a_new_fork_layer_only_through_use() {
        let app = App { path: None, commit: None, abi: Some(3) };
        let fork = Published::Fork { repo: "someone/cmux".into(), reference: "theme".into() };
        let layer = layer_from(&pointer_json(true, 3), &app, Some(&fork)).unwrap();
        let note = fork_update_waits(&fork, &layer).unwrap();
        assert!(note.contains("cmux customize use someone/cmux@theme"), "{note}");
        assert!(note.contains(short(&layer.head)), "{note}");
        for ours in [
            Published::Pr(7),
            Published::Ref { kind: CodeKind::Branch, name: "feat-x".into() },
            Published::Ref { kind: CodeKind::Sha, name: "a".repeat(40) },
        ] {
            assert_eq!(fork_update_waits(&ours, &layer), None, "{ours:?}");
        }
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
