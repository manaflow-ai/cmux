//! Setting a harness's icon (user 12922): `cmux harness icon ID VALUE`,
//! `cmux harness add … --icon VALUE` and Settings' `_acpmux/harness/icon`
//! all run [`set_icon`]. It edits only a profile in the user's harness folder:
//! the top-level `icon = …` line, and for an image a copy of the file next to
//! the profile (`<id>.png` / `<id>.svg`), so the profile folder stays
//! self-contained. The value forms are `config::harness_icon::IconValue`'s.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::config::harness_icon::{self, IconValue, MAX_ICON_BYTES};
use crate::config::profiles::{self, ProfileSources};
use crate::harness_admin::AdminError;

/// What to set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IconChange {
    /// An emoji, SF Symbol name or agent mark id; or a path to an image file,
    /// which is copied next to the profile.
    Value(String),
    /// Image bytes (Settings' file chooser): `ext` is `png` or `svg`.
    Image { bytes: Vec<u8>, ext: String },
    /// Remove the `icon` line: cmux picks the icon again.
    Clear,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IconSet {
    pub id: String,
    pub path: PathBuf,
    /// The `icon` value now in the file; None after a clear.
    pub icon: Option<String>,
}

/// Sets harness `id`'s icon in its user profile file.
pub fn set_icon(
    id: &str,
    change: IconChange,
    sources: &ProfileSources,
) -> Result<IconSet, AdminError> {
    if !profiles::valid_id(id) {
        return Err(AdminError::Invalid(format!("{id:?} is not a harness id")));
    }
    let dir = sources.user_dir.clone().ok_or_else(|| {
        AdminError::Failed("no harness folder: set HOME or XDG_CONFIG_HOME".into())
    })?;
    let path = dir.join(format!("{id}.toml"));
    if !path.is_file() {
        return Err(AdminError::NotFound(format!(
            "no harness profile {id} in your harness folder; only your own profiles take an icon \
             here (add one with `cmux harness add {id} --command PROGRAM`)"
        )));
    }
    let text = std::fs::read_to_string(&path).map_err(|e| AdminError::Failed(e.to_string()))?;
    let previous = top_level_icon(&text);
    let icon = match change {
        IconChange::Clear => None,
        IconChange::Image { bytes, ext } => Some(copy_image(&dir, id, &ext, &bytes)?),
        IconChange::Value(raw) => match IconValue::parse(&raw).map_err(AdminError::Invalid)? {
            IconValue::File(file) => {
                let source = Path::new(&file);
                let ext = source
                    .extension()
                    .map(|x| x.to_string_lossy().to_lowercase())
                    .unwrap_or_default();
                // A file already in the harness folder is used where it is.
                if source.parent().is_none_or(|p| p.as_os_str().is_empty())
                    && dir.join(source).is_file()
                {
                    harness_icon::read_icon_file(&path, &file).map_err(AdminError::Invalid)?;
                    Some(file)
                } else {
                    let meta = std::fs::metadata(source).map_err(|_| {
                        AdminError::Invalid(format!("icon file {file:?} is missing"))
                    })?;
                    if !meta.is_file() || meta.len() > MAX_ICON_BYTES {
                        return Err(AdminError::Invalid(format!(
                            "icon {file:?} must be a file of at most {MAX_ICON_BYTES} bytes"
                        )));
                    }
                    let bytes =
                        std::fs::read(source).map_err(|e| AdminError::Failed(e.to_string()))?;
                    Some(copy_image(&dir, id, &ext, &bytes)?)
                }
            }
            value => Some(value.wire()),
        },
    };
    let written = with_icon(&text, icon.as_deref());
    crate::config::write_atomic(&path, written.as_bytes())
        .map_err(|e| AdminError::Failed(format!("{e:#}")))?;
    // The copy this command made for the old icon, when no longer named.
    if let Some(old) = previous.filter(|old| Some(old) != icon.as_ref())
        && is_own_copy(id, &old)
    {
        let _ = std::fs::remove_file(dir.join(old));
    }
    Ok(IconSet { id: id.to_owned(), path, icon })
}

/// `<id>.png` / `<id>.svg`: the name [`copy_image`] gives.
fn is_own_copy(id: &str, name: &str) -> bool {
    name == format!("{id}.png") || name == format!("{id}.svg")
}

/// Writes `bytes` as `<dir>/<id>.<ext>` (owner-only) after checking them.
fn copy_image(dir: &Path, id: &str, ext: &str, bytes: &[u8]) -> Result<String, AdminError> {
    let mime = match ext {
        "png" => "image/png",
        "svg" => "image/svg+xml",
        _ => return Err(AdminError::Invalid(format!("an icon image is .png or .svg, not .{ext}"))),
    };
    if bytes.len() as u64 > MAX_ICON_BYTES {
        return Err(AdminError::Invalid(format!(
            "the icon image is {} bytes; at most {MAX_ICON_BYTES}",
            bytes.len()
        )));
    }
    harness_icon::check_image_bytes(mime, bytes).map_err(AdminError::Invalid)?;
    let name = format!("{id}.{ext}");
    crate::config::write_atomic(&dir.join(&name), bytes)
        .map_err(|e| AdminError::Failed(format!("{e:#}")))?;
    Ok(name)
}

/// The top-level `icon = "…"` value of a profile file, if any.
fn top_level_icon(text: &str) -> Option<String> {
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with('[') {
            return None;
        }
        if let Some(rest) = t.strip_prefix("icon") {
            let rest = rest.trim_start();
            if let Some(value) = rest.strip_prefix('=') {
                return toml::from_str::<toml::Value>(&format!("v = {}", value.trim()))
                    .ok()
                    .and_then(|v| v.get("v").and_then(|v| v.as_str()).map(str::to_owned));
            }
        }
    }
    None
}

/// `text` with its top-level `icon` line set to `icon` (or removed for None).
/// A new line goes after `name` (else `id`), before any table.
pub fn with_icon(text: &str, icon: Option<&str>) -> String {
    let line = icon.map(|i| format!("icon = {}", serde_json::to_string(i).unwrap_or_default()));
    let mut out = String::with_capacity(text.len() + 32);
    let mut top = true;
    let mut placed = line.is_none();
    let mut anchor: Option<usize> = None;
    let mut lines: Vec<String> = Vec::new();
    for raw in text.lines() {
        let t = raw.trim_start();
        if t.starts_with('[') {
            top = false;
        }
        let is_icon =
            top && t.strip_prefix("icon").is_some_and(|r| r.trim_start().starts_with('='));
        if is_icon {
            if let Some(line) = &line
                && !placed
            {
                lines.push(line.clone());
                placed = true;
            }
            continue;
        }
        lines.push(raw.to_owned());
        let key = |k: &str| t.strip_prefix(k).is_some_and(|r| r.trim_start().starts_with('='));
        if top && (key("name") || (key("id") && anchor.is_none())) {
            anchor = Some(lines.len());
        }
    }
    if !placed && let Some(line) = line {
        let at = anchor.unwrap_or_else(|| {
            lines.iter().position(|l| l.trim_start().starts_with('[')).unwrap_or(lines.len())
        });
        lines.insert(at, line);
    }
    for l in lines {
        out.push_str(&l);
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_icon_line_is_set_replaced_and_removed_at_the_top_level_only() {
        let base = "schema = 1\nid = \"a\"\nname = \"A\"\ncommand = \"a\"\n\n[env]\nicon = \"x\"\n";
        let set = with_icon(base, Some("🦊"));
        assert_eq!(
            set,
            "schema = 1\nid = \"a\"\nname = \"A\"\nicon = \"🦊\"\ncommand = \"a\"\n\n[env]\nicon = \"x\"\n"
        );
        assert_eq!(top_level_icon(&set).as_deref(), Some("🦊"));
        let replaced = with_icon(&set, Some("hammer.fill"));
        assert!(replaced.contains("icon = \"hammer.fill\"\ncommand"), "{replaced}");
        assert_eq!(replaced.matches("icon = ").count(), 2, "{replaced}");
        assert_eq!(with_icon(&replaced, None), base);
        assert_eq!(top_level_icon(base), None);
        // No name line: after id.
        assert_eq!(
            with_icon("id = \"b\"\ncommand = \"b\"\n", Some("x")),
            "id = \"b\"\nicon = \"x\"\ncommand = \"b\"\n"
        );
    }
}
