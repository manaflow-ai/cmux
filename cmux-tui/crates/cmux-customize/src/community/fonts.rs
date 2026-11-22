//! A theme repository's font pack: font files in `fonts/` beside `themes/`,
//! the way it carries `wallpapers/`, for the agent chat's
//! `agentPane.display.font.faces` (a community typography theme).
//!
//! Only openly licensed fonts: a theme that carries font files declares
//! `"fontLicense"` (`OFL-1.1`, `Apache-2.0` or `MIT`) in `cmux-theme.json`
//! and includes the license text as `fonts/OFL.txt` or `fonts/LICENSE*`.
//! Each face follows `cmux_config::font_faces`: at most
//! [`font_faces::MAX_FACES`] files of at most [`font_faces::MAX_FACE_BYTES`],
//! `woff2`, `woff`, `ttf` or `otf`, the extension matching the first bytes.
//!
//! Install copies the files to `<config dir>/fonts/<entry>/` and rewrites a
//! theme file's `file:../fonts/NAME` face values to
//! `file:../fonts/<entry>/NAME`, so two themes' fonts never mix.

use std::io::Read as _;
use std::path::{Path, PathBuf};

use cmux_config::{font_faces, jsonc};
use serde_json::Value;

use super::art::{self, Staged};
use crate::Error;

/// The folder beside `themes/` the fonts are read from and copied into.
pub const FONTS: &str = "fonts";
/// The licenses a theme's fonts may carry (`"fontLicense"`).
pub const LICENSES: &[&str] = &["OFL-1.1", "Apache-2.0", "MIT"];
/// The most license files one theme carries.
pub const MAX_LICENSE_FILES: usize = 4;
/// The most one license text may be.
pub const MAX_LICENSE_BYTES: u64 = 256 * 1024;

/// The font pack a theme repository carries.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Fonts {
    /// Repository-relative font files (`fonts/PackSans.woff2`), each checked.
    pub files: Vec<String>,
    /// Repository-relative license texts (`fonts/OFL.txt`), copied too.
    pub licenses: Vec<String>,
    /// The marker's `"fontLicense"`.
    pub license: Option<String>,
    /// The fetched tree they are read from.
    pub source: PathBuf,
}

fn refuse(why: impl Into<String>) -> Error {
    Error::Community(why.into())
}

/// The file name of `path` when it is a plain `fonts/NAME` (one level).
fn plain_name(path: &str) -> Option<&str> {
    let name = path.strip_prefix("fonts/")?;
    let plain = !name.is_empty()
        && !name.contains(['/', '\\'])
        && !name.starts_with('.')
        && Path::new(name).file_name().is_some_and(|n| n == name);
    plain.then_some(name)
}

/// Whether `path` is `fonts/NAME.woff2|woff|ttf|otf`.
pub fn is_font_path(path: &str) -> bool {
    plain_name(path)
        .and_then(|name| name.rsplit_once('.'))
        .is_some_and(|(_, ext)| font_faces::extension_kind(ext).is_some())
}

/// Whether `path` is a license text a font pack carries: `fonts/OFL.txt`
/// or `fonts/LICENSE*` (any case).
pub fn is_license_path(path: &str) -> bool {
    plain_name(path).is_some_and(|name| {
        let lower = name.to_ascii_lowercase();
        lower == "ofl.txt" || lower.starts_with("license")
    })
}

/// Whether a theme install reads `path`: a font file or a license text.
pub fn is_fonts_path(path: &str) -> bool {
    is_font_path(path) || is_license_path(path)
}

/// The `"fontLicense"` the marker declares, checked.
fn license(header: &Value) -> Result<Option<String>, Error> {
    match header.get("fontLicense") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(id)) if LICENSES.contains(&id.as_str()) => Ok(Some(id.clone())),
        Some(_) => Err(refuse(format!(
            "cmux-theme.json: \"fontLicense\" is one of {}",
            LICENSES.join(", ")
        ))),
    }
}

/// A plain file of at most `limit` bytes: its length.
fn plain_file(dir: &Path, path: &str, limit: u64, what: &str) -> Result<u64, Error> {
    let metadata = std::fs::symlink_metadata(dir.join(path))
        .map_err(|_| refuse(format!("{path}: not in the repository")))?;
    if !metadata.is_file() {
        return Err(refuse(format!("{path}: not a plain file")));
    }
    if metadata.len() > limit {
        let size = if limit >= 1 << 20 {
            format!("{} MiB", limit >> 20)
        } else {
            format!("{} KiB", limit / 1024)
        };
        return Err(refuse(format!("{path}: larger than {size}, the most {what} may be")));
    }
    Ok(metadata.len())
}

/// Reads and checks the font pack in `dir`'s `fonts/` folder.
pub fn read_fonts(dir: &Path, header: &Value) -> Result<Fonts, Error> {
    let license = license(header)?;
    let mut files = Vec::new();
    let mut licenses = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir.join(FONTS)) {
        for entry in entries.flatten() {
            let path = format!("{FONTS}/{}", entry.file_name().to_string_lossy());
            if is_font_path(&path) {
                files.push(path);
            } else if is_license_path(&path) {
                licenses.push(path);
            }
        }
    }
    files.sort();
    licenses.sort();
    if files.is_empty() {
        return Ok(Fonts { files, licenses: Vec::new(), license, source: dir.to_path_buf() });
    }
    if files.len() > font_faces::MAX_FACES {
        return Err(refuse(format!(
            "a theme carries at most {} font files; fonts/ has {}",
            font_faces::MAX_FACES,
            files.len()
        )));
    }
    if license.is_none() {
        return Err(refuse(format!(
            "fonts/: a theme that carries font files declares \"fontLicense\": \"OFL-1.1\" in cmux-theme.json (only {} fonts)",
            LICENSES.join(", ")
        )));
    }
    if licenses.is_empty() {
        return Err(refuse(
            "fonts/: a theme that carries font files includes their license text as fonts/OFL.txt or fonts/LICENSE",
        ));
    }
    if licenses.len() > MAX_LICENSE_FILES {
        return Err(refuse(format!(
            "fonts/: at most {MAX_LICENSE_FILES} license files (OFL.txt, LICENSE*)"
        )));
    }
    for path in &licenses {
        plain_file(dir, path, MAX_LICENSE_BYTES, "a license text")?;
    }
    for path in &files {
        plain_file(dir, path, font_faces::MAX_FACE_BYTES, "a font file")?;
        let mut head = [0u8; 4];
        let read = std::fs::File::open(dir.join(path)).and_then(|mut f| f.read(&mut head))?;
        let named = path
            .rsplit_once('.')
            .and_then(|(_, ext)| font_faces::extension_kind(ext))
            .unwrap_or_default();
        match head.get(..read).and_then(font_faces::font_kind) {
            Some(kind) if kind == named => {}
            Some(kind) => return Err(refuse(format!("{path}: a {kind} file, not .{named}"))),
            None => {
                return Err(refuse(format!(
                    "{path}: not a font file (a theme carries woff2, woff, ttf or otf)"
                )));
            }
        }
    }
    Ok(Fonts { files, licenses, license, source: dir.to_path_buf() })
}

/// Every face entry of a theme file: (key path, face key, value), whether
/// the setting is written dotted, nested, or partly both.
fn faces(root: &serde_json::Map<String, Value>) -> Vec<(Vec<String>, String, Value)> {
    fn walk(
        map: &serde_json::Map<String, Value>,
        path: &[String],
        joined: &str,
        out: &mut Vec<(Vec<String>, String, Value)>,
    ) {
        for (key, value) in map {
            let here = if joined.is_empty() { key.clone() } else { format!("{joined}.{key}") };
            let mut key_path = path.to_vec();
            key_path.push(key.clone());
            let Some(inner) = value.as_object() else { continue };
            if here == font_faces::SETTING_KEY {
                for (face, value) in inner {
                    let mut face_path = key_path.clone();
                    face_path.push(face.clone());
                    out.push((face_path, face.clone(), value.clone()));
                }
            } else if font_faces::SETTING_KEY.starts_with(&format!("{here}.")) {
                walk(inner, &key_path, &here, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(root, &[], "", &mut out);
    out
}

/// `text` (a theme file) with every face value `file:../fonts/NAME` pointed
/// at `file:../fonts/<entry>/NAME`. A face whose key is not one family
/// (optionally `:italic`), or whose value is not one of the theme's own font
/// files, is refused; so are more than [`font_faces::MAX_FACES`] faces.
pub fn rewrite(text: &str, path: &str, entry: &str, fonts: &Fonts) -> Result<String, Error> {
    let Ok(Value::Object(root)) = jsonc::parse(text) else { return Ok(text.to_owned()) };
    let found = faces(&root);
    if found.len() > font_faces::MAX_FACES {
        return Err(refuse(format!(
            "{path}: {} declares at most {} faces",
            font_faces::SETTING_KEY,
            font_faces::MAX_FACES
        )));
    }
    let mut out = text.to_owned();
    for (key_path, face, value) in found {
        let shown = key_path.join(".");
        font_faces::parse_key(&face).map_err(|why| refuse(format!("{path}: {shown}: {why}")))?;
        let target = value
            .as_str()
            .and_then(|v| v.strip_prefix(font_faces::FILE_PREFIX))
            .and_then(|v| v.strip_prefix("../"))
            .filter(|target| is_font_path(target))
            .ok_or_else(|| {
                refuse(format!(
                    "{path}: {shown}: a community theme's face is one of its own font files, \"file:../fonts/NAME.woff2\""
                ))
            })?;
        if !fonts.files.iter().any(|file| file == target) {
            return Err(refuse(format!(
                "{path}: {shown} points at {target}, which is not in the repository's fonts/"
            )));
        }
        let name = target.strip_prefix("fonts/").unwrap_or(target);
        let new = Value::String(format!("{}../{FONTS}/{entry}/{name}", font_faces::FILE_PREFIX));
        out = jsonc::set(&out, &key_path, &new).map_err(|_| {
            refuse(format!("{path}: {shown} could not be pointed at the installed font"))
        })?;
    }
    Ok(out)
}

/// `<config dir>/fonts/<entry>`.
pub fn folder(config_dir: &Path, entry: &str) -> PathBuf {
    config_dir.join(FONTS).join(entry)
}

/// Copies the font files and license texts into `<config dir>/fonts/<entry>/`,
/// replacing what an earlier install put there. `None` when there are none.
pub fn install(config_dir: &Path, entry: &str, fonts: &Fonts) -> Result<Option<Staged>, Error> {
    if fonts.files.is_empty() {
        return Ok(None);
    }
    let files: Vec<(&str, &str)> = fonts
        .files
        .iter()
        .chain(&fonts.licenses)
        .map(|path| (path.as_str(), path.strip_prefix("fonts/").unwrap_or(path)))
        .collect();
    art::install_into(config_dir, FONTS, entry, &fonts.source, &files)
}

/// Deletes the fonts an install copied for `entry`.
pub fn remove(config_dir: &Path, entry: &str) -> Result<bool, Error> {
    art::remove_from(config_dir, FONTS, entry)
}
