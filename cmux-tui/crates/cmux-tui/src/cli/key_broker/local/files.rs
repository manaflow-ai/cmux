//! `write`: a key copied into a store, a 0600 file, a JSON or TOML field, or an env file.

use std::io::{Read as _, Write as _};

use super::*;

/// Writes `bytes` to `path` as a new 0600 file, through a temporary file and a rename, so a
/// reader sees the old file or the new one. A symlink or folder at `path` is refused: the value
/// would land somewhere the agent did not name.
pub(super) fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt as _;
    if let Ok(meta) = std::fs::symlink_metadata(path)
        && !meta.file_type().is_file()
    {
        return Err(format!(
            "{} is not a plain file (a link or a folder): not written",
            path.display()
        ));
    }
    let folder = path.parent().ok_or_else(|| format!("{} has no folder", path.display()))?;
    std::fs::create_dir_all(folder)
        .map_err(|e| format!("cannot make {}: {e}", folder.display()))?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("key");
    let temporary = folder.join(format!(".{name}.cmux-keys.{}", std::process::id()));
    let _ = std::fs::remove_file(&temporary);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    let written = file.write_all(bytes).and_then(|()| file.sync_all());
    drop(file);
    if let Err(e) = written.and_then(|()| std::fs::rename(&temporary, path)) {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("cannot write {}: {e}", path.display()));
    }
    Ok(())
}

pub(super) fn read_existing(path: &Path) -> Result<Option<Zeroizing<String>>, String> {
    match std::fs::File::open(path) {
        Ok(mut file) => {
            let mut text = Zeroizing::new(String::new());
            file.read_to_string(&mut text)
                .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
            Ok(Some(text))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("cannot read {}: {e}", path.display())),
    }
}

/// `text` (a JSON file, or none) with `field` set to `value`.
pub(super) fn set_json(
    text: Option<&str>,
    field: &[String],
    value: &str,
) -> Result<Zeroizing<String>, String> {
    let mut root: Value = match text {
        Some(text) if !text.trim().is_empty() => serde_json::from_str(text)
            .map_err(|_| "the file is not JSON: not written".to_owned())?,
        _ => json!({}),
    };
    let mut at = &mut root;
    for part in field {
        let Some(fields) = at.as_object_mut() else {
            return Err(format!("{part:?}'s parent is not an object: not written"));
        };
        at = fields.entry(part.clone()).or_insert_with(|| json!({}));
    }
    *at = json!(value);
    let mut out = serde_json::to_string_pretty(&root).map_err(|e| e.to_string())?;
    out.push('\n');
    Ok(Zeroizing::new(out))
}

/// `text` (a TOML file, or none) with `field` set to `value`, every other line kept as it was.
pub(super) fn set_toml(
    text: Option<&str>,
    field: &[String],
    value: &str,
) -> Result<Zeroizing<String>, String> {
    let mut doc: toml_edit::DocumentMut =
        text.unwrap_or("").parse().map_err(|_| "the file is not TOML: not written".to_owned())?;
    let (last, parents) = field.split_last().ok_or("no field")?;
    let mut table = doc.as_table_mut();
    for part in parents {
        let entry =
            table.entry(part).or_insert_with(|| toml_edit::Item::Table(toml_edit::Table::new()));
        table =
            entry.as_table_mut().ok_or_else(|| format!("{part:?} is not a table: not written"))?;
    }
    table.insert(last, toml_edit::value(value));
    Ok(Zeroizing::new(doc.to_string()))
}

/// `text` (an env file, or none) with the line of `var` set to `value` (added when missing).
pub(super) fn set_env_line(text: Option<&str>, var: &str, value: &str) -> Zeroizing<String> {
    let plain = value.chars().all(|c| c.is_ascii_alphanumeric() || "_-./+=:@,".contains(c));
    let quoted = if plain {
        value.to_owned()
    } else {
        let escaped = value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('$', "\\$")
            .replace('`', "\\`")
            .replace('\n', "\\n");
        format!("\"{escaped}\"")
    };
    let line = format!("{var}={quoted}");
    let mut out = String::new();
    let mut found = false;
    for existing in text.unwrap_or("").lines() {
        let bare = existing.trim_start().strip_prefix("export ").unwrap_or(existing.trim_start());
        if bare.split_once('=').is_some_and(|(k, _)| k.trim() == var) {
            if !found {
                out.push_str(&line);
                out.push('\n');
            }
            found = true;
        } else {
            out.push_str(existing);
            out.push('\n');
        }
    }
    if !found {
        out.push_str(&line);
        out.push('\n');
    }
    Zeroizing::new(out)
}

/// The audit's name of a target.
pub(super) fn target_label(target: &Target) -> String {
    match target {
        Target::Store(store) => store.spot(),
        Target::File(path) => format!("file:{}", path.display()),
        Target::Json(path, field) => format!("json:{}#{}", path.display(), field.join(".")),
        Target::Toml(path, field) => format!("toml:{}#{}", path.display(), field.join(".")),
        Target::EnvFile(path, var) => format!("env-file:{}#{var}", path.display()),
    }
}

/// Copies key `name` into each target, recording each; stops at the first that fails.
pub(in crate::cli) fn write(
    paths: &Paths,
    vault: &dyn KeyVault,
    sinks: &dyn Sinks,
    name: &str,
    targets: &[Target],
) -> Result<Value, String> {
    let (record, value) = value_of(paths, vault, name)?;
    let hosts = hosts_of(&record);
    let mut written = Vec::new();
    for target in targets {
        let label = target_label(target);
        let outcome = match target {
            Target::Store(store) => {
                let store = store.clone().with_hosts(&hosts);
                sinks.put(&store, &store.name(""), &value)
            }
            Target::File(path) => write_private(path, value.as_bytes()),
            Target::Json(path, field) => read_existing(path)
                .and_then(|old| set_json(old.as_deref().map(|s| s.as_str()), field, &value))
                .and_then(|text| write_private(path, text.as_bytes())),
            Target::Toml(path, field) => read_existing(path)
                .and_then(|old| set_toml(old.as_deref().map(|s| s.as_str()), field, &value))
                .and_then(|text| write_private(path, text.as_bytes())),
            Target::EnvFile(path, var) => read_existing(path)
                .map(|old| set_env_line(old.as_deref().map(|s| s.as_str()), var, &value))
                .and_then(|text| write_private(path, text.as_bytes())),
        };
        if let Err(message) = outcome {
            return Err(format!(
                "{}\nwritten before it: {}",
                mask_text(&message, &[&value]),
                if written.is_empty() { "nothing".to_owned() } else { written.join(", ") }
            ));
        }
        record_copy(paths, name, &label)?;
        written.push(label);
    }
    Ok(json!({"key": name, "written": written}))
}

pub(super) fn record_copy(paths: &Paths, name: &str, label: &str) -> Result<(), String> {
    record(paths, name, label, true)
}
