//! Resolve opt-in file sources once at the import boundary. The model, saved
//! profiles and library layers continue to hold portable inline text.
use std::fs;
use std::io::Read;
use std::path::Path;

use cmux_app_manifest::module_store::validate_module_path;
use serde_json::Value;

use crate::tree::MAX_FILE_BYTES;

pub(crate) fn resolve(value: &mut Value, root: &Path) -> Result<(), String> {
    let Some(files) = value.get_mut("files").and_then(Value::as_object_mut) else {
        return Ok(());
    };
    for (logical, entry) in files {
        if entry.is_string() {
            continue;
        }
        let reference = entry
            .as_object()
            .filter(|object| object.len() == 1)
            .and_then(|object| object.get("$file"))
            .and_then(Value::as_str)
            .ok_or_else(|| {
                format!("{logical}: expected text or {{\"$file\":\"relative/path\"}}")
            })?;
        // Reuse the package path contract: bounded relative paths, no parent,
        // absolute, platform-prefix or hidden-control spellings.
        validate_module_path(reference)
            .map_err(|_| format!("{logical}: $file must be a relative package file path"))?;
        let mut file = root.to_path_buf();
        for component in reference.split('/') {
            file.push(component);
            let metadata = fs::symlink_metadata(&file)
                .map_err(|_| format!("{logical}: $file cannot be read"))?;
            // As with setup repo files, links at any depth are not sources.
            if metadata.file_type().is_symlink() {
                return Err(format!("{logical}: $file is a link; use a plain file"));
            }
        }
        let metadata =
            fs::symlink_metadata(&file).map_err(|_| format!("{logical}: $file cannot be read"))?;
        if !metadata.is_file() || metadata.len() > MAX_FILE_BYTES {
            return Err(format!("{logical}: $file must be a plain text file at most 2 MiB"));
        }
        let opened =
            fs::File::open(&file).map_err(|_| format!("{logical}: $file cannot be read"))?;
        let mut bytes = Vec::new();
        // Bound the read itself, including a file that grows after metadata.
        opened
            .take(MAX_FILE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| format!("{logical}: $file cannot be read"))?;
        if bytes.len() as u64 > MAX_FILE_BYTES {
            return Err(format!("{logical}: $file is larger than 2 MiB"));
        }
        let text =
            String::from_utf8(bytes).map_err(|_| format!("{logical}: $file is not UTF-8 text"))?;
        *entry = Value::String(text);
    }
    Ok(())
}
