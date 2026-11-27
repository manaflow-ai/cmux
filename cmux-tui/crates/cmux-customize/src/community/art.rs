//! A theme repository's art: wallpapers (window, light and dark; per pane),
//! a sidebar header image, and flourishes, as `cmux-theme.json` lists them
//! (Leo, 2026-11-17: "ok i feel like a [character] theme necessarily has to
//! have lots of [character] wallpapers among other flourishes").
//!
//! The window art applies through the backdrop settings cmux already has
//! (`appearance.background`, `backgroundLight`, `backgroundDark`,
//! `backgroundSchedule`): install copies the images to
//! `<config dir>/wallpapers/<entry>/` and rewrites a theme file's
//! `file:../wallpapers/...` and `folder:../wallpapers/...` values to point
//! there, so two themes' art never mix. What cmux has no setting for yet
//! (per-pane art, the header image, accent glow, cursor style, tab-close
//! colors) became settings of their own (schemas/settings/source/appearance.json,
//! Theme Flourishes, and `terminal.cursorStyle` / `terminal.cursorBlink`): install
//! writes them into each theme file it installs ([`with_settings`]), so they
//! apply with that theme file and go when another one is picked. A flourish
//! this cmux does not know is checked as far as it can be and named in
//! [`Art::pending`].

use std::path::{Component, Path, PathBuf};

use cmux_config::jsonc;
use serde_json::Value;

use crate::Error;

/// The most one image may be.
pub const MAX_IMAGE_BYTES: u64 = 8 << 20;
/// The most images one theme carries.
pub const MAX_IMAGES: usize = 64;
/// The most all of a theme's images may be together.
pub const MAX_ART_BYTES: u64 = 48 << 20;
/// The folder beside `themes/` the art is copied into.
pub const WALLPAPERS: &str = "wallpapers";
/// The image types a theme may carry, by extension.
pub const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "webp"];
/// The backdrop settings whose `file:`/`folder:` values point at art.
const BACKDROP_KEYS: &[&str] =
    &["background", "backgroundLight", "backgroundDark", "backdropArt", "backgroundSchedule"];
const CURSOR_STYLES: &[&str] = &["block", "bar", "underline", "block_hollow"];

/// The art a theme repository lists.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Art {
    /// Repository-relative paths (`wallpapers/dark/waves.webp`), each checked.
    pub images: Vec<String>,
    /// The fetched tree they are read from.
    pub source: PathBuf,
    /// What the marker asks for that this cmux has no setting for yet.
    pub pending: Vec<String>,
    /// What the marker asks for that install applies, as marker names
    /// (`flourishes.accentGlow`, `header`, `wallpapers.pane`).
    pub applied: Vec<String>,
    /// The settings the flourishes, header and pane art become, in key order.
    pub settings: Vec<(String, Setting)>,
}

/// One setting a theme's art becomes.
#[derive(Debug, Clone, PartialEq)]
pub enum Setting {
    /// A value as it is.
    Value(Value),
    /// A repository image (`header/dark.webp`): a `file:` picture of the installed copy.
    Picture(String),
    /// Repository images: a list of `file:` pictures of the installed copies.
    Pictures(Vec<String>),
}

/// The color of `mode` (`dark` or `light`) in a checked color value: the
/// string itself, or that mode's member (else the other mode's).
fn mode_color(value: Option<&Value>, mode: &str) -> Option<Value> {
    match value? {
        Value::String(text) => Some(Value::String(text.clone())),
        Value::Object(modes) => {
            let other = if mode == "dark" { "light" } else { "dark" };
            modes.get(mode).or_else(|| modes.get(other)).cloned()
        }
        _ => None,
    }
}

fn refuse(why: impl Into<String>) -> Error {
    Error::Community(why.into())
}

/// The image type `bytes` start with, if one a theme may carry.
pub fn image_kind(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("png")
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("jpeg")
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP".as_slice()) {
        Some("webp")
    } else {
        None
    }
}

/// Whether `path` is a plain repository path under `wallpapers/` or
/// `header/` with an image extension.
pub fn is_art_path(path: &str) -> bool {
    let plain = Path::new(path).components().all(|c| matches!(c, Component::Normal(_)))
        && !path.split('/').any(|piece| piece.is_empty() || piece.starts_with('.'))
        && !path.contains('\\');
    let extension = path.rsplit_once('.').map(|(_, ext)| ext.to_ascii_lowercase());
    plain
        && (path.starts_with("wallpapers/") || path.starts_with("header/"))
        && extension.is_some_and(|ext| IMAGE_EXTENSIONS.contains(&ext.as_str()))
}

fn color(value: &Value, what: &str) -> Result<(), Error> {
    let ok = |text: &str| {
        text.strip_prefix('#').is_some_and(|hex| {
            matches!(hex.len(), 3 | 6 | 8) && hex.chars().all(|c| c.is_ascii_hexdigit())
        })
    };
    let fine = match value {
        Value::String(text) => ok(text),
        Value::Object(modes) => {
            !modes.is_empty()
                && modes.iter().all(|(mode, text)| {
                    matches!(mode.as_str(), "dark" | "light") && text.as_str().is_some_and(ok)
                })
        }
        _ => false,
    };
    if fine {
        Ok(())
    } else {
        Err(refuse(format!(
            "cmux-theme.json: {what} is a color (#rrggbb) or {{\"dark\": ..., \"light\": ...}}"
        )))
    }
}

fn number_in(value: Option<&Value>, low: f64, high: f64, what: &str) -> Result<(), Error> {
    match value {
        None => Ok(()),
        Some(value) if value.as_f64().is_some_and(|n| (low..=high).contains(&n)) => Ok(()),
        Some(_) => Err(refuse(format!("cmux-theme.json: {what} is a number from {low} to {high}"))),
    }
}

fn path_list(value: Option<&Value>, what: &str) -> Result<Vec<String>, Error> {
    match value {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::String(one)) => Ok(vec![one.clone()]),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| {
                item.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| refuse(format!("cmux-theme.json: {what} lists image paths")))
            })
            .collect(),
        Some(_) => Err(refuse(format!("cmux-theme.json: {what} lists image paths"))),
    }
}

/// Checks the flourishes, turns those this cmux has settings for into
/// `settings`, and names the others in `pending`.
fn flourishes(
    header: &Value,
    pending: &mut Vec<String>,
    applied: &mut Vec<String>,
    settings: &mut Vec<(String, Setting)>,
) -> Result<(), Error> {
    let mut set = |key: &str, value: Value| settings.push((key.to_owned(), Setting::Value(value)));
    let Some(value) = header.get("flourishes").filter(|v| !v.is_null()) else { return Ok(()) };
    let Some(map) = value.as_object() else {
        return Err(refuse("cmux-theme.json: \"flourishes\" must be an object"));
    };
    for (name, item) in map {
        match name.as_str() {
            "accentGlow" => {
                let glow = item.as_object().ok_or_else(|| {
                    refuse("cmux-theme.json: flourishes.accentGlow must be an object")
                })?;
                for mode in ["dark", "light"] {
                    if let Some(c) = glow.get(mode) {
                        color(c, &format!("flourishes.accentGlow.{mode}"))?;
                    }
                }
                number_in(glow.get("radius"), 0.0, 200.0, "flourishes.accentGlow.radius")?;
                number_in(glow.get("opacity"), 0.0, 1.0, "flourishes.accentGlow.opacity")?;
                let dark = mode_color(glow.get("dark"), "dark");
                let light = mode_color(glow.get("light"), "light");
                // The app draws no glow without a dark color: a light-only glow is both.
                if let Some(dark) = dark.or_else(|| light.clone()) {
                    set("appearance.accentGlow.dark", dark);
                    if let Some(light) = light {
                        set("appearance.accentGlow.light", light);
                    }
                    for part in ["radius", "opacity"] {
                        if let Some(value) = glow.get(part) {
                            set(&format!("appearance.accentGlow.{part}"), value.clone());
                        }
                    }
                }
                applied.push("flourishes.accentGlow".to_owned());
            }
            "cursor" => {
                let cursor = item.as_object().ok_or_else(|| {
                    refuse("cmux-theme.json: flourishes.cursor must be an object")
                })?;
                if let Some(style) = cursor.get("style") {
                    if !style.as_str().is_some_and(|s| CURSOR_STYLES.contains(&s)) {
                        return Err(refuse(format!(
                            "cmux-theme.json: flourishes.cursor.style is one of {}",
                            CURSOR_STYLES.join(", ")
                        )));
                    }
                    set("terminal.cursorStyle", style.clone());
                    applied.push("flourishes.cursor.style".to_owned());
                }
                if let Some(blink) = cursor.get("blink") {
                    if !blink.is_boolean() {
                        return Err(refuse(
                            "cmux-theme.json: flourishes.cursor.blink is true or false",
                        ));
                    }
                    let on = blink.as_bool() == Some(true);
                    set(
                        "terminal.cursorBlink",
                        Value::String(if on { "on" } else { "off" }.to_owned()),
                    );
                    applied.push("flourishes.cursor.blink".to_owned());
                }
                if let Some(c) = cursor.get("color") {
                    // Applied through each theme file's own `colors.cursor`.
                    color(c, "flourishes.cursor.color")?;
                }
            }
            "tabClose" => {
                let close = item.as_object().ok_or_else(|| {
                    refuse("cmux-theme.json: flourishes.tabClose must be an object")
                })?;
                for end in ["from", "to"] {
                    if let Some(c) = close.get(end) {
                        color(c, &format!("flourishes.tabClose.{end}"))?;
                    }
                }
                if let Some(how) = close.get("interpolation")
                    && !matches!(how.as_str(), Some("oklab" | "srgb"))
                {
                    return Err(refuse(
                        "cmux-theme.json: flourishes.tabClose.interpolation is oklab or srgb",
                    ));
                }
                // One resting color: a per-mode `from` rests in its dark color.
                if let Some(from) = mode_color(close.get("from"), "dark") {
                    set("appearance.tabClose.from", from);
                }
                if let Some(to) = mode_color(close.get("to"), "dark") {
                    set("appearance.tabClose.toDark", to);
                }
                if let Some(to) = mode_color(close.get("to"), "light") {
                    set("appearance.tabClose.toLight", to);
                }
                if let Some(how) = close.get("interpolation") {
                    set("appearance.tabClose.interpolation", how.clone());
                }
                applied.push("flourishes.tabClose".to_owned());
            }
            other => pending.push(format!("flourishes.{other}")),
        }
    }
    Ok(())
}

/// Reads and checks the art `header` (the marker) lists, from `dir`.
pub fn read_art(dir: &Path, header: &Value) -> Result<Art, Error> {
    let mut images = Vec::new();
    let mut pending = Vec::new();
    let mut applied = Vec::new();
    let mut settings = Vec::new();
    match header.get("wallpapers") {
        None | Some(Value::Null) => {}
        Some(Value::Object(sets)) => {
            for (set, value) in sets {
                match set.as_str() {
                    "dark" | "light" => {
                        images.extend(path_list(Some(value), &format!("wallpapers.{set}"))?);
                    }
                    "pane" => {
                        let modes = value.as_object().ok_or_else(|| {
                            refuse("cmux-theme.json: wallpapers.pane is {\"dark\": [...], \"light\": [...]}")
                        })?;
                        for (mode, list) in modes {
                            if !matches!(mode.as_str(), "dark" | "light") {
                                return Err(refuse(format!(
                                    "cmux-theme.json: wallpapers.pane.{mode}: only dark and light"
                                )));
                            }
                            let paths = path_list(Some(list), &format!("wallpapers.pane.{mode}"))?;
                            images.extend(paths.iter().cloned());
                            if !paths.is_empty() {
                                settings.push((
                                    format!("appearance.paneArt.{mode}"),
                                    Setting::Pictures(paths),
                                ));
                            }
                        }
                        applied.push("wallpapers.pane".to_owned());
                    }
                    other => {
                        return Err(refuse(format!(
                            "cmux-theme.json: wallpapers.{other}: the sets are dark, light and pane"
                        )));
                    }
                }
            }
        }
        Some(_) => return Err(refuse("cmux-theme.json: \"wallpapers\" must be an object")),
    }
    match header.get("header") {
        None | Some(Value::Null) => {}
        Some(Value::Object(modes)) => {
            for (mode, path) in modes {
                if !matches!(mode.as_str(), "dark" | "light") {
                    return Err(refuse(format!(
                        "cmux-theme.json: header.{mode}: only dark and light"
                    )));
                }
                let paths = path_list(Some(path), &format!("header.{mode}"))?;
                if paths.len() > 1 {
                    return Err(refuse(format!("cmux-theme.json: header.{mode} is one image")));
                }
                if let Some(first) = paths.first() {
                    settings.push((
                        format!("appearance.sidebarHeader.{mode}"),
                        Setting::Picture(first.clone()),
                    ));
                }
                images.extend(paths);
            }
            applied.push("header".to_owned());
        }
        Some(_) => {
            return Err(refuse("cmux-theme.json: \"header\" is {\"dark\": ..., \"light\": ...}"));
        }
    }
    flourishes(header, &mut pending, &mut applied, &mut settings)?;
    settings.sort_by(|a, b| a.0.cmp(&b.0));
    images.sort();
    images.dedup();
    if images.len() > MAX_IMAGES {
        return Err(refuse(format!("a theme carries at most {MAX_IMAGES} images")));
    }
    let mut total: u64 = 0;
    for path in &images {
        if !is_art_path(path) {
            return Err(refuse(format!(
                "{path}: an image is under wallpapers/ or header/, named .png, .jpg or .webp"
            )));
        }
        let file = dir.join(path);
        let metadata = std::fs::symlink_metadata(&file).map_err(|_| {
            refuse(format!("{path}: listed in cmux-theme.json but not in the repository"))
        })?;
        if !metadata.is_file() {
            return Err(refuse(format!("{path}: not a plain file")));
        }
        if metadata.len() > MAX_IMAGE_BYTES {
            return Err(refuse(format!("{path}: larger than {} MiB", MAX_IMAGE_BYTES >> 20)));
        }
        total = total.saturating_add(metadata.len());
        let mut head = [0u8; 12];
        let read = {
            use std::io::Read as _;
            std::fs::File::open(&file).and_then(|mut f| f.read(&mut head))?
        };
        let kind = head.get(..read).and_then(image_kind);
        let extension =
            path.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
        let matches = match kind {
            Some("png") => extension == "png",
            Some("jpeg") => matches!(extension.as_str(), "jpg" | "jpeg"),
            Some("webp") => extension == "webp",
            _ => false,
        };
        if !matches {
            return Err(refuse(format!(
                "{path}: not a {extension} image (a theme carries PNG, JPEG or WebP)"
            )));
        }
    }
    if total > MAX_ART_BYTES {
        return Err(refuse(format!(
            "a theme's images are at most {} MiB together",
            MAX_ART_BYTES >> 20
        )));
    }
    Ok(Art { images, source: dir.to_path_buf(), pending, applied, settings })
}

/// Where a repository image goes under `<config dir>/wallpapers/<entry>/`:
/// `wallpapers/dark/a.webp` to `dark/a.webp`, `header/dark.webp` as it is.
fn installed_path(image: &str) -> &str {
    image.strip_prefix("wallpapers/").unwrap_or(image)
}

/// `text` (a theme file) with every backdrop `file:`/`folder:` value that
/// points into `../wallpapers/` pointed at `../wallpapers/<entry>/` instead.
/// A value that points into `../wallpapers/` at nothing `art` lists is refused.
pub fn rewrite(text: &str, path: &str, entry: &str, art: &Art) -> Result<String, Error> {
    let Ok(Value::Object(root)) = jsonc::parse(text) else { return Ok(text.to_owned()) };
    // (key path, value) of every backdrop value, nested or dotted.
    let mut found: Vec<(Vec<String>, String)> = Vec::new();
    let mut take = |key_path: Vec<String>, value: &Value| match value {
        Value::String(text) => found.push((key_path, text.clone())),
        Value::Object(map) => {
            for (when, value) in map {
                if let Some(text) = value.as_str() {
                    let mut inner = key_path.clone();
                    inner.push(when.clone());
                    found.push((inner, text.to_owned()));
                }
            }
        }
        _ => {}
    };
    for key in BACKDROP_KEYS {
        if let Some(value) = root.get(&format!("appearance.{key}")) {
            take(vec![format!("appearance.{key}")], value);
        }
        if let Some(value) = root.get("appearance").and_then(|a| a.get(*key)) {
            take(vec!["appearance".to_owned(), (*key).to_owned()], value);
        }
    }
    let mut out = text.to_owned();
    for (key_path, value) in found {
        let Some((prefix, rest)) = ["file:", "folder:"]
            .into_iter()
            .find_map(|prefix| value.strip_prefix(prefix).map(|rest| (prefix, rest)))
        else {
            continue;
        };
        let Some(inside) = rest.strip_prefix("../wallpapers/") else { continue };
        let inside = inside.trim_end_matches('/');
        let target = format!("wallpapers/{inside}");
        let listed = match prefix {
            "file:" => art.images.contains(&target),
            _ => art.images.iter().any(|image| image.starts_with(&format!("{target}/"))),
        };
        if !listed || inside.split('/').any(|p| p.is_empty() || p == "." || p == "..") {
            return Err(refuse(format!(
                "{path}: {} points at {target}, which cmux-theme.json's \"wallpapers\" does not list",
                key_path.join(".")
            )));
        }
        let new = Value::String(format!("{prefix}../{WALLPAPERS}/{entry}/{inside}"));
        out = jsonc::set(&out, &key_path, &new).map_err(|_| {
            refuse(format!(
                "{path}: {} could not be pointed at the installed art",
                key_path.join(".")
            ))
        })?;
    }
    Ok(out)
}

/// The settings `art` becomes for the library entry `entry`, a picture as
/// `file:../wallpapers/<entry>/...` (relative to the themes folder, as a theme
/// file's own pictures are).
pub fn settings(art: &Art, entry: &str) -> Vec<(String, Value)> {
    let picture = |image: &str| {
        Value::String(format!("file:../{WALLPAPERS}/{entry}/{}", installed_path(image)))
    };
    art.settings
        .iter()
        .map(|(key, setting)| {
            let value = match setting {
                Setting::Value(value) => value.clone(),
                Setting::Picture(image) => picture(image),
                Setting::Pictures(images) => {
                    Value::Array(images.iter().map(|i| picture(i)).collect())
                }
            };
            (key.clone(), value)
        })
        .collect()
}

/// Whether the theme file object `root` sets `key` (dotted), in any mix of
/// nested and dotted members.
fn sets(root: &serde_json::Map<String, Value>, parts: &[&str]) -> bool {
    (1..=parts.len()).any(|split| {
        let (head, rest) = parts.split_at(split);
        root.get(&head.join(".")).is_some_and(|value| {
            rest.is_empty() || value.as_object().is_some_and(|inner| sets(inner, rest))
        })
    })
}

/// `text` (a theme file) with each of `settings` set, nested, unless the
/// file sets that key itself: the theme file's own value wins.
pub fn with_settings(
    text: &str,
    path: &str,
    settings: &[(String, Value)],
) -> Result<String, Error> {
    let Ok(Value::Object(root)) = jsonc::parse(text) else { return Ok(text.to_owned()) };
    let mut out = text.to_owned();
    for (key, value) in settings {
        let parts: Vec<&str> = key.split('.').collect();
        if sets(&root, &parts) {
            continue;
        }
        let key_path: Vec<String> = parts.iter().map(|part| (*part).to_owned()).collect();
        out = jsonc::set(&out, &key_path, value)
            .map_err(|_| refuse(format!("{path}: could not add {key} from cmux-theme.json")))?;
    }
    Ok(out)
}

/// `<config dir>/wallpapers/<entry>`.
pub fn folder(config_dir: &Path, entry: &str) -> PathBuf {
    config_dir.join(WALLPAPERS).join(entry)
}

/// An art install in progress: the new folder is in place; [`Staged::keep`]
/// drops the one it replaced, dropping this puts that one back.
pub struct Staged {
    dest: PathBuf,
    old: Option<PathBuf>,
    kept: bool,
}

impl Staged {
    pub fn keep(mut self) {
        self.kept = true;
        if let Some(old) = self.old.take() {
            let _ = std::fs::remove_dir_all(old);
        }
    }
}

impl Drop for Staged {
    fn drop(&mut self) {
        if self.kept {
            return;
        }
        let _ = std::fs::remove_dir_all(&self.dest);
        if let Some(old) = self.old.take() {
            let _ = std::fs::rename(old, &self.dest);
        }
    }
}

/// Copies `art` into `<config dir>/wallpapers/<entry>/`, replacing what an
/// earlier install put there. `None` when there is no art.
pub fn install(config_dir: &Path, entry: &str, art: &Art) -> Result<Option<Staged>, Error> {
    let files: Vec<(&str, &str)> =
        art.images.iter().map(|image| (image.as_str(), installed_path(image))).collect();
    install_into(config_dir, WALLPAPERS, entry, &art.source, &files)
}

/// Copies `files` (repository path, path in the folder) from `source` into
/// `<config dir>/<kind>/<entry>/`, replacing what an earlier install put
/// there. `None` when there are no files.
pub(crate) fn install_into(
    config_dir: &Path,
    kind: &str,
    entry: &str,
    source: &Path,
    files: &[(&str, &str)],
) -> Result<Option<Staged>, Error> {
    if files.is_empty() {
        return Ok(None);
    }
    let parent = config_dir.join(kind);
    let dest = parent.join(entry);
    let stage = parent.join(format!(".{entry}.new"));
    let _ = std::fs::remove_dir_all(&stage);
    let copied = files.iter().try_for_each(|(from, to)| {
        let to = stage.join(to);
        if let Some(dir) = to.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::copy(source.join(from), &to).map(drop)
    });
    if let Err(error) = copied {
        let _ = std::fs::remove_dir_all(&stage);
        return Err(error.into());
    }
    let old = if dest.exists() {
        let old = parent.join(format!(".{entry}.old"));
        let _ = std::fs::remove_dir_all(&old);
        std::fs::rename(&dest, &old)?;
        Some(old)
    } else {
        None
    };
    if let Err(error) = std::fs::rename(&stage, &dest) {
        if let Some(old) = &old {
            let _ = std::fs::rename(old, &dest);
        }
        let _ = std::fs::remove_dir_all(&stage);
        return Err(error.into());
    }
    Ok(Some(Staged { dest, old, kept: false }))
}

/// Deletes the art an install copied for `entry`.
pub fn remove(config_dir: &Path, entry: &str) -> Result<bool, Error> {
    remove_from(config_dir, WALLPAPERS, entry)
}

/// Deletes `<config dir>/<kind>/<entry>/`, what an install copied there.
pub(crate) fn remove_from(config_dir: &Path, kind: &str, entry: &str) -> Result<bool, Error> {
    let dest = config_dir.join(kind).join(entry);
    if entry.is_empty() || entry.contains(['/', '\\']) || entry.starts_with('.') || !dest.is_dir() {
        return Ok(false);
    }
    std::fs::remove_dir_all(dest)?;
    Ok(true)
}
