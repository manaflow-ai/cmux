//! Each installed setup's views as a layer of its own, like dotfiles: a
//! setup's `customize/` files never go into the person's own customize
//! folder (the app `local/customize`, which stays theirs and on top).
//!
//! ```text
//! ~/.config/cmux-next/setups/            (Roots::setups_dir)
//!   layers.json                          the layers that are on, top first
//!   setup-OWNER-NAME/cmux-app.json ...   one setup's views, as the app local/setup-OWNER-NAME
//! ```
//!
//! The folder's files are the setup's `customize/...` files at the same
//! paths under it; its `cmux-app.json` (which says `local/customize` in the
//! repo) is written with the layer's own id. `layers.json` is written from
//! the receipts on every change (install, update, remove, on, off, order);
//! the daemon's catalog loads exactly the folders it names, in its order,
//! and refuses a `local/setup-*` id from anywhere else. What a layer does
//! not have, a lower one or the person's own app still shows; the person's
//! own app is never written here.

use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Receipt, profile_name};
use crate::Error;
use crate::profile::Profile;

/// The index file in the setups folder.
pub const INDEX_FILE: &str = "layers.json";
/// The index format version.
pub const INDEX_FORMAT: u32 = 1;
/// The logical prefix of a setup's views files.
const VIEWS: &str = "customize/";

/// `layers.json`: the layers that are on, top first.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Index {
    #[serde(rename = "cmuxSetupLayers")]
    pub format: u32,
    pub layers: Vec<IndexRow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexRow {
    /// The setup's id, `OWNER/NAME`.
    pub id: String,
    /// The app id the layer loads as, `local/<dir>`.
    pub app: String,
    /// Its folder under the setups folder.
    pub dir: String,
}

/// The layer folder (and app name) for setup `id`: `setup-OWNER-NAME`.
pub fn name(id: &str) -> String {
    profile_name(id)
}

/// The app id the layer of setup `id` loads as.
pub fn app_id(id: &str) -> String {
    format!("local/{}", name(id))
}

/// The app id a setup repo's views carry in the repo (`customize/cmux-app.json`), which the layer is
/// written over with its own ([`app_id`]).
pub const REPO_APP: &str = "local/customize";

/// The settings whose value names an app: a whole New Tab page (`cmux.newtab/1`) shows only once
/// `tabs.newTabApp` picks it.
const APP_SETTINGS: &[&str] = &["tabs.newTabApp"];

/// Setup `id`'s settings as they install over its own layer: a setting that names the repo's views
/// app ([`REPO_APP`], what a look's `tabs.newTabApp` says in its repo) names the layer's app
/// instead, `local/setup-OWNER-NAME`. So a New Tab look picks its own page, never the person's own
/// `local/customize`; two looks each pick their own, and the higher one's pick shows (`cmux setup
/// order`, `off`). Called only for a setup that has views; any other value stays as written.
pub fn point_at_layer(settings: &mut BTreeMap<String, Value>, id: &str) {
    for key in APP_SETTINGS {
        if let Some(value) = settings.get_mut(*key)
            && value.as_str() == Some(REPO_APP)
        {
            *value = Value::String(app_id(id));
        }
    }
}

/// Whether logical path `path` is a views file (`customize/...`).
pub fn is_view(path: &str) -> bool {
    path.starts_with(VIEWS)
}

/// `profile` without its views files, and the views files apart (still at
/// their logical paths).
pub fn split_views(profile: &Profile) -> (Profile, BTreeMap<String, String>) {
    let mut rest = profile.clone();
    let views: BTreeMap<String, String> = profile
        .files
        .iter()
        .filter(|(path, _)| is_view(path))
        .map(|(p, t)| (p.clone(), t.clone()))
        .collect();
    rest.files.retain(|path, _| !is_view(path));
    (rest, views)
}

/// Writes setup `id`'s views as its layer folder, whole: into a folder of
/// its own first, then in place of the old one. `None` (and no folder) when
/// it has no views.
pub fn write_layer(
    setups_dir: &Path,
    id: &str,
    views: &BTreeMap<String, String>,
) -> Result<Option<String>, Error> {
    if views.is_empty() {
        return Ok(None);
    }
    let layer = name(id);
    let fresh = setups_dir.join(format!(".{layer}.new"));
    remove_dir(&fresh)?;
    for (logical, text) in views {
        let inner = logical.strip_prefix(VIEWS).unwrap_or(logical);
        let relative = plain_relative(inner).ok_or_else(|| {
            Error::Setup(format!("{logical} is not a plain path inside customize/"))
        })?;
        let file = fresh.join(relative);
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let bytes = if inner == "cmux-app.json" || inner == "cmux-app.v2.json" {
            with_id(text, &app_id(id))?
        } else {
            text.clone().into_bytes()
        };
        std::fs::write(&file, bytes)?;
    }
    let live = setups_dir.join(&layer);
    let old = setups_dir.join(format!(".{layer}.old"));
    remove_dir(&old)?;
    if live.exists() {
        std::fs::rename(&live, &old)?;
    }
    std::fs::rename(&fresh, &live)?;
    remove_dir(&old)?;
    Ok(Some(layer))
}

/// The app manifest with the layer's id in place of `local/customize`.
fn with_id(text: &str, id: &str) -> Result<Vec<u8>, Error> {
    let mut manifest: Value = cmux_config::jsonc::parse(text)
        .map_err(|_| Error::Setup("customize/cmux-app.json is not JSON".to_owned()))?;
    let Some(fields) = manifest.as_object_mut() else {
        return Err(Error::Setup("customize/cmux-app.json is not an object".to_owned()));
    };
    fields.insert("id".to_owned(), Value::String(id.to_owned()));
    let mut text = serde_json::to_string_pretty(&manifest).map_err(std::io::Error::other)?;
    text.push('\n');
    Ok(text.into_bytes())
}

fn plain_relative(path: &str) -> Option<PathBuf> {
    let path = Path::new(path);
    let plain = path.components().all(|part| matches!(part, Component::Normal(_)));
    (plain && !path.as_os_str().is_empty()).then(|| path.to_path_buf())
}

/// Deletes layer `layer`'s folder; one that is not there is no change.
pub fn remove_layer(setups_dir: &Path, layer: &str) -> Result<(), Error> {
    if plain_relative(layer).is_none() || layer.contains('/') {
        return Ok(());
    }
    remove_dir(&setups_dir.join(layer))
}

/// Layer `layer`'s files as they are, at their paths inside its folder
/// (empty: no folder). Views are text; a file that is not is refused.
pub fn read_layer(setups_dir: &Path, layer: &str) -> Result<BTreeMap<String, String>, Error> {
    let mut files = BTreeMap::new();
    if plain_relative(layer).is_none() || layer.contains('/') {
        return Ok(files);
    }
    let root = setups_dir.join(layer);
    if !root.is_dir() {
        return Ok(files);
    }
    let mut pending = vec![root.clone()];
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(&dir)? {
            let path = entry?.path();
            if path.is_dir() {
                pending.push(path);
                continue;
            }
            let Ok(relative) = path.strip_prefix(&root) else { continue };
            let text = String::from_utf8(std::fs::read(&path)?).map_err(|_| {
                Error::Setup(format!("{layer}/{} is not a text file", relative.display()))
            })?;
            files.insert(relative.to_string_lossy().replace('\\', "/"), text);
        }
    }
    Ok(files)
}

/// Puts layer `layer`'s folder back holding exactly `files` (paths inside
/// it, from [`read_layer`]), whole: into a folder of its own first.
pub fn put_layer(
    setups_dir: &Path,
    layer: &str,
    files: &BTreeMap<String, String>,
) -> Result<(), Error> {
    if plain_relative(layer).is_none() || layer.contains('/') {
        return Err(Error::Setup(format!("{layer:?} is not a layer folder name")));
    }
    let fresh = setups_dir.join(format!(".{layer}.new"));
    remove_dir(&fresh)?;
    for (inner, text) in files {
        let relative = plain_relative(inner)
            .ok_or_else(|| Error::Setup(format!("{inner} is not a plain path in {layer}")))?;
        let file = fresh.join(relative);
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&file, text)?;
    }
    let live = setups_dir.join(layer);
    remove_dir(&live)?;
    if files.is_empty() {
        return Ok(());
    }
    std::fs::rename(&fresh, &live)?;
    Ok(())
}

fn remove_dir(dir: &Path) -> Result<(), Error> {
    match std::fs::remove_dir_all(dir) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
        _ => Ok(()),
    }
}

/// A layer folder set aside while its setup is updated (`stash`).
#[derive(Debug)]
pub struct Stash {
    live: PathBuf,
    aside: PathBuf,
}

/// Moves layer `layer`'s folder aside, to put back with [`restore_stash`]
/// if the update fails, or delete with [`drop_stash`] once it went on.
pub fn stash(setups_dir: &Path, layer: Option<&str>) -> Result<Option<Stash>, Error> {
    let Some(layer) = layer.filter(|layer| plain_relative(layer).is_some()) else {
        return Ok(None);
    };
    let live = setups_dir.join(layer);
    if !live.is_dir() {
        return Ok(None);
    }
    let aside = setups_dir.join(format!(".{layer}.stash"));
    remove_dir(&aside)?;
    std::fs::rename(&live, &aside)?;
    Ok(Some(Stash { live, aside }))
}

pub fn restore_stash(stash: Option<Stash>) -> Result<(), Error> {
    let Some(stash) = stash else { return Ok(()) };
    remove_dir(&stash.live)?;
    std::fs::rename(&stash.aside, &stash.live)?;
    Ok(())
}

pub fn drop_stash(stash: Option<Stash>) {
    if let Some(stash) = stash {
        let _ = remove_dir(&stash.aside);
    }
}

/// Writes `layers.json` from `receipts` (top first): every one that is on
/// and has views. With none, the file goes (an empty setups folder too).
pub fn write_index(setups_dir: &Path, receipts: &[Receipt]) -> Result<(), Error> {
    let layers: Vec<IndexRow> = receipts
        .iter()
        .filter(|receipt| receipt.on)
        .filter_map(|receipt| {
            let dir = receipt.layer.clone()?;
            Some(IndexRow { id: receipt.id.clone(), app: format!("local/{dir}"), dir })
        })
        .collect();
    let file = setups_dir.join(INDEX_FILE);
    if layers.is_empty() && receipts.iter().all(|receipt| receipt.layer.is_none()) {
        return match std::fs::remove_file(&file) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        };
    }
    std::fs::create_dir_all(setups_dir)?;
    let index = Index { format: INDEX_FORMAT, layers };
    let mut text = serde_json::to_string_pretty(&index).map_err(std::io::Error::other)?;
    text.push('\n');
    cmux_config::fsio::write_atomic(&file, text.as_bytes())?;
    Ok(())
}

/// The index as it is (`None`: no file, or one that does not read).
pub fn read_index(setups_dir: &Path) -> Option<Index> {
    let text = std::fs::read_to_string(setups_dir.join(INDEX_FILE)).ok()?;
    serde_json::from_str(&text).ok()
}
