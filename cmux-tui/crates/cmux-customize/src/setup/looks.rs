//! The looks gallery: setup repos cmux lists by name, each previewed on the
//! golden sample, installed, stacked and removed with the setup verbs.
//!
//! The catalog ([`CATALOG`], `looks.json` next to this file) is compiled in
//! and changes only by a reviewed PR. The gallery is the catalog with each
//! look's install state, and the stack: every installed setup (catalog or
//! not), top layer first, from the receipts. Nothing here reaches the
//! network; fetching a preview image is the caller's (the CLI's), and this
//! module only names the files to try, where they are, and where the copy
//! is cached.
//!
//! ```text
//! <state dir>/looks/previews/OWNER-NAME/
//!   dark.png    dark.json     the image, and which repo file it was (or none)
//!   light.png   light.json
//! ```

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::{Receipt, Reference, SetupSource, check_id};
use crate::Error;

/// The catalog as compiled in.
pub const CATALOG: &str = include_str!("looks.json");
/// The catalog format version this cmux reads.
pub const CATALOG_FORMAT: u32 = 1;
/// The most bytes one preview image may have.
pub const MAX_PREVIEW_BYTES: u64 = 4 * 1024 * 1024;
/// How long a cached preview (or a repo's lack of one) is used before it is
/// fetched again.
pub const PREVIEW_MAX_AGE_SECS: u64 = 24 * 60 * 60;
/// The preview cache, under the customize state dir.
const PREVIEWS: &str = "looks/previews";

/// `looks.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Catalog {
    #[serde(rename = "cmuxLooks")]
    pub format: u32,
    pub looks: Vec<Look>,
}

/// One look the gallery lists.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Look {
    /// The setup id its `cmux-setup.json` names, `OWNER/NAME`.
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub tagline: String,
    /// The repo it installs from, `HOST/OWNER/REPO[/PATH][@BRANCH]`. A branch
    /// is for a look in a folder of a repo whose default branch does not carry
    /// it (cmux's own `examples/looks` live on feat-cmux-next); the card still
    /// resolves it to one commit, and Install pins that commit.
    pub repo: String,
    #[serde(default)]
    pub tags: Vec<String>,
    /// Repo files that picture it, per scheme, tried before the golden
    /// sample's (a look whose pictures are not at `preview/golden-*.png`).
    #[serde(default, skip_serializing_if = "Previews::is_empty")]
    pub previews: Previews,
}

/// A catalog look's own preview files, repo paths.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Previews {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub light: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dark: Option<String>,
}

impl Previews {
    fn is_empty(&self) -> bool {
        self.light.is_none() && self.dark.is_none()
    }

    fn of(&self, scheme: Scheme) -> Option<&String> {
        match scheme {
            Scheme::Light => self.light.as_ref(),
            Scheme::Dark => self.dark.as_ref(),
        }
    }
}

impl Look {
    /// The repo as a reference (the catalog was checked to parse).
    pub fn reference(&self) -> Option<Reference> {
        Reference::parse(&self.repo).ok()
    }
}

/// Reads a catalog: the format, one entry per id and per repo, each repo a
/// reference with no ref (the gallery installs a look at the commit its
/// card shows), each id one its repo's owner may publish.
pub fn parse_catalog(text: &str) -> Result<Catalog, Error> {
    let catalog: Catalog = serde_json::from_str(text)
        .map_err(|error| Error::Setup(format!("the looks catalog does not read: {error}")))?;
    if catalog.format != CATALOG_FORMAT {
        return Err(Error::Setup(format!(
            "the looks catalog is format {}, this cmux reads {CATALOG_FORMAT}",
            catalog.format
        )));
    }
    let mut keys = Vec::new();
    for look in &catalog.looks {
        let reference = Reference::parse(&look.repo)?;
        if reference.git_ref.as_deref().is_some_and(is_commit) {
            return Err(Error::Setup(format!(
                "look {}: its repo names a commit; name a branch, the card pins the commit",
                look.id
            )));
        }
        check_id(&look.id, &reference.owner)?;
        if look.name.trim().is_empty() {
            return Err(Error::Setup(format!("look {} has no name", look.id)));
        }
        for file in [&look.previews.light, &look.previews.dark].into_iter().flatten() {
            if !is_repo_file(file) {
                return Err(Error::Setup(format!(
                    "look {}: preview {file:?} is not a file in its repo",
                    look.id
                )));
            }
        }
        for key in [look.id.clone(), reference.key()] {
            if keys.contains(&key) {
                return Err(Error::Setup(format!("the looks catalog lists {key} twice")));
            }
            keys.push(key);
        }
    }
    Ok(catalog)
}

/// A full commit hash. A catalog look names a branch, never a commit, so the
/// gallery shows what that branch holds now.
fn is_commit(git_ref: &str) -> bool {
    git_ref.len() == 40 && git_ref.bytes().all(|b| b.is_ascii_hexdigit())
}

/// A relative path inside a repo: no leading `/`, no `.` or `..` part, no
/// backslash or query.
fn is_repo_file(file: &str) -> bool {
    !file.is_empty()
        && !file.starts_with('/')
        && !file.contains(['\\', '?', '#'])
        && file.split('/').all(|part| !part.is_empty() && part != "." && part != "..")
}

/// The catalog compiled into this cmux.
pub fn catalog() -> Result<Catalog, Error> {
    parse_catalog(CATALOG)
}

/// An installed setup as the gallery shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StackRow {
    pub id: String,
    pub name: String,
    pub on: bool,
    /// 1 is the top layer.
    pub position: usize,
    /// The repo it was installed from (`HOST/OWNER/REPO[/PATH]`), or its folder.
    pub source: String,
    pub commit: String,
    /// Whether the catalog lists it.
    pub catalog: bool,
}

/// A catalog look and its install state (`None`: not installed).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GalleryLook {
    #[serde(flatten)]
    pub look: Look,
    pub installed: Option<StackRow>,
}

/// `cmux setup gallery`: the catalog's looks, and every installed setup,
/// top layer first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Gallery {
    pub looks: Vec<GalleryLook>,
    pub stack: Vec<StackRow>,
}

/// Whether `receipt` is the install of `look`: the same id, or the same repo.
fn is_look(look: &Look, receipt: &Receipt) -> bool {
    receipt.id == look.id || look.reference().is_some_and(|r| receipt.source.key() == r.key())
}

/// The gallery from `catalog` and the receipts (top first, as kept).
pub fn gallery(catalog: &Catalog, receipts: &[Receipt]) -> Gallery {
    let stack: Vec<StackRow> = receipts
        .iter()
        .enumerate()
        .map(|(at, receipt)| StackRow {
            id: receipt.id.clone(),
            name: receipt.name.clone(),
            on: receipt.on,
            position: at + 1,
            source: receipt.source.key(),
            commit: receipt.commit.clone(),
            catalog: catalog.looks.iter().any(|look| is_look(look, receipt)),
        })
        .collect();
    let looks = catalog
        .looks
        .iter()
        .map(|look| GalleryLook {
            look: look.clone(),
            installed: receipts
                .iter()
                .position(|receipt| is_look(look, receipt))
                .and_then(|at| stack.get(at).cloned()),
        })
        .collect();
    Gallery { looks, stack }
}

/// A light or dark preview.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Scheme {
    Light,
    #[default]
    Dark,
}

impl Scheme {
    pub fn parse(text: &str) -> Option<Scheme> {
        match text {
            "light" => Some(Scheme::Light),
            "dark" => Some(Scheme::Dark),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Scheme::Light => "light",
            Scheme::Dark => "dark",
        }
    }

    fn other(self) -> Scheme {
        match self {
            Scheme::Light => Scheme::Dark,
            Scheme::Dark => Scheme::Light,
        }
    }
}

/// The repo files a preview is, in the order tried: the golden sample in
/// this scheme, in the other one, then the chat screenshot.
pub fn preview_files(scheme: Scheme) -> [String; 3] {
    [
        format!("preview/golden-{}.png", scheme.as_str()),
        format!("preview/golden-{}.png", scheme.other().as_str()),
        "screenshots/chat.png".to_owned(),
    ]
}

/// The files tried for look `id`: the catalog's own pictures of it (this
/// scheme, then the other), then [`preview_files`].
pub fn look_preview_files(catalog: &Catalog, id: &str, scheme: Scheme) -> Vec<String> {
    let own = catalog.looks.iter().find(|look| look.id == id).map(|look| &look.previews);
    let mut files: Vec<String> = own
        .into_iter()
        .flat_map(|previews| [previews.of(scheme), previews.of(scheme.other())])
        .flatten()
        .cloned()
        .collect();
    for file in preview_files(scheme) {
        if !files.contains(&file) {
            files.push(file);
        }
    }
    files
}

/// Where a look's preview is read from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PreviewSource {
    /// A repo at a ref (`None`: its default branch).
    Repo { reference: Reference, git_ref: Option<String> },
    /// A folder installed from this machine: read in place, never cached.
    Folder { path: PathBuf },
}

/// A look the preview verb names, resolved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreviewTarget {
    /// Its id (the repo's key when neither the catalog nor a receipt names one).
    pub id: String,
    pub source: PreviewSource,
}

/// The look `which` names (an id, or a repo in any form): the installed
/// setup first (at the commit it is installed at), then the catalog (at the
/// branch it names, else the repo's default branch), then any repo reference.
pub fn resolve_preview(
    catalog: &Catalog,
    receipts: &[Receipt],
    which: &str,
) -> Result<PreviewTarget, Error> {
    let key = Reference::parse(which).ok();
    let named = |id: &str, repo: &str| id == which || key.as_ref().is_some_and(|k| k.key() == repo);
    if let Some(receipt) = receipts.iter().find(|r| named(&r.id, &r.source.key())) {
        let source = match &receipt.source {
            SetupSource::Repo { reference } => PreviewSource::Repo {
                reference: reference.at(None),
                git_ref: Some(receipt.commit.clone()),
            },
            SetupSource::Folder { path } => PreviewSource::Folder { path: path.clone() },
        };
        return Ok(PreviewTarget { id: receipt.id.clone(), source });
    }
    let listed = catalog.looks.iter().find_map(|look| {
        let reference = look.reference()?;
        named(&look.id, &reference.key()).then(|| (look.id.clone(), reference))
    });
    if let Some((id, reference)) = listed {
        let git_ref = reference.git_ref.clone();
        let source = PreviewSource::Repo { reference: reference.at(None), git_ref };
        return Ok(PreviewTarget { id, source });
    }
    match key {
        Some(reference) => {
            let git_ref = reference.git_ref.clone();
            Ok(PreviewTarget {
                id: reference.key(),
                source: PreviewSource::Repo { reference: reference.at(None), git_ref },
            })
        }
        None => Err(Error::Setup(format!(
            "{which} is not a look in the gallery, an installed setup or a repo; `cmux setup gallery` lists them"
        ))),
    }
}

/// The https URL of repo file `file` at `git_ref` (`HEAD` when none), for a
/// host that serves raw files; `None` for any other host.
pub fn raw_url(reference: &Reference, git_ref: Option<&str>, file: &str) -> Option<String> {
    if reference.host != "github.com" {
        return None;
    }
    let mut path = reference.path.clone();
    if !path.is_empty() {
        path.push('/');
    }
    Some(format!(
        "https://raw.githubusercontent.com/{}/{}/{}/{path}{file}",
        reference.owner,
        reference.repo,
        git_ref.unwrap_or("HEAD"),
    ))
}

/// The cache folder of look `id`'s previews: `looks/previews/OWNER-NAME`.
pub fn preview_cache_dir(state_dir: &Path, id: &str) -> PathBuf {
    let mut name: String = id
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '.' { c.to_ascii_lowercase() } else { '-' })
        .collect();
    name.truncate(96);
    let name = name.trim_matches(|c| c == '-' || c == '.');
    state_dir.join(PREVIEWS).join(if name.is_empty() { "look" } else { name })
}

/// Whether `bytes` is a PNG file.
pub fn is_png(bytes: &[u8]) -> bool {
    bytes.starts_with(b"\x89PNG\r\n\x1a\n")
}

#[cfg(test)]
#[path = "looks_tests.rs"]
mod tests;
