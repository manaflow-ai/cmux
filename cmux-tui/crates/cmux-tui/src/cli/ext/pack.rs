//! `cmux ext pack [DIR] [--out DIR]`: the release assets of an extension.
//! `cmux-extension.tar.gz` holds the package as cmux installs it (the
//! manifest and the files it names: the same set `ext dev` copies), and
//! `cmux-app.v2.json` is the manifest beside it, so a registry reads the
//! version and scopes without unpacking. The archive is byte-for-byte the
//! same for the same files (sorted, no times or owners), so its sha256 names
//! the release.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::Field as _;
use super::dev;

/// The archive's file name, a release asset.
pub(super) const ARCHIVE: &str = "cmux-extension.tar.gz";
/// The manifest's release asset name.
pub(super) const MANIFEST_ASSET: &str = "cmux-app.v2.json";
/// Where the assets go by default, inside the extension folder (the
/// scaffold's `.gitignore` leaves it out of the repository).
pub(super) const OUT_DIR: &str = "release";

/// `ext pack`'s options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct PackOptions {
    pub dir: PathBuf,
    /// `--out DIR` (default `DIR/release`).
    pub out: Option<PathBuf>,
}

/// What `ext pack` wrote.
#[derive(Debug, Clone)]
pub(super) struct Packed {
    pub id: String,
    pub version: String,
    pub archive: PathBuf,
    pub manifest: PathBuf,
    pub sha256: String,
    pub files: Vec<PathBuf>,
}

impl Packed {
    pub(super) fn to_json(&self) -> Value {
        json!({
            "ok": true,
            "id": self.id,
            "version": self.version,
            "archive": self.archive,
            "manifest": self.manifest,
            "sha256": self.sha256,
            "files": self.files,
        })
    }

    pub(super) fn text(&self) -> String {
        format!(
            "packed {} {} ({} files)\n  {}\n  {}\nsha256 {}\n",
            self.id,
            self.version,
            self.files.len(),
            self.archive.display(),
            self.manifest.display(),
            self.sha256
        )
    }
}

/// Validates `options.dir` as `ext dev` does, then writes the two assets.
pub(super) fn pack(options: &PackOptions) -> Result<Packed, String> {
    let dir = &options.dir;
    let pkg = dev::load_package(dir).map_err(|problems| {
        let lines: Vec<String> = problems.iter().map(dev::Problem::text).collect();
        format!("{} is not a valid extension:\n{}", dir.display(), lines.join("\n"))
    })?;
    let out = options.out.clone().unwrap_or_else(|| dir.join(OUT_DIR));
    let out_rel = out.strip_prefix(dir).ok().map(Path::to_path_buf);
    let files: Vec<PathBuf> = dev::package_files(&pkg)
        .map_err(|problem| problem.text())?
        .into_iter()
        .filter(|rel| out_rel.as_ref().is_none_or(|skip| !rel.starts_with(skip)))
        .collect();
    let manifest_file = files
        .iter()
        .find(|rel| *rel == Path::new("cmux-app.json") || *rel == Path::new(MANIFEST_ASSET))
        .cloned()
        .ok_or_else(|| format!("{} has no manifest", dir.display()))?;
    let bytes = archive(dir, &files)?;
    std::fs::create_dir_all(&out).map_err(|e| format!("cannot create {}: {e}", out.display()))?;
    let archive_path = out.join(ARCHIVE);
    std::fs::write(&archive_path, &bytes)
        .map_err(|e| format!("cannot write {}: {e}", archive_path.display()))?;
    let manifest_path = out.join(MANIFEST_ASSET);
    std::fs::copy(dir.join(&manifest_file), &manifest_path)
        .map_err(|e| format!("cannot write {}: {e}", manifest_path.display()))?;
    let sha256 = Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
    Ok(Packed {
        id: pkg.manifest.field("id").as_str().unwrap_or_default().to_string(),
        version: pkg.manifest.field("version").as_str().unwrap_or_default().to_string(),
        archive: archive_path,
        manifest: manifest_path,
        sha256,
        files,
    })
}

/// The gzip'd tar of `files` (relative to `dir`), in order, each a plain
/// file with mode 644, no time and no owner.
pub(super) fn archive(dir: &Path, files: &[PathBuf]) -> Result<Vec<u8>, String> {
    let mut sorted = files.to_vec();
    sorted.sort();
    let mut builder =
        tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best()));
    for rel in &sorted {
        let path = dir.join(rel);
        let body =
            std::fs::read(&path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        let mut header = tar::Header::new_ustar();
        header.set_size(body.len() as u64);
        header.set_mode(0o644);
        header.set_mtime(0);
        header.set_uid(0);
        header.set_gid(0);
        header.set_entry_type(tar::EntryType::Regular);
        builder
            .append_data(&mut header, rel, body.as_slice())
            .map_err(|e| format!("cannot pack {}: {e}", rel.display()))?;
    }
    builder
        .into_inner()
        .and_then(|gz| gz.finish())
        .map_err(|e| format!("cannot finish {ARCHIVE}: {e}"))
}
