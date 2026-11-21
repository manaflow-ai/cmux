//! Font files the agent chat declares (`agentPane.display.font.faces`), so a
//! theme can ship the faces its `agentPane.display.font.uiFamily` and
//! `font.proseFamily` name. Port of Swift `ChatFontFaces` (CmuxNextSettings):
//! the CLI's `cmux theme check`, the daemon and the phone check a face as the
//! Mac app loads it.
//!
//! The setting is a map: key = family name, optionally suffixed `:italic`;
//! value = `file:PATH`. In a theme file a relative path resolves against the
//! themes folder (`file:../fonts/x.woff2` from `themes/NAME.json`), as a
//! backdrop picture does. A face is a plain file (no symlink) of at most
//! [`MAX_FACE_BYTES`], with a `woff2`, `woff`, `ttf` or `otf` extension that
//! matches its first bytes; at most [`MAX_FACES`] are read. Each becomes a
//! `data:font/<kind>;base64,...` URL for the chat page, which declares it as
//! an `@font-face`. A bad entry is skipped with a problem naming it; the rest
//! still apply.

use std::io::Read;
use std::path::{Path, PathBuf};

use base64::Engine;
use serde_json::{Map, Value};

/// The setting that holds the faces.
pub const SETTING_KEY: &str = "agentPane.display.font.faces";
/// The most faces one map declares; entries past it (in key order) are skipped.
pub const MAX_FACES: usize = 8;
/// The most one face file may be: 2 MiB.
pub const MAX_FACE_BYTES: u64 = 2 << 20;
/// The one key suffix a face may carry.
pub const ITALIC_SUFFIX: &str = ":italic";
/// The value prefix of a face file.
pub const FILE_PREFIX: &str = "file:";
/// The face file types, by extension.
pub const EXTENSIONS: [&str; 4] = ["woff2", "woff", "ttf", "otf"];
/// Characters a face's family may not hold beyond what
/// [`crate::text::is_valid_font_family`] refuses: one family, never a stack,
/// and nothing that ends a CSS string or block.
const FAMILY_REFUSED: [char; 8] = [',', ';', '{', '}', '\\', '\'', '<', '>'];

/// A face file's type, from its first bytes: `woff2` (`wOF2`), `woff`
/// (`wOFF`), `ttf` (`00 01 00 00` or `true`) or `otf` (`OTTO`).
pub fn font_kind(bytes: &[u8]) -> Option<&'static str> {
    match bytes.get(..4)? {
        b"wOF2" => Some("woff2"),
        b"wOFF" => Some("woff"),
        [0, 1, 0, 0] | b"true" => Some("ttf"),
        b"OTTO" => Some("otf"),
        _ => None,
    }
}

/// The face type an extension names (case-insensitive), if a face may have it.
pub fn extension_kind(extension: &str) -> Option<&'static str> {
    let lower = extension.to_ascii_lowercase();
    EXTENSIONS.into_iter().find(|kind| *kind == lower)
}

/// One key of the map read: the family and whether it is the italic face.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FaceKey {
    pub family: String,
    pub italic: bool,
}

/// `key` as a family and style: a valid family name, optionally `:italic`.
pub fn parse_key(key: &str) -> Result<FaceKey, String> {
    let (family, italic) = match key.rsplit_once(':') {
        Some((family, suffix)) if format!(":{suffix}") == ITALIC_SUFFIX => (family, true),
        Some(_) => return Err(format!("the only key suffix is {ITALIC_SUFFIX}")),
        None => (key, false),
    };
    let family = crate::text::trim_whitespaces(family);
    if !crate::text::is_valid_font_family(family) || family.contains(FAMILY_REFUSED) {
        return Err("expected one font family name, such as \"Inter Display\"".to_string());
    }
    Ok(FaceKey { family: family.to_string(), italic })
}

/// The file a face value names: `file:` and an absolute path, or one at `~`.
pub fn face_path(value: &Value) -> Result<PathBuf, String> {
    let raw = value.as_str().ok_or("expected \"file:PATH\"")?;
    let rest = raw.strip_prefix(FILE_PREFIX).ok_or("expected \"file:PATH\"")?;
    if let Some(after) = rest.strip_prefix('~')
        && (after.is_empty() || after.starts_with('/'))
    {
        let home = std::env::var("HOME").unwrap_or_default();
        return Ok(PathBuf::from(format!("{home}{after}")));
    }
    if !rest.starts_with('/') {
        return Err("expected an absolute path, one at ~, or (in a theme file) one relative to the themes folder".into());
    }
    Ok(PathBuf::from(rest))
}

/// A face file checked without reading all of it: its path and type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckedFace {
    pub key: FaceKey,
    pub path: PathBuf,
    pub kind: &'static str,
    pub bytes: u64,
}

/// Checks one entry: its key, and the file it names (a plain file, not a
/// symlink, within [`MAX_FACE_BYTES`], whose extension matches its first
/// bytes). Reads only the first four bytes.
pub fn check(key: &str, value: &Value) -> Result<CheckedFace, String> {
    let key = parse_key(key)?;
    let path = face_path(value)?;
    let (kind, bytes) = check_file(&path)?;
    Ok(CheckedFace { key, path, kind, bytes })
}

fn check_file(path: &Path) -> Result<(&'static str, u64), String> {
    let shown = path.display();
    let meta = std::fs::symlink_metadata(path).map_err(|_| format!("there is no file {shown}"))?;
    if meta.file_type().is_symlink() {
        return Err(format!("{shown} is a symbolic link; a face must be a plain file"));
    }
    if !meta.is_file() {
        return Err(format!("{shown} is not a file"));
    }
    if meta.len() > MAX_FACE_BYTES {
        return Err(format!("{shown} is larger than {} MiB", MAX_FACE_BYTES >> 20));
    }
    let named = path
        .extension()
        .and_then(|ext| ext.to_str())
        .and_then(extension_kind)
        .ok_or_else(|| format!("{shown}: expected a .woff2, .woff, .ttf or .otf file"))?;
    let mut head = [0u8; 4];
    std::fs::File::open(path)
        .and_then(|mut file| file.read_exact(&mut head))
        .map_err(|_| format!("{shown} could not be read"))?;
    match font_kind(&head) {
        Some(kind) if kind == named => Ok((kind, meta.len())),
        Some(kind) => Err(format!("{shown} is a {kind} file, not .{named}")),
        None => Err(format!("{shown} is not a font file")),
    }
}

/// One face ready for the page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Face {
    /// The map key as the page reads it: `Family` or `Family:italic`.
    pub key: String,
    /// `data:font/<kind>;base64,...`.
    pub data_url: String,
}

/// The `data:` URL of a face file's bytes of type `kind`.
pub fn data_url(kind: &str, bytes: &[u8]) -> String {
    format!("data:font/{kind};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes))
}

/// Reads one entry as a face: [`check`], then the whole file.
pub fn load(key: &str, value: &Value) -> Result<Face, String> {
    let checked = check(key, value)?;
    let bytes = std::fs::read(&checked.path)
        .map_err(|_| format!("{} could not be read", checked.path.display()))?;
    // The file may have changed between the check and the read.
    if bytes.len() as u64 > MAX_FACE_BYTES || font_kind(&bytes) != Some(checked.kind) {
        return Err(format!("{} changed while it was read", checked.path.display()));
    }
    Ok(Face { key: face_key(&checked.key), data_url: data_url(checked.kind, &bytes) })
}

/// The page's key of a face: the trimmed family, with `:italic` for the italic face.
pub fn face_key(key: &FaceKey) -> String {
    if key.italic { format!("{}{ITALIC_SUFFIX}", key.family) } else { key.family.clone() }
}

/// One problem with an entry: its key and what is wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FaceProblem {
    pub key: String,
    pub message: String,
}

/// Runs `each` over the entries of `map` in key order, at most [`MAX_FACES`]
/// of them; the rest are problems.
fn each_entry<T>(
    map: &Map<String, Value>,
    mut each: impl FnMut(&str, &Value) -> Result<T, String>,
) -> (Vec<T>, Vec<FaceProblem>) {
    let mut keys: Vec<&String> = map.keys().collect();
    keys.sort();
    let mut done = Vec::new();
    let mut problems = Vec::new();
    for (index, key) in keys.into_iter().enumerate() {
        if index >= MAX_FACES {
            problems.push(FaceProblem {
                key: key.clone(),
                message: format!("at most {MAX_FACES} faces; this one is skipped"),
            });
            continue;
        }
        match each(key, &map[key]) {
            Ok(value) => done.push(value),
            Err(message) => problems.push(FaceProblem { key: key.clone(), message }),
        }
    }
    (done, problems)
}

/// Checks every entry of a faces map without reading the files whole.
pub fn check_all(map: &Map<String, Value>) -> (Vec<CheckedFace>, Vec<FaceProblem>) {
    each_entry(map, check)
}

/// Loads every good entry of a faces map; the bad ones are problems.
pub fn load_all(map: &Map<String, Value>) -> (Vec<Face>, Vec<FaceProblem>) {
    each_entry(map, load)
}

#[cfg(test)]
mod tests;
