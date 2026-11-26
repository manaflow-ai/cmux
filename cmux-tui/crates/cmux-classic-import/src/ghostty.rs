//! Copy Classic's terminal settings on consent. Ghostty expands paths relative to each
//! configuration file, including when that file is a symlink. Preserve external references
//! and snapshot references into Classic with the layer, so later reloads need only NEXT.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use crate::{
    ledger,
    source::{CHANNELS, Finder},
};

const LAYER: &str = "config.ghostty";

/// The same channel and filename order as Classic. This probe reads only metadata.
pub fn source_path(support: &Path, bundle: &str) -> Option<PathBuf> {
    ledger::directory_in(support, bundle)?;
    let own = Finder::new(support, Some(bundle)).own_channel();
    let mut channels = vec![bundle];
    channels.extend(own.filter(|&id| id != bundle));
    if !channels.contains(&CHANNELS[0]) {
        channels.push(CHANNELS[0]);
    }
    channels
        .into_iter()
        .flat_map(|id| [LAYER, "config"].map(|name| support.join(id).join(name)))
        .find(|file| fs::metadata(file).is_ok_and(|info| info.is_file() && info.len() > 0))
}

/// Publish the whole layer at once. A previous import (including any subsequent edits)
/// wins. An interrupted import never leaves a partially active layer. `classic_config` is
/// Classic's cmux config folder (`$XDG_CONFIG_HOME/cmux`, else under `home`): an include that
/// points into it, or into Classic's other folders, is not copied.
pub fn import(
    home: &Path,
    classic_config: &Path,
    support: &Path,
    bundle: &str,
    config: &Path,
) -> io::Result<()> {
    let destination = config.join("classic-ghostty");
    if destination.try_exists()? {
        return Ok(());
    }
    let Some(source) = source_path(support, bundle) else { return Ok(()) };
    fs::create_dir_all(config)?;
    let stage = tempfile::Builder::new().prefix(".classic-ghostty-").tempdir_in(config)?;
    let mut classic_dirs = vec![
        classic_config.to_path_buf(),
        home.join(".local/state/cmux"),
        support.join("cmux"),
        support.join(bundle),
    ];
    classic_dirs.extend(CHANNELS.map(|id| support.join(id)));
    classic_dirs.extend(
        classic_dirs.iter().filter_map(|path| fs::canonicalize(path).ok()).collect::<Vec<_>>(),
    );
    let mut snapshot = Snapshot {
        home,
        classic_dirs,
        destination: &destination,
        stage: stage.path(),
        files: HashMap::new(),
        remaining: 256 * 1024 * 1024,
    };
    snapshot.files.insert((resolve_parent(&source), true), LAYER.to_owned());
    snapshot.copy(&source, LAYER, true)?;
    match fs::rename(stage.path(), &destination) {
        Err(_) if destination.is_dir() => Ok(()), // Another process published its complete layer.
        result => result,
    }
}

struct Snapshot<'a> {
    home: &'a Path,
    classic_dirs: Vec<PathBuf>,
    destination: &'a Path,
    stage: &'a Path,
    files: HashMap<(PathBuf, bool), String>,
    remaining: u64,
}

impl Snapshot<'_> {
    fn copy(&mut self, source: &Path, name: &str, config: bool) -> io::Result<()> {
        let mut options = File::options();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NONBLOCK);
        }
        let file = match options.open(source) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound && name != LAYER => return Ok(()),
            Err(error) => return Err(error),
        };
        if !file.metadata()?.is_file() {
            return Err(io::Error::other("expected a regular Ghostty configuration file or asset"));
        }
        let limit = if config { self.remaining.min(4 * 1024 * 1024) } else { self.remaining };
        let mut reader = file.take(limit + 1);
        let target = self.stage.join(name);
        if !config {
            let copied = io::copy(&mut reader, &mut File::create(target)?)?;
            return self.account(copied, limit);
        }
        let mut contents = String::new();
        let size = reader.read_to_string(&mut contents)?;
        self.account(size as u64, limit)?;
        let mut output = File::create(target)?;
        for line in contents.trim_start_matches('\u{feff}').lines() {
            let base = source.parent().unwrap_or(self.home);
            let Some((key, value)) = line.split_once('=') else {
                writeln!(output, "{line}")?;
                continue;
            };
            let value = unquote(value.trim());
            match key.trim() {
                "config-file" | "background-image" | "custom-shader" | "bell-audio-path"
                | "gtk-custom-css"
                    if !value.is_empty() =>
                {
                    let raw = value.strip_prefix('?').unwrap_or(value);
                    let optional = if raw.len() != value.len() { "?" } else { "" };
                    let raw = unquote(raw);
                    if raw.is_empty() {
                        writeln!(output, "{line}")?;
                        continue;
                    }
                    let path = self.reference(raw, base, key.trim() == "config-file")?;
                    if path.ends_with([' ', '\t', '\r', '"']) {
                        writeln!(output, "{key}= {optional}\"{path}\"")?;
                    } else {
                        writeln!(output, "{key}= {optional}{path}")?;
                    }
                }
                "theme" => {
                    // Ghostty accepts a name, an absolute theme file, or light:/dark: alternatives.
                    let mut specs = Vec::new();
                    for part in value.split(',') {
                        let part = part.trim();
                        let (prefix, path) = ["light:", "dark:"]
                            .into_iter()
                            .find_map(|prefix| part.strip_prefix(prefix).map(|path| (prefix, path)))
                            .unwrap_or(("", part));
                        if Path::new(path).is_absolute() && self.owned(Path::new(path)) {
                            let name = self.dependency(Path::new(path), true)?;
                            // Ghostty treats a relative theme as a name, so use the final absolute file.
                            let target = self.destination.join(name);
                            specs.push(format!("{prefix}{}", target.display()));
                        } else {
                            specs.push(part.to_owned());
                        }
                    }
                    if specs.iter().zip(value.split(',')).all(|(spec, raw)| spec == raw.trim()) {
                        writeln!(output, "{line}")?;
                    } else {
                        writeln!(output, "{key}= {}", specs.join(","))?;
                    }
                }
                _ => writeln!(output, "{line}")?,
            }
        }
        Ok(())
    }

    fn account(&mut self, size: u64, limit: u64) -> io::Result<()> {
        if size > limit {
            return Err(io::Error::other("Classic terminal settings exceed the import size limit"));
        }
        self.remaining -= size;
        Ok(())
    }

    fn reference(&mut self, raw: &str, base: &Path, config: bool) -> io::Result<String> {
        let path =
            raw.strip_prefix("~/").map_or_else(|| base.join(raw), |suffix| self.home.join(suffix));
        if self.owned(&path) {
            self.dependency(&path, config)
        } else {
            Ok(path.to_string_lossy().into_owned())
        }
    }

    fn owned(&self, path: &Path) -> bool {
        let at = resolve_parent(path);
        let real = fs::canonicalize(path).ok();
        self.classic_dirs.iter().any(|dir| {
            at.starts_with(dir) || real.as_ref().is_some_and(|resolved| resolved.starts_with(dir))
        })
    }

    fn dependency(&mut self, path: &Path, config: bool) -> io::Result<String> {
        let key = (resolve_parent(path), config);
        if let Some(name) = self.files.get(&key) {
            return Ok(name.clone());
        }
        if self.files.len() >= 128 {
            return Err(io::Error::other("too many files in Classic's terminal settings"));
        }
        let mut name = format!("file-{}", self.files.len());
        if let Some(ext) = path.extension().and_then(|ext| ext.to_str()) {
            name.push('.');
            name.push_str(ext);
        }
        self.files.insert(key, name.clone());
        self.copy(path, &name, config)?;
        Ok(name)
    }
}

// Do not canonicalize the last component: Ghostty resolves paths in a symlinked
// configuration relative to the symlink's parent, not the target's parent.
fn resolve_parent(path: &Path) -> PathBuf {
    path.parent()
        .and_then(|parent| fs::canonicalize(parent).ok())
        .zip(path.file_name())
        .map_or_else(|| path.to_owned(), |(parent, name)| parent.join(name))
}

fn unquote(value: &str) -> &str {
    value.strip_prefix('"').and_then(|s| s.strip_suffix('"')).unwrap_or(value)
}

#[cfg(test)]
#[path = "ghostty_tests.rs"]
mod tests;
