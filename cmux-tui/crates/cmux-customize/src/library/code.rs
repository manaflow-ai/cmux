//! Code layers: a library entry that is code not in your build, not settings
//! or files (cmuxterm-hq `docs/design/experiments-shelf.md`). The code comes
//! from a pull request, a branch or commit of manaflow-ai/cmux, a folder on
//! this computer, or a fork's own published layer ([`CodeKind`]).
//!
//! ```text
//! <state dir>/layers/<key>/      one PR's web bundles, as an overlay folder
//!                                 (agent-pane/, pages/, webviews-app/, manifest.json)
//! <config dir>/web-dev.json       `overlay` names the folder the app serves
//! ```
//!
//! A PR entry carries a [`CodeLayer`]: the PR, its head, the base CI merged it
//! onto, the published web bundle key and the parts that need a build. Its
//! web part is one stack key, `code:web`, decided like every setting: the
//! highest entry that is on wins, the others list it under `overridden`. Two
//! PRs' web bundles are two whole builds, so they never merge at runtime.
//!
//! Making the stack live writes only `overlay` and `enabled` in web-dev.json
//! (the app reloads every page on that file). The values they had before the
//! first code entry came on are the base, kept in the library, and turning
//! the last code entry off writes them back exactly, a key that was not there
//! is removed again. Every other key in web-dev.json (a dev server, its
//! token) is left as it was.
//!
//! Fetching a layer is the CLI's (`cmux customize use pr:N`): this module
//! only reads and writes files, as the rest of the crate.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::{Customize, Error};

/// The stack key of a code entry's web part.
pub const WEB_KEY: &str = "code:web";
/// The file the app watches for an overlay (WebDevOverride.swift).
pub const WEB_DEV: &str = "web-dev.json";
/// Where a web-dev.json that did not read is kept when the library writes it.
pub const WEB_DEV_UNREADABLE: &str = "web-dev.json.unreadable";
/// What an overlay folder holds once its install is complete.
pub const LAYER_MANIFEST: &str = "manifest.json";

/// Where a code layer's code comes from.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CodeKind {
    /// A pull request of manaflow-ai/cmux (`pr:N`): CI publishes its layer.
    #[default]
    Pr,
    /// A branch of manaflow-ai/cmux (`branch:NAME`): CI publishes its tip's layer.
    Branch,
    /// A commit on a branch of manaflow-ai/cmux (`sha:SHA`).
    Sha,
    /// A working copy on this computer (`dir:PATH`), built here.
    Dir,
    /// A fork's branch (`OWNER/REPO@REF`): the fork's own CI publishes its
    /// layer as a release of the fork; our CI never builds fork code.
    Fork,
}

impl CodeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            CodeKind::Pr => "pr",
            CodeKind::Branch => "branch",
            CodeKind::Sha => "sha",
            CodeKind::Dir => "dir",
            CodeKind::Fork => "fork",
        }
    }

    fn is_pr(&self) -> bool {
        *self == CodeKind::Pr
    }
}

/// Code not in your build as a library entry: a pull request, a branch, a
/// commit, a local folder or a fork.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodeLayer {
    /// Where the code comes from; absent in older entries, which are PRs.
    #[serde(default, skip_serializing_if = "CodeKind::is_pr")]
    pub kind: CodeKind,
    /// The branch, the full commit, the folder's absolute path, or
    /// `OWNER/REPO@REF`; empty for a PR.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub source: String,
    /// `owner/name`.
    pub repo: String,
    /// The pull request; 0 for every other kind.
    #[serde(default)]
    pub pr: u64,
    #[serde(default)]
    pub title: String,
    /// The commit this layer was built from (a folder's HEAD).
    pub head: String,
    /// The commit the change was applied onto.
    #[serde(default)]
    pub base: String,
    /// The published web bundle key (files.cmux.com/cmux-next-web/<key>); empty
    /// when the PR changes no web bundle.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub web: String,
    /// The web ABI the bundles need (the app refuses another).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub abi: Option<u32>,
    /// What this layer cannot carry, one line each: "needs a build: ...".
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub needs_build: Vec<String>,
    /// The last settle's word on it: `in your build`, `no longer applies: ...`,
    /// `newer head ...`. Empty when nothing is to say.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub note: String,
}

impl CodeLayer {
    /// `pr-43496`: the entry name a PR gets.
    pub fn entry_name(pr: u64) -> String {
        format!("pr-{pr}")
    }

    /// The entry name this layer gets: `pr-N`, `branch-NAME`, `sha-XXXXXXX`,
    /// `dir-NAME` (the folder's name) or `fork-OWNER-REF`.
    pub fn name(&self) -> String {
        let name = match self.kind {
            CodeKind::Pr => return CodeLayer::entry_name(self.pr),
            CodeKind::Branch => format!("branch-{}", slug(&self.source)),
            CodeKind::Sha => format!("sha-{}", self.source.chars().take(7).collect::<String>()),
            CodeKind::Dir => format!(
                "dir-{}",
                slug(
                    &Path::new(&self.source)
                        .file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .unwrap_or_default()
                )
            ),
            CodeKind::Fork => {
                let (repo, reference) = self.source.split_once('@').unwrap_or((&self.source, ""));
                let owner = repo.split('/').next().unwrap_or(repo);
                format!("fork-{}-{}", slug(owner), slug(reference))
            }
        };
        let name: String = name.chars().take(64).collect();
        name.trim_end_matches('-').to_owned()
    }

    /// How a person names the source: `#43496`, `branch feat-x`, `commit
    /// dbb1e3e`, `folder ~/cmux`, `fork someone/cmux@main`.
    pub fn source_label(&self) -> String {
        match self.kind {
            CodeKind::Pr => format!("#{}", self.pr),
            CodeKind::Branch => format!("branch {}", self.source),
            CodeKind::Sha => format!("commit {}", self.source.chars().take(7).collect::<String>()),
            CodeKind::Dir => format!("folder {}", self.source),
            CodeKind::Fork => format!("fork {}", self.source),
        }
    }

    /// The source and its title, one line: `#43496 cat icon`.
    pub fn label(&self) -> String {
        let label = self.source_label();
        if self.title.is_empty() { label } else { format!("{label} {}", self.title) }
    }

    /// Whether the entry has a web part to serve.
    pub fn has_web(&self) -> bool {
        !self.web.is_empty()
    }

    /// The same source (the same PR, branch, commit, folder or fork ref).
    pub fn same_source(&self, other: &CodeLayer) -> bool {
        self.kind == other.kind
            && self.repo == other.repo
            && self.pr == other.pr
            && self.source == other.source
    }

    /// The same source at the same head.
    pub fn same(&self, other: &CodeLayer) -> bool {
        self.same_source(other) && self.head == other.head
    }
}

/// `Feat/Night Theme` -> `feat-night-theme`: lowercase letters and digits,
/// everything else one `-`.
pub fn slug(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_matches('-').to_owned()
}

/// What `overlay` and `enabled` were in web-dev.json before the library
/// pointed it at a layer. `None`: the key was not there.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct WebBase {
    #[serde(default)]
    pub overlay: Option<Value>,
    #[serde(default)]
    pub enabled: Option<Value>,
    /// There was no web-dev.json at all, so putting the base back removes the
    /// file again instead of leaving `{}`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub no_file: bool,
    /// web-dev.json's text as it was, so putting the base back writes the
    /// same bytes (key order, spacing, comments) when nothing else in it
    /// changed since. `None`: an older library, or no file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// Where web-dev.json points now, as the stack decides it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum WebTarget {
    /// The base: what was there before.
    Base,
    /// A layer folder.
    Layer(PathBuf),
}

impl Customize {
    /// Where layer `key`'s overlay folder is.
    pub fn layer_dir(&self, key: &str) -> PathBuf {
        self.roots().state_dir.join("layers").join(key)
    }

    /// Whether layer `key` is installed whole (its manifest was written last).
    pub fn layer_ready(&self, key: &str) -> bool {
        valid_key(key) && self.layer_dir(key).join(LAYER_MANIFEST).is_file()
    }

    fn web_dev_path(&self) -> PathBuf {
        self.roots().config_dir.join(WEB_DEV)
    }

    /// `overlay` and `enabled` as web-dev.json has them now.
    pub(crate) fn web_dev_now(&self) -> Result<WebBase, Error> {
        let path = self.web_dev_path();
        let (object, unreadable) = read_object(&path)?;
        let text = match unreadable {
            Some(_) => None,
            None => std::fs::read_to_string(&path).ok(),
        };
        Ok(WebBase {
            overlay: object.get("overlay").cloned(),
            enabled: object.get("enabled").cloned(),
            no_file: !path.exists(),
            text,
        })
    }

    /// Points web-dev.json at `target`, writing only `overlay` and `enabled`,
    /// under web-overlay.sh's own lock (`.web-dev.lock`). `base` is what
    /// [`WebTarget::Base`] writes back.
    pub(crate) fn write_web_dev(&self, target: &WebTarget, base: &WebBase) -> Result<(), Error> {
        let path = self.web_dev_path();
        std::fs::create_dir_all(&self.roots().config_dir)?;
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.roots().config_dir.join(".web-dev.lock"))?;
        let _lock = cmux_file_lock::FileLock::take(lock, cmux_file_lock::Kind::Exclusive)?;
        (|| {
            let (mut object, unreadable) = read_object(&path)?;
            // A file that reads as neither JSON nor JSONC is kept beside, never
            // written over unseen (the app reads it as empty, so none of it
            // was live).
            if let Some(text) = unreadable {
                cmux_config::fsio::write_atomic(
                    &self.roots().config_dir.join(WEB_DEV_UNREADABLE),
                    text.as_bytes(),
                )?;
            }
            let (overlay, enabled) = match target {
                WebTarget::Layer(dir) => (
                    Some(Value::String(dir.to_string_lossy().into_owned())),
                    Some(Value::Bool(true)),
                ),
                WebTarget::Base => (base.overlay.clone(), base.enabled.clone()),
            };
            for (key, value) in [("overlay", overlay), ("enabled", enabled)] {
                match value {
                    Some(value) => object.insert(key.to_owned(), value),
                    None => object.remove(key),
                };
            }
            if object.is_empty() && !path.exists() {
                return Ok(());
            }
            if object.is_empty() && matches!(target, WebTarget::Base) && base.no_file {
                std::fs::remove_file(&path)?;
                return Ok(());
            }
            // Back to the base with nothing else changed: the file as it was,
            // byte for byte, not a re-sorted copy.
            if matches!(target, WebTarget::Base)
                && let Some(text) = &base.text
                && parse_object(text).is_some_and(|was| was == object)
            {
                cmux_config::fsio::write_atomic(&path, text.as_bytes())?;
                return Ok(());
            }
            let mut text = serde_json::to_string_pretty(&Value::Object(object))
                .map_err(std::io::Error::other)?;
            text.push('\n');
            cmux_config::fsio::write_atomic(&path, text.as_bytes())?;
            Ok(())
        })()
    }
}

/// A web bundle key: 64 lowercase hex.
pub fn valid_key(key: &str) -> bool {
    key.len() == 64 && key.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// web-dev.json's keys. A file with comments or trailing commas reads as
/// JSONC, so its other keys are kept. One that reads as neither is empty
/// (web-overlay.sh reads a broken file as empty too) and its text comes back
/// second, for a write to keep beside.
pub(crate) fn read_object(path: &Path) -> Result<(Map<String, Value>, Option<String>), Error> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ok(match parse_object(&text) {
            Some(object) => (object, None),
            None if text.trim().is_empty() => (Map::new(), None),
            None => (Map::new(), Some(text)),
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok((Map::new(), None)),
        Err(error) => Err(error.into()),
    }
}

/// web-dev.json's text as an object, as JSON or JSONC.
fn parse_object(text: &str) -> Option<Map<String, Value>> {
    match serde_json::from_str::<Value>(text).ok().or_else(|| cmux_config::jsonc::parse(text).ok())
    {
        Some(Value::Object(object)) => Some(object),
        _ => None,
    }
}
