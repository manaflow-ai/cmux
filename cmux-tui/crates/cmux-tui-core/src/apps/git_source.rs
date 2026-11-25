//! Apps installed straight from a git repository (docs/app-store-usage.md,
//! "Install from a git repo").
//!
//! A reference names a repository, optionally a directory in it and a ref:
//! `[https://]HOST/OWNER/REPO[/PATH][@REF]` (also GitHub's and Codeberg's
//! `/tree/REF/PATH` page URLs and `https://HOST/OWNER/REPO.git`). An install
//! always pins a 40-hex commit: the ref resolves through the repository's
//! smart-HTTP ref list (`info/refs`, the one form every git host serves, with
//! no API rate limit), the tree at that commit comes from the host's archive
//! endpoint (GitHub, GitLab, Codeberg) or a shallow `git fetch` elsewhere,
//! and extracts with path and size limits into
//! `<state>/apps/git/HOST/OWNER/REPO/<commit>[+PATH]/`. The package passes
//! the one manifest v2 validator, its id must start with the repository
//! owner (`OWNER/...`), its `engines.cmux` must admit this cmux, and it is
//! always unverified. `<state>/apps/git/sources.json` records each installed
//! app's {repository, ref, commit, tag, version, sha256}; the catalog loads
//! from it, so installs survive a restart. The SHA-256 of the extracted tree
//! is recorded per commit and checked on every later fetch of that commit.

use std::collections::BTreeMap;
use std::io::Read as _;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest as _, Sha256};

use super::catalog::{self, Catalog, DirKind, Package, Sources};

/// The app platform version `engines.cmux` ranges with major 2 or more are
/// checked against (every v2 manifest says `^2.0`).
pub const PLATFORM_API: (u64, u64, u64) = (2, 0, 0);
/// The most a ref list (`info/refs`) may be.
pub const MAX_REFS: u64 = 16 << 20;
/// The most a downloaded archive may be.
pub const MAX_ARCHIVE: u64 = 64 << 20;
/// The most the decompressed archive stream may be (every entry, kept or not).
const MAX_STREAM: u64 = 256 << 20;
/// The most the extracted package may be, in total and per file.
pub const MAX_TOTAL: u64 = 64 << 20;
const MAX_FILE: u64 = 32 << 20;
/// The most entries an archive may have.
const MAX_ENTRIES: usize = 20_000;
/// The index of installed git apps in the git directory.
pub const INDEX: &str = "sources.json";

/// Publishers a repository may not claim unless it is manaflow-ai's.
/// The one host whose `manaflow-ai` owner is ours.
const TRUSTED_HOST: &str = "github.com";
const FIRST_PARTY: &[&str] = &["cmux", "manaflow-ai"];

/// A parsed reference.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoRef {
    pub host: String,
    pub owner: String,
    pub repo: String,
    /// The package directory in the repository, `""` at its root.
    pub path: String,
    /// The branch, tag or commit; `None` is the default branch.
    pub git_ref: Option<String>,
}

fn name_ok(segment: &str) -> bool {
    !segment.is_empty()
        && segment.len() <= 100
        && !segment.starts_with(['.', '-'])
        && segment.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

fn ref_ok(git_ref: &str) -> bool {
    !git_ref.is_empty()
        && git_ref.len() <= 200
        && !git_ref.starts_with(['-', '/', '.'])
        && !git_ref.ends_with(['/', '.'])
        && !git_ref.contains("..")
        && !git_ref.contains("//")
        && git_ref.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/'))
}

fn host_ok(host: &str) -> bool {
    host.contains('.')
        && host.len() <= 253
        && host.parse::<std::net::IpAddr>().is_err()
        && !host.ends_with(".local")
        && !host.ends_with(".localhost")
        && host.split('.').all(|label| {
            !label.is_empty()
                && !label.starts_with('-')
                && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        })
}

/// Whether `text` is 40 hex digits.
pub fn is_commit(text: &str) -> bool {
    text.len() == 40 && text.chars().all(|c| c.is_ascii_hexdigit())
}

impl RepoRef {
    /// Whether an App Store `app` argument is a reference rather than an app
    /// id (`publisher/name`): a URL, or a first segment that is a host name.
    pub fn looks_like(app: &str) -> bool {
        let app = app.trim();
        app.starts_with("https://")
            || app.starts_with("http://")
            || app.split('/').next().is_some_and(|first| first.contains('.'))
                && app.split('/').count() >= 3
    }

    pub fn parse(input: &str) -> Result<Self, String> {
        let text = input.trim();
        let bad = |why: &str| Err(format!("{text}: {why}"));
        if text.is_empty()
            || text.len() > 512
            || text.chars().any(|c| c.is_whitespace() || c.is_control())
        {
            return bad("not a repository reference (HOST/OWNER/REPO[/PATH][@REF])");
        }
        let rest = if let Some(rest) = text.strip_prefix("https://") {
            rest
        } else if text.starts_with("http://") {
            return bad("only https repositories install");
        } else if text.contains("://") || text.starts_with("git@") {
            return bad("only https repositories install (HOST/OWNER/REPO)");
        } else {
            text
        };
        let (location, mut git_ref) = match rest.split_once('@') {
            Some((location, git_ref)) => (location, Some(git_ref.to_string())),
            None => (rest, None),
        };
        let location = location.trim_end_matches('/');
        let segments: Vec<&str> = location.split('/').collect();
        let [host, owner, repo, rest @ ..] = segments.as_slice() else {
            return bad("name the repository as HOST/OWNER/REPO");
        };
        let host = host.to_ascii_lowercase();
        if !host_ok(&host) {
            return bad("the host is not a public host name");
        }
        let owner = owner.to_string();
        let repo = repo.trim_end_matches(".git").to_string();
        if !name_ok(&owner) || !name_ok(&repo) {
            return bad("the owner or repository name has characters a repository cannot have");
        }
        // A repository page URL: `/tree/REF/PATH` (GitHub, Codeberg's `/src/branch/REF`
        // is not taken), GitLab's `/-/tree/REF/PATH`.
        let path: &[&str] = match rest {
            ["tree", tree_ref, path @ ..] | ["-", "tree", tree_ref, path @ ..] => {
                if git_ref.is_some() {
                    return bad("name the ref once: either /tree/REF or @REF");
                }
                git_ref = Some(tree_ref.to_string());
                path
            }
            path => path,
        };
        if path.iter().any(|segment| !name_ok(segment)) {
            return bad("the package path has an empty, hidden or unusual directory name");
        }
        if let Some(git_ref) = &git_ref
            && !ref_ok(git_ref)
        {
            return bad("the ref has characters a branch or tag cannot have");
        }
        Ok(Self { host, owner, repo, path: path.join("/"), git_ref })
    }

    /// `HOST/OWNER/REPO[/PATH]`, without the ref.
    pub fn canonical(&self) -> String {
        let mut out = format!("{}/{}/{}", self.host, self.owner, self.repo);
        if !self.path.is_empty() {
            out.push('/');
            out.push_str(&self.path);
        }
        out
    }

    /// `HOST/OWNER/REPO[/PATH][@REF]`.
    pub fn reference(&self) -> String {
        match &self.git_ref {
            Some(git_ref) => format!("{}@{git_ref}", self.canonical()),
            None => self.canonical(),
        }
    }

    /// The repository's page, `https://HOST/OWNER/REPO`.
    pub fn repository_url(&self) -> String {
        format!("https://{}/{}/{}", self.host, self.owner, self.repo)
    }

    /// The clone URL, `https://HOST/OWNER/REPO.git`.
    pub fn clone_url(&self) -> String {
        format!("{}.git", self.repository_url())
    }

    /// The tarball of `commit` from the host's archive endpoint; `None` for
    /// a host without one (fetched with `git`).
    pub fn archive_url(&self, commit: &str) -> Option<String> {
        let (owner, repo) = (&self.owner, &self.repo);
        match self.host.as_str() {
            "github.com" => {
                Some(format!("https://codeload.github.com/{owner}/{repo}/tar.gz/{commit}"))
            }
            "gitlab.com" => Some(format!(
                "https://gitlab.com/{owner}/{repo}/-/archive/{commit}/{repo}-{commit}.tar.gz"
            )),
            "codeberg.org" => {
                Some(format!("https://codeberg.org/{owner}/{repo}/archive/{commit}.tar.gz"))
            }
            _ => None,
        }
    }

    /// The package directory of `commit` under the git directory.
    /// `release`: the release's built package, not the source tree.
    pub fn package_dir(&self, commit: &str, release: bool) -> String {
        let mut leaf = commit.to_string();
        if !self.path.is_empty() {
            leaf = format!("{leaf}+{}", self.path.replace('/', "+"));
        }
        if release {
            leaf.push_str("+release");
        }
        format!("{}/{}/{}/{leaf}", self.host, self.owner, self.repo)
    }

    /// The digest key of this package at `commit`.
    pub fn digest_key(&self, commit: &str, release: bool) -> String {
        let kind = if release { "#release" } else { "" };
        format!("{}@{commit}{kind}", self.canonical())
    }
}

/// Network access for git installs; tests use a local fixture.
pub trait GitTransport: Send + Sync {
    /// GETs `url`: the status and at most `limit` bytes of body (an error
    /// beyond it).
    fn get(&self, url: &str, accept: &str, limit: u64) -> Result<(u16, Vec<u8>), String>;
    /// The tree of `commit` in the repository at `clone_url` as a tar, for a
    /// host without an archive endpoint.
    fn git_archive(&self, clone_url: &str, commit: &str, limit: u64) -> Result<Vec<u8>, String> {
        if !is_commit(commit) || !clone_url.starts_with("https://") {
            return Err("git fetches only an https repository at a commit".into());
        }
        let work = std::env::temp_dir().join(format!(
            "cmux-git-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let dir = work.to_string_lossy().into_owned();
        let tar_path = work.join("tree.tar");
        let tar_arg = format!("--output={}", tar_path.to_string_lossy());
        let deadline = std::time::Instant::now() + GIT_FETCH_TIMEOUT;
        let result = (|| {
            run_git(&["init", "-q", "--bare", dir.as_str()], &work, limit, deadline)?;
            run_git(
                &[
                    "-C",
                    dir.as_str(),
                    "fetch",
                    "-q",
                    "--depth",
                    "1",
                    "--no-tags",
                    "--",
                    clone_url,
                    commit,
                ],
                &work,
                limit,
                deadline,
            )?;
            run_git(
                &[
                    "-C",
                    dir.as_str(),
                    "archive",
                    "--format=tar",
                    "--prefix=tree/",
                    tar_arg.as_str(),
                    commit,
                ],
                &work,
                limit,
                deadline,
            )?;
            let tar = std::fs::read(&tar_path).map_err(|_| GIT_DOWNLOAD_FAILED.to_string())?;
            if tar.len() as u64 > limit {
                return Err(format!("the tree is larger than {} MiB", limit >> 20));
            }
            Ok(tar)
        })();
        let _ = std::fs::remove_dir_all(&work);
        result
    }

    fn post_json(&self, url: &str, body: &Value) -> Result<(), String>;
}

/// A successful GET's body.
fn get_ok(transport: &dyn GitTransport, url: &str, limit: u64) -> Result<Vec<u8>, String> {
    match transport.get(url, "*/*", limit)? {
        (200..=299, body) => Ok(body),
        (404, _) => Err(format!("{url}: not found (is the repository public?)")),
        (status, _) => Err(format!("{url}: HTTP {status}")),
    }
}

/// The refs a repository advertises.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Refs {
    /// `HEAD`'s commit.
    pub head: Option<String>,
    /// Ref name to the commit it names (annotated tags peeled).
    pub commits: BTreeMap<String, String>,
    /// Annotated tags: tag name to the tag object's id.
    pub tag_objects: BTreeMap<String, String>,
}

impl Refs {
    /// Parses a smart-HTTP (`# service=git-upload-pack` pkt-lines) or dumb
    /// (`<sha>\t<ref>` lines) ref list.
    pub fn parse(body: &[u8]) -> Result<Self, String> {
        let mut raw: Vec<(String, String)> = Vec::new();
        // A dumb ref list is `<40 hex>\t<ref>` lines; a smart one starts with a pkt-line length.
        let smart = body.get(..4).is_some_and(|head| head.iter().all(u8::is_ascii_hexdigit))
            && body.get(40) != Some(&b'\t');
        if smart {
            let mut rest = body;
            while let Some((head, after)) = rest.split_at_checked(4) {
                let len = std::str::from_utf8(head)
                    .ok()
                    .and_then(|hex| usize::from_str_radix(hex, 16).ok())
                    .ok_or("the ref list is not a git ref list")?;
                if len == 0 {
                    rest = after;
                    continue;
                }
                let Some((payload, next)) =
                    len.checked_sub(4).and_then(|len| after.split_at_checked(len))
                else {
                    return Err("the ref list is cut short".into());
                };
                rest = next;
                let line = String::from_utf8_lossy(payload);
                let line = line.split('\0').next().unwrap_or_default().trim_end();
                if line.starts_with('#') {
                    continue;
                }
                if let Some((sha, name)) = line.split_once(' ') {
                    raw.push((sha.to_string(), name.to_string()));
                }
            }
        } else {
            for line in String::from_utf8_lossy(body).lines() {
                if let Some((sha, name)) = line.split_once('\t') {
                    raw.push((sha.to_string(), name.trim().to_string()));
                }
            }
        }
        let mut refs = Refs::default();
        for (sha, name) in &raw {
            if !is_commit(sha) {
                continue;
            }
            let sha = sha.to_ascii_lowercase();
            if name == "HEAD" {
                refs.head = Some(sha);
            } else if let Some(tag) = name.strip_suffix("^{}") {
                if let Some(object) = refs.commits.insert(tag.to_string(), sha) {
                    refs.tag_objects.insert(tag.to_string(), object);
                }
            } else {
                refs.commits.entry(name.clone()).or_insert(sha);
            }
        }
        Ok(refs)
    }

    /// The commit `git_ref` names (tags first, as git does), and the tag
    /// when it is one; `None` is the default branch.
    pub fn resolve(&self, git_ref: Option<&str>) -> Result<(String, Option<String>), String> {
        let Some(git_ref) = git_ref else {
            let head = self.head.clone().ok_or("the repository has no default branch")?;
            return Ok((head, None));
        };
        if is_commit(git_ref) {
            return Ok((git_ref.to_ascii_lowercase(), None));
        }
        if let Some(commit) = self.commits.get(&format!("refs/tags/{git_ref}")) {
            return Ok((commit.clone(), Some(git_ref.to_string())));
        }
        if let Some(commit) = self.commits.get(&format!("refs/heads/{git_ref}")) {
            return Ok((commit.clone(), None));
        }
        if let Some(commit) = self.commits.get(git_ref).filter(|_| git_ref.starts_with("refs/")) {
            let tag = git_ref.strip_prefix("refs/tags/").map(str::to_string);
            return Ok((commit.clone(), tag));
        }
        Err(format!("the repository has no branch or tag named {git_ref}"))
    }

    /// A tag at `commit`: `v<version>`, else `<version>`, else the first.
    pub fn tag_at(&self, commit: &str, version: &str) -> Option<String> {
        let tags: Vec<&str> = self
            .commits
            .iter()
            .filter(|(_, sha)| *sha == commit)
            .filter_map(|(name, _)| name.strip_prefix("refs/tags/"))
            .collect();
        [format!("v{version}"), version.to_string()]
            .into_iter()
            .find(|want| tags.contains(&want.as_str()))
            .or_else(|| tags.first().map(|tag| tag.to_string()))
    }
}

/// The repository's refs.
pub fn list_refs(transport: &dyn GitTransport, reference: &RepoRef) -> Result<Refs, String> {
    let url = format!("{}/info/refs?service=git-upload-pack", reference.clone_url());
    let body = get_ok(transport, &url, MAX_REFS)?;
    let mut refs = Refs::parse(&body)?;
    if refs.head.is_none()
        && let Ok(head) = get_ok(transport, &format!("{}/HEAD", reference.clone_url()), 4096)
        && let Some(target) = String::from_utf8_lossy(&head).trim().strip_prefix("ref: ")
    {
        refs.head = refs.commits.get(target).cloned();
    }
    Ok(refs)
}

/// The tree of `commit`, a (possibly gzipped) tar.
pub fn download(
    transport: &dyn GitTransport,
    reference: &RepoRef,
    commit: &str,
) -> Result<Vec<u8>, String> {
    match reference.archive_url(commit) {
        Some(url) => get_ok(transport, &url, MAX_ARCHIVE),
        None => transport.git_archive(&reference.clone_url(), commit, MAX_ARCHIVE),
    }
}

/// The release asset of a built extension (`cmux ext pack`).
pub const RELEASE_ASSET: &str = "cmux-extension.tar.gz";

/// A release's built package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asset {
    pub url: String,
    /// The host's `sha256:` digest of the asset, when it gives one.
    pub sha256: Option<String>,
}

/// What an install pins: the commit, the tag it is at, and the release
/// asset when the release has one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub commit: String,
    pub tag: Option<String>,
    pub asset: Option<Asset>,
}

/// A version tag: the manifest version, `1.2.0` or `v1.2.0`.
pub fn is_version_tag(tag: &str) -> bool {
    let core = tag.strip_prefix('v').unwrap_or(tag);
    let parts: Vec<&str> = core.split('.').collect();
    parts.len() == 3 && parts.iter().all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

impl Refs {
    /// The newest version tag ([`is_version_tag`]).
    pub fn newest_version_tag(&self) -> Option<String> {
        self.commits
            .keys()
            .filter_map(|name| name.strip_prefix("refs/tags/"))
            .filter(|tag| is_version_tag(tag))
            .max_by_key(|tag| version_triple(tag))
            .map(str::to_string)
    }
}

/// A GitHub release (`releases/latest`, or the release of `tag`): its tag
/// and its [`RELEASE_ASSET`], if any. `None` when there is no such release.
pub fn github_release(
    transport: &dyn GitTransport,
    reference: &RepoRef,
    tag: Option<&str>,
) -> Option<(String, Option<Asset>)> {
    if reference.host != "github.com" || !reference.path.is_empty() {
        return None;
    }
    let which = match tag {
        Some(tag) => format!("tags/{tag}"),
        None => "latest".into(),
    };
    let url = format!(
        "https://api.github.com/repos/{}/{}/releases/{which}",
        reference.owner, reference.repo
    );
    let (200, body) = transport.get(&url, "application/vnd.github+json", 4 << 20).ok()? else {
        return None;
    };
    let release: Value = serde_json::from_slice(&body).ok()?;
    let text =
        |value: &Value, key: &str| value.get(key).and_then(Value::as_str).map(str::to_string);
    let tag = text(&release, "tag_name")?;
    let assets = release.get("assets").and_then(Value::as_array);
    let asset = assets.into_iter().flatten().find_map(|asset| {
        (text(asset, "name").as_deref() == Some(RELEASE_ASSET)).then(|| Asset {
            url: text(asset, "browser_download_url").unwrap_or_default(),
            sha256: text(asset, "digest")
                .and_then(|d| d.strip_prefix("sha256:").map(str::to_ascii_lowercase)),
        })
    });
    let asset = asset.filter(|a| a.url.starts_with("https://"));
    Some((tag, asset))
}

/// The commit (and tag, and release asset) an install of `reference` pins.
/// No ref: the latest release (its built package when it has one), else
/// the newest version tag, else the default branch. A tag: its release's
/// built package when it has one, else the tag's tree. A branch or commit:
/// its tree.
pub fn resolve(
    transport: &dyn GitTransport,
    reference: &RepoRef,
    refs: &Refs,
) -> Result<Resolved, String> {
    let at_tag = |tag: String, asset: Option<Asset>| -> Result<Resolved, String> {
        let (commit, _) = refs.resolve(Some(&tag))?;
        Ok(Resolved { commit, tag: Some(tag), asset })
    };
    match reference.git_ref.as_deref() {
        None => {
            if let Some((tag, asset)) = github_release(transport, reference, None)
                && refs.commits.contains_key(&format!("refs/tags/{tag}"))
            {
                return at_tag(tag, asset);
            }
            match refs.newest_version_tag() {
                Some(tag) => at_tag(tag, None),
                None => {
                    refs.resolve(None).map(|(commit, tag)| Resolved { commit, tag, asset: None })
                }
            }
        }
        Some(git_ref) if refs.commits.contains_key(&format!("refs/tags/{git_ref}")) => {
            let asset =
                github_release(transport, reference, Some(git_ref)).and_then(|(_, asset)| asset);
            at_tag(git_ref.to_string(), asset)
        }
        Some(git_ref) => {
            refs.resolve(Some(git_ref)).map(|(commit, tag)| Resolved { commit, tag, asset: None })
        }
    }
}

/// Downloads a release asset and checks the host's digest: answers the
/// bytes and their SHA-256.
pub fn download_asset(
    transport: &dyn GitTransport,
    asset: &Asset,
) -> Result<(Vec<u8>, String), String> {
    let bytes = get_ok(transport, &asset.url, MAX_ARCHIVE)?;
    let sha256 = hex(&Sha256::digest(&bytes));
    if let Some(want) = asset.sha256.as_ref().filter(|want| **want != sha256) {
        return Err(format!("{RELEASE_ASSET}: its sha256 is {sha256}, the release says {want}"));
    }
    Ok((bytes, sha256))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Extracts the `path` directory of the archive's one top directory into
/// `dest` (which must not exist), and answers the SHA-256 of the tree
/// written: each file's relative path and content hash, sorted. Symlinks,
/// hard links and special files are skipped; an absolute path, a `..`, or a
/// size or entry count over the limits refuses the whole archive.
pub fn extract(archive: &[u8], path: &str, dest: &Path) -> Result<String, String> {
    extract_with(archive, path, dest, true, MAX_TOTAL)
}

/// Extracts a release's built package ([`RELEASE_ASSET`]): its files at
/// the archive's root, or under one top directory.
pub fn extract_release(archive: &[u8], dest: &Path) -> Result<String, String> {
    let mut at_root = false;
    let mut tar = open(archive);
    for entry in
        tar.entries().map_err(|e| format!("the archive does not read: {e}"))?.take(MAX_ENTRIES)
    {
        let entry = entry.map_err(|e| format!("the archive does not read: {e}"))?;
        let name = entry.path().map_err(|e| e.to_string())?.into_owned();
        let parts: Vec<_> =
            name.components().filter(|c| matches!(c, Component::Normal(_))).collect();
        if parts.len() == 1
            && matches!(
                name.file_name().and_then(|n| n.to_str()),
                Some("cmux-app.json" | "cmux-app.v2.json")
            )
        {
            at_root = true;
            break;
        }
    }
    extract_with(archive, "", dest, !at_root, MAX_TOTAL)
}

fn open(archive: &[u8]) -> tar::Archive<std::io::Take<Box<dyn std::io::Read + '_>>> {
    let reader: Box<dyn std::io::Read + '_> = if archive.starts_with(&[0x1f, 0x8b]) {
        Box::new(flate2::read::GzDecoder::new(archive))
    } else {
        Box::new(archive)
    };
    tar::Archive::new(reader.take(MAX_STREAM))
}

pub(super) fn extract_with(
    archive: &[u8],
    path: &str,
    dest: &Path,
    strip_top: bool,
    max_total: u64,
) -> Result<String, String> {
    let mut tar = open(archive);
    let prefix: Vec<String> =
        path.split('/').filter(|s| !s.is_empty()).map(str::to_string).collect();
    std::fs::create_dir_all(dest).map_err(|e| format!("{}: {e}", dest.display()))?;
    let mut files: Vec<(String, String)> = Vec::new();
    let mut total = 0u64;
    let mut entries = 0usize;
    for entry in tar.entries().map_err(|e| format!("the archive does not read: {e}"))? {
        let mut entry = entry.map_err(|e| format!("the archive does not read: {e}"))?;
        entries += 1;
        if entries > MAX_ENTRIES {
            return Err(format!("the archive has more than {MAX_ENTRIES} entries"));
        }
        let kind = entry.header().entry_type();
        if !(kind.is_file() || kind.is_dir()) {
            continue;
        }
        let name =
            entry.path().map_err(|e| format!("an archive path does not read: {e}"))?.into_owned();
        let mut parts = Vec::new();
        for component in name.components() {
            match component {
                Component::Normal(part) => {
                    parts.push(part.to_str().ok_or("an archive path is not UTF-8")?.to_string());
                }
                Component::CurDir => {}
                _ => return Err(format!("the archive path {} leaves the archive", name.display())),
            }
        }
        // The archive's one top directory (`REPO-COMMIT/`).
        let Some(parts) = parts.get(usize::from(strip_top)..) else { continue };
        let Some(inside) =
            parts.strip_prefix(prefix.as_slice()).filter(|inside| !inside.is_empty())
        else {
            continue;
        };
        let relative: PathBuf = inside.iter().collect();
        let target = dest.join(&relative);
        if kind.is_dir() {
            std::fs::create_dir_all(&target).map_err(|e| format!("{}: {e}", target.display()))?;
            continue;
        }
        let size = entry.header().size().map_err(|e| e.to_string())?;
        if size > MAX_FILE {
            return Err(format!("{} is larger than {} MiB", relative.display(), MAX_FILE >> 20));
        }
        total += size;
        if total > max_total {
            return Err(format!("the package is larger than {} MiB", max_total >> 20));
        }
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        }
        let mut body = Vec::with_capacity(size as usize);
        (&mut entry).take(size).read_to_end(&mut body).map_err(|e| e.to_string())?;
        std::fs::write(&target, &body).map_err(|e| format!("{}: {e}", target.display()))?;
        let relative = inside.join("/");
        files.push((relative, hex(&Sha256::digest(&body))));
    }
    if files.is_empty() {
        return Err(if path.is_empty() {
            "the archive holds no files".into()
        } else {
            format!("the repository has no directory {path} at this commit")
        });
    }
    files.sort();
    let mut tree = Sha256::new();
    for (name, digest) in &files {
        tree.update(name.as_bytes());
        tree.update([0]);
        tree.update(digest.as_bytes());
        tree.update(b"\n");
    }
    Ok(hex(&tree.finalize()))
}

/// The contract's id rule: a repository app's id starts with the
/// repository owner, lowercased (`OWNER/...`); `cmux/` and `manaflow-ai/`
/// only from manaflow-ai's repositories on github.com (another host's
/// `manaflow-ai` owner is not ours); never `local/`.
pub fn check_id(id: &str, host: &str, owner: &str) -> Result<(), String> {
    let owner = owner.to_ascii_lowercase();
    let publisher = id.split('/').next().unwrap_or_default();
    if publisher == "local" {
        return Err(format!("{id}: local/ apps come only from your own folders, not a repository"));
    }
    if FIRST_PARTY.contains(&publisher) {
        return if owner == "manaflow-ai" && host.eq_ignore_ascii_case(TRUSTED_HOST) {
            Ok(())
        } else {
            Err(format!(
                "{id}: {publisher}/ apps come only from manaflow-ai's repositories on {TRUSTED_HOST}"
            ))
        };
    }
    if publisher != owner {
        return Err(format!(
            "{id}: an app from {owner}'s repository must have an id starting with {owner}/"
        ));
    }
    Ok(())
}

fn version_triple(text: &str) -> Option<(u64, u64, u64)> {
    let core = text.trim().trim_start_matches('v').split(['-', '+']).next()?;
    let mut parts = core.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = match parts.next() {
        None | Some("x" | "*") => 0,
        Some(minor) => minor.parse().ok()?,
    };
    let patch = match parts.next() {
        None | Some("x" | "*") => 0,
        Some(patch) => patch.parse().ok()?,
    };
    Some((major, minor, patch))
}

/// Whether `have` meets one comparator (`^2.0`, `~2.1`, `>=0.70.0`, `2.0.0`,
/// `*`); `None` when the comparator does not parse.
fn meets(comparator: &str, have: (u64, u64, u64)) -> Option<bool> {
    let comparator = comparator.trim();
    if comparator == "*" || comparator.is_empty() {
        return Some(true);
    }
    for op in [">=", "<=", ">", "<", "=", "^", "~"] {
        if let Some(text) = comparator.strip_prefix(op) {
            let want = version_triple(text)?;
            return Some(match op {
                ">=" => have >= want,
                "<=" => have <= want,
                ">" => have > want,
                "<" => have < want,
                "=" => have == want,
                "^" if want.0 == 0 => have.0 == 0 && have.1 == want.1 && have >= want,
                "^" => have.0 == want.0 && have >= want,
                _ => have.0 == want.0 && have.1 == want.1 && have >= want,
            });
        }
    }
    let want = version_triple(comparator)?;
    Some(have == want)
}

/// The manifest's `engines.cmux`: alternatives joined by `||`, each a
/// space-separated set of comparators that must all hold (`^2.0 || ^3.0`,
/// `>=0.70.0 <1`). An alternative whose first comparator has major 2 or more
/// names the app platform ([`PLATFORM_API`], what every v2 manifest's `^2.0`
/// means); a lower one names the cmux release (`>=0.70.0`), unchecked in a
/// build that is not a release. The range passes when one alternative does.
/// A range this does not parse is refused, not guessed at.
pub fn check_engines(manifest: &Value, release: &str) -> Result<(), String> {
    let Some(range) = manifest.pointer("/engines/cmux").and_then(Value::as_str) else {
        return Ok(());
    };
    let unsupported = || {
        format!(
            "engines.cmux {range:?} is not a range this cmux reads: use comparators like ^2.0, ~2.1, >=0.70.0 or *, joined by spaces (and) or || (or)"
        )
    };
    // Parse every alternative first: one that does not parse refuses the range.
    let mut parsed: Vec<(bool, Vec<String>)> = Vec::new();
    for alternative in range.split("||") {
        // `>= 2.1` is one comparator written with a space.
        let mut comparators: Vec<String> = Vec::new();
        let mut pending = String::new();
        for token in alternative.split_whitespace() {
            if !pending.is_empty() {
                comparators.push(format!("{pending}{token}"));
                pending.clear();
            } else if token.chars().all(|c| matches!(c, '>' | '<' | '=' | '^' | '~')) {
                pending = token.to_string();
            } else {
                comparators.push(token.to_string());
            }
        }
        if !pending.is_empty() || comparators.is_empty() {
            return Err(unsupported());
        }
        if comparators.iter().any(|c| meets(c, (0, 0, 0)).is_none()) {
            return Err(unsupported());
        }
        let first = comparators
            .first()
            .ok_or_else(unsupported)?
            .trim_start_matches(['>', '<', '=', '^', '~']);
        let major = if first == "*" { 0 } else { version_triple(first).ok_or_else(unsupported)?.0 };
        parsed.push((major >= 2, comparators));
    }
    let mut platform_failed = false;
    let mut release_failed = false;
    for (platform, comparators) in &parsed {
        let have = if *platform {
            PLATFORM_API
        } else {
            match version_triple(release).filter(|v| *v != (0, 0, 0)) {
                Some(version) => version,
                // Not a release build: its release range is not checked.
                None => return Ok(()),
            }
        };
        if comparators.iter().all(|c| meets(c, have) == Some(true)) {
            return Ok(());
        }
        if *platform {
            platform_failed = true;
        } else {
            release_failed = true;
        }
    }
    if platform_failed && !release_failed {
        Err(format!(
            "this extension needs cmux app platform {range}; this cmux has {}.{}, so it needs a newer cmux",
            PLATFORM_API.0, PLATFORM_API.1
        ))
    } else {
        Err(format!("this extension requires cmux {range}; this cmux is {release}"))
    }
}

/// Where an installed git app came from (`sources.json`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitSource {
    /// `https://HOST/OWNER/REPO`.
    pub repository: String,
    pub host: String,
    pub owner: String,
    pub repo: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub path: String,
    /// The ref asked for; `None` follows the default branch.
    #[serde(rename = "ref", default, skip_serializing_if = "Option::is_none")]
    pub git_ref: Option<String>,
    pub commit: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    pub version: String,
    /// SHA-256 of the extracted tree ([`extract`]).
    pub sha256: String,
    /// SHA-256 of the release asset ([`RELEASE_ASSET`]) installed, when the
    /// install came from a release's built package rather than the tree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub asset_sha256: Option<String>,
    /// The package directory, relative to the git directory.
    pub dir: String,
    /// A GitHub signed tag at this commit (best effort).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub verified_source: bool,
}

impl GitSource {
    pub fn reference(&self) -> RepoRef {
        RepoRef {
            host: self.host.clone(),
            owner: self.owner.clone(),
            repo: self.repo.clone(),
            path: self.path.clone(),
            git_ref: self.git_ref.clone(),
        }
    }

    /// What an update fetches: the recorded ref, except that an install
    /// pinned to a version tag follows new releases (the latest one).
    pub fn update_reference(&self) -> RepoRef {
        let mut reference = self.reference();
        if reference.git_ref.as_deref().is_some_and(is_version_tag) {
            reference.git_ref = None;
        }
        reference
    }

    /// The fields an App Store row carries for this app.
    pub fn wire_fields(&self) -> serde_json::Map<String, Value> {
        let mut out = serde_json::Map::new();
        out.insert("repository".into(), Value::String(self.repository.clone()));
        if !self.path.is_empty() {
            out.insert("path".into(), Value::String(self.path.clone()));
        }
        if let Some(git_ref) = &self.git_ref {
            out.insert("ref".into(), Value::String(git_ref.clone()));
        }
        out.insert("commit".into(), Value::String(self.commit.clone()));
        if let Some(tag) = &self.tag {
            out.insert("tag".into(), Value::String(tag.clone()));
        }
        out.insert("version".into(), Value::String(self.version.clone()));
        out.insert("source_sha256".into(), Value::String(self.sha256.clone()));
        if let Some(asset) = &self.asset_sha256 {
            out.insert("asset_sha256".into(), Value::String(asset.clone()));
        }
        if self.verified_source {
            out.insert("verified_source".into(), Value::Bool(true));
        }
        out.insert("source_ref".into(), Value::String(self.reference().reference()));
        out.insert("update_ref".into(), Value::String(self.update_reference().reference()));
        out
    }
}

/// `sources.json`: the installed git apps, and the tree digest of every
/// commit fetched (kept after an uninstall, so a reinstall is checked).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Index {
    #[serde(default)]
    pub apps: BTreeMap<String, GitSource>,
    #[serde(default)]
    pub digests: BTreeMap<String, String>,
    /// The release asset SHA-256 of each digest key fetched from a release.
    #[serde(default)]
    pub assets: BTreeMap<String, String>,
}

impl Index {
    pub fn load(git_dir: &Path) -> Self {
        std::fs::read(git_dir.join(INDEX))
            .ok()
            .and_then(|raw| serde_json::from_slice(&raw).ok())
            .unwrap_or_default()
    }

    /// Writes durably: temp file, fsync, rename.
    pub fn save(&self, git_dir: &Path) -> std::io::Result<()> {
        use std::io::Write as _;
        std::fs::create_dir_all(git_dir)?;
        let temp = git_dir.join(format!("{INDEX}.tmp"));
        let body = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        let mut file = std::fs::File::create(&temp)?;
        file.write_all(&body)?;
        file.sync_all()?;
        std::fs::rename(&temp, git_dir.join(INDEX))
    }
}

/// `<state>/apps/git`, next to the local directory (`<state>/apps/local`).
pub fn git_dir(sources: &Sources) -> Option<PathBuf> {
    sources.local.as_ref()?.parent().map(|apps| apps.join("git"))
}

/// A relative directory of the index that stays inside the git directory.
pub fn inside(git_dir: &Path, relative: &str) -> Option<PathBuf> {
    let path = Path::new(relative);
    path.components().all(|c| matches!(c, Component::Normal(_))).then(|| git_dir.join(path))
}

/// Validates a fetched package: the one validator, the id rule, engines.
pub fn validate(dir: &Path, host: &str, owner: &str) -> Result<Package, String> {
    let package = catalog::package(dir, DirKind::Git)?;
    if package.id == catalog::CUSTOMIZE_APP {
        return Err(format!("{} loads only from the customize folder", catalog::CUSTOMIZE_APP));
    }
    check_id(&package.id, host, owner)?;
    check_engines(&package.manifest, crate::release::distribution_version())?;
    Ok(package)
}

/// Adds the installed git apps of `sources.json` to `catalog` (after the
/// shipped and local apps: a git app never shadows one).
pub fn load_into(catalog: &mut Catalog, sources: &Sources) {
    let Some(git_dir) = git_dir(sources) else { return };
    for (id, source) in Index::load(&git_dir).apps {
        let Some(dir) = inside(&git_dir, &source.dir) else {
            catalog.rejected.push((git_dir.join(&source.dir), format!("{id}: bad directory")));
            continue;
        };
        match catalog::package(&dir, DirKind::Git) {
            Ok(package) if package.id != id => {
                catalog.rejected.push((dir, format!("{id}: the package's id is {}", package.id)));
            }
            Ok(_) if catalog.packages.contains_key(&id) => catalog
                .rejected
                .push((dir, format!("{id}: an app with this id already ships with cmux"))),
            Ok(package) => {
                catalog.git.insert(id.clone(), source);
                catalog.packages.insert(id, package);
            }
            Err(issue) => catalog.rejected.push((dir, issue)),
        }
    }
}

/// Longest a custom host's `git fetch` and `git archive` may take in all.
const GIT_FETCH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// What a failed or stalled custom-host download says: git's own stderr
/// is not shown (it can carry the host's raw text).
const GIT_DOWNLOAD_FAILED: &str = "could not download the repository from its host; check that the address is right and the repository is public, then try again";

/// Bytes under `dir`, counting only until `cap` is passed.
fn dir_bytes(dir: &Path, cap: u64) -> u64 {
    let mut total = 0u64;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(next) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&next) else { continue };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                stack.push(entry.path());
            } else {
                total += meta.len();
            }
            if total > cap {
                return total;
            }
        }
    }
    total
}

/// Runs `git args` to its end, killing it when `deadline` passes or the
/// bytes it writes under `work` pass `limit`. Its streams are discarded:
/// the error is the fixed [`GIT_DOWNLOAD_FAILED`] (or the size limit).
fn run_git(
    args: &[&str],
    work: &Path,
    limit: u64,
    deadline: std::time::Instant,
) -> Result<(), String> {
    let mut child = cmux_process::Command::new("git")
        .args(["-c", "protocol.allow=never", "-c", "protocol.https.allow=always"])
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .map_err(|_| "git is not available to fetch from this host".to_string())?;
    loop {
        match child.wait_timeout(std::time::Duration::from_millis(200)) {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(_)) | Err(_) => return Err(GIT_DOWNLOAD_FAILED.to_string()),
            Ok(None) => {}
        }
        let too_big = dir_bytes(work, limit) > limit;
        if too_big || std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(if too_big {
                format!("the repository is larger than {} MiB", limit >> 20)
            } else {
                GIT_DOWNLOAD_FAILED.to_string()
            });
        }
    }
}

/// The network transport: reqwest on a runtime of its own (the caller is a
/// worker thread), `git` for hosts without an archive endpoint.
pub struct HttpTransport;

impl HttpTransport {
    fn runtime() -> Result<tokio::runtime::Runtime, String> {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| e.to_string())
    }

    fn client() -> Result<reqwest::Client, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::custom(|attempt| {
                if attempt.previous().len() >= 5 || attempt.url().scheme() != "https" {
                    attempt.stop()
                } else {
                    attempt.follow()
                }
            }))
            // Hosts answer the smart ref list only to a git client.
            .user_agent(concat!("git/2.0 (cmux/", env!("CARGO_PKG_VERSION"), ")"))
            .connect_timeout(std::time::Duration::from_secs(15))
            .timeout(std::time::Duration::from_secs(120))
            .build()
            .map_err(|e| e.to_string())
    }
}

impl GitTransport for HttpTransport {
    fn get(&self, url: &str, accept: &str, limit: u64) -> Result<(u16, Vec<u8>), String> {
        let client = Self::client()?;
        Self::runtime()?.block_on(async {
            let mut response = client
                .get(url)
                .header("accept", accept)
                .send()
                .await
                .map_err(|e| format!("{url}: {e}"))?;
            let status = response.status().as_u16();
            if response.content_length().is_some_and(|len| len > limit) {
                return Err(format!("{url}: larger than {} MiB", limit >> 20));
            }
            let mut body = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|e| format!("{url}: {e}"))? {
                body.extend_from_slice(&chunk);
                if body.len() as u64 > limit {
                    return Err(format!("{url}: larger than {} MiB", limit >> 20));
                }
            }
            Ok((status, body))
        })
    }

    fn git_archive(&self, clone_url: &str, commit: &str, limit: u64) -> Result<Vec<u8>, String> {
        if !is_commit(commit) || !clone_url.starts_with("https://") {
            return Err("git fetches only an https repository at a commit".into());
        }
        let work = std::env::temp_dir().join(format!(
            "cmux-git-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let run = |args: &[&str]| -> Result<Vec<u8>, String> {
            let output = cmux_process::Command::new("git")
                .args(["-c", "protocol.allow=never", "-c", "protocol.https.allow=always"])
                .args(args)
                .env("GIT_TERMINAL_PROMPT", "0")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .output()
                .map_err(|e| format!("git is not available to fetch from this host: {e}"))?;
            if output.status.success() {
                Ok(output.stdout)
            } else {
                Err(format!("git: {}", String::from_utf8_lossy(&output.stderr).trim()))
            }
        };
        let dir = work.to_string_lossy().into_owned();
        let result = (|| {
            run(&["init", "-q", "--bare", dir.as_str()])?;
            run(&[
                "-C",
                dir.as_str(),
                "fetch",
                "-q",
                "--depth",
                "1",
                "--no-tags",
                "--",
                clone_url,
                commit,
            ])?;
            run(&["-C", dir.as_str(), "archive", "--format=tar", "--prefix=tree/", commit])
        })();
        let _ = std::fs::remove_dir_all(&work);
        let tar = result?;
        if tar.len() as u64 > limit {
            return Err(format!("the tree is larger than {} MiB", limit >> 20));
        }
        Ok(tar)
    }

    fn post_json(&self, url: &str, body: &Value) -> Result<(), String> {
        let client = Self::client()?;
        Self::runtime()?.block_on(async {
            let request = client.post(url).json(body).timeout(std::time::Duration::from_secs(5));
            request.send().await.map(|_| ()).map_err(|e| e.to_string())
        })
    }
}

/// The extension registry (cmux-platform): `CMUX_EXTENSIONS_REGISTRY_URL`,
/// else production.
pub fn registry_base() -> String {
    std::env::var("CMUX_EXTENSIONS_REGISTRY_URL")
        .ok()
        .filter(|url| url.starts_with("https://"))
        .unwrap_or_else(|| "https://cloud-api.cmux.dev".into())
        .trim_end_matches('/')
        .to_string()
}

/// The community list of record (`manaflow-ai/cmux-extensions`'s
/// `extensions.json` on main): `CMUX_EXTENSIONS_INDEX_URL`, else that file.
pub fn community_index_url() -> String {
    std::env::var("CMUX_EXTENSIONS_INDEX_URL")
        .ok()
        .filter(|url| url.starts_with("https://"))
        .unwrap_or_else(|| {
            "https://raw.githubusercontent.com/manaflow-ai/cmux-extensions/main/extensions.json"
                .into()
        })
}

/// Whether the community list lists this package: an entry whose `repo`
/// (`OWNER/REPO` for GitHub, or `https://HOST/OWNER/REPO`) and `path` name
/// it. Listing is the review (the registry repo's CI and a person merge
/// it); anything else, or no answer, is not reviewed.
pub fn reviewed(transport: &dyn GitTransport, reference: &RepoRef) -> bool {
    let Ok((200, body)) = transport.get(&community_index_url(), "application/json", 8 << 20) else {
        return false;
    };
    let Ok(Value::Array(entries)) = serde_json::from_slice::<Value>(&body) else { return false };
    entries.iter().any(|entry| {
        let Some(repo) = entry.get("repo").and_then(Value::as_str) else { return false };
        let named = match repo.strip_prefix("https://") {
            Some(url) => url.trim_end_matches('/').trim_end_matches(".git").to_string(),
            None => format!("github.com/{repo}"),
        };
        let path = entry.get("path").and_then(Value::as_str).unwrap_or_default().trim_matches('/');
        named.eq_ignore_ascii_case(&format!(
            "{}/{}/{}",
            reference.host, reference.owner, reference.repo
        )) && path == reference.path
            // A registry listing's `status`: only "reviewed" counts (absent: listed on main is approved).
            && entry.get("status").and_then(Value::as_str).is_none_or(|status| status == "reviewed")
    })
}

/// Whether `tag` is a GitHub-verified signed tag (best effort, never
/// required): the tag object's `verification.verified`.
pub fn signed_tag(
    transport: &dyn GitTransport,
    reference: &RepoRef,
    refs: &Refs,
    tag: &str,
) -> bool {
    if reference.host != "github.com" {
        return false;
    }
    let Some(object) = refs.tag_objects.get(&format!("refs/tags/{tag}")) else { return false };
    let url = format!(
        "https://api.github.com/repos/{}/{}/git/tags/{object}",
        reference.owner, reference.repo
    );
    match transport.get(&url, "application/vnd.github+json", 1 << 20) {
        Ok((200, body)) => serde_json::from_slice::<Value>(&body)
            .ok()
            .is_some_and(|tag| tag.pointer("/verification/verified") == Some(&Value::Bool(true))),
        _ => false,
    }
}

/// The anonymous install count: `POST /v1/extensions/installs {ref, commit}`,
/// no user id. Off with `CMUX_EXTENSIONS_NO_PING`.
pub fn ping_install(transport: &dyn GitTransport, reference: &RepoRef, commit: &str) {
    if std::env::var_os("CMUX_EXTENSIONS_NO_PING").is_some() {
        return;
    }
    let url = format!("{}/v1/extensions/installs", registry_base());
    let body = serde_json::json!({ "ref": reference.canonical(), "commit": commit });
    let _ = transport.post_json(&url, &body);
}

#[cfg(test)]
#[path = "git_source_tests.rs"]
pub(super) mod tests;
