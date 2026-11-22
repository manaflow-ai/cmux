//! `cmux ext pack [DIR] [--out DIR]`: the release assets of an extension.
//! `cmux-extension.tar.gz` holds the package as cmux installs it (the
//! manifest and the files it names: the same set `ext dev` copies), and
//! `cmux-app.v2.json` is the manifest beside it, so a registry reads the
//! version and scopes without unpacking. The archive is byte-for-byte the
//! same for the same files (sorted, no times or owners), so its sha256 names
//! the release. Anyone rebuilds it from the source at a commit and compares:
//! `--expect SHA256` fails unless this folder packs to that hash, and
//! [`sha256_of`] is the hash `ext add` records for what it fetched.

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
    /// `--expect SHA256`: the published hash this folder must pack to.
    pub expect: Option<String>,
    /// `--entry FILE`: a signed registry entry whose id, version and hash
    /// this folder must pack to.
    pub entry: Option<PathBuf>,
}

/// The registry entry at `path`, opened with the registry's keys; else why not.
pub(super) fn read_entry(path: &Path) -> Result<cmux_tui_core::registry_trust::Entry, String> {
    use cmux_tui_core::registry_trust as trust;
    let body = trust::read_signed(path)
        .unwrap_or_else(|| Err(format!("no registry entry at {}", path.display())))?;
    trust::open_entry(&body, &trust::trusted_keys())
        .map_err(|why| format!("{} is not a registry entry cmux signed: {why}", path.display()))
}

/// What `ext pack` wrote.
#[derive(Debug, Clone, PartialEq, Eq)]
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

/// Why `pack` did not finish.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum PackError {
    /// The folder is not a valid extension, or a file could not be read or written.
    Invalid(String),
    /// It packed, to another hash than `--expect`: not the published build.
    Mismatch { expected: String, packed: Packed },
}

impl PackError {
    pub(super) fn text(&self) -> String {
        match self {
            PackError::Invalid(message) => message.clone(),
            PackError::Mismatch { expected, packed } => format!(
                "{} {} packs to sha256 {}, not the expected {expected}: these files are not that build",
                packed.id, packed.version, packed.sha256
            ),
        }
    }
}

/// A folder's package, its files and their archive, before anything is written.
struct Built {
    id: String,
    version: String,
    manifest_file: PathBuf,
    files: Vec<PathBuf>,
    bytes: Vec<u8>,
}

/// Validates `dir` as `ext dev` does and archives its package files, leaving
/// out `skip` (the output folder, relative to `dir`).
fn build(dir: &Path, skip: Option<&Path>) -> Result<Built, String> {
    let pkg = dev::load_package(dir).map_err(|problems| {
        let lines: Vec<String> = problems.iter().map(dev::Problem::text).collect();
        format!("{} is not a valid extension:\n{}", dir.display(), lines.join("\n"))
    })?;
    let files: Vec<PathBuf> = dev::package_files(&pkg)
        .map_err(|problem| problem.text())?
        .into_iter()
        .filter(|rel| skip.is_none_or(|skip| !rel.starts_with(skip)))
        .collect();
    let manifest_file = files
        .iter()
        .find(|rel| *rel == Path::new("cmux-app.json") || *rel == Path::new(MANIFEST_ASSET))
        .cloned()
        .ok_or_else(|| format!("{} has no manifest", dir.display()))?;
    let bytes = archive(dir, &files)?;
    Ok(Built {
        id: pkg.manifest.field("id").as_str().unwrap_or_default().to_string(),
        version: pkg.manifest.field("version").as_str().unwrap_or_default().to_string(),
        manifest_file,
        files,
        bytes,
    })
}

/// The sha256 `ext pack` prints for `dir` (its default `release/` left out),
/// writing nothing.
pub(super) fn sha256_of(dir: &Path) -> Result<String, String> {
    build(dir, Some(Path::new(OUT_DIR))).map(|built| hex_sha256(&built.bytes))
}

fn hex_sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// Validates `options.dir` as `ext dev` does, then writes the two assets;
/// with `--expect`, fails when they hash to anything else.
pub(super) fn pack(options: &PackOptions) -> Result<Packed, PackError> {
    let dir = &options.dir;
    let out = options.out.clone().unwrap_or_else(|| dir.join(OUT_DIR));
    let out_rel = out.strip_prefix(dir).ok().map(Path::to_path_buf);
    let built = build(dir, out_rel.as_deref()).map_err(PackError::Invalid)?;
    let mut expect = options.expect.clone();
    if let Some(path) = &options.entry {
        let entry = read_entry(path).map_err(PackError::Invalid)?;
        if (entry.id.as_str(), entry.version.as_str())
            != (built.id.as_str(), built.version.as_str())
        {
            return Err(PackError::Invalid(format!(
                "the entry is {}@{}'s, and this folder is {}@{}",
                entry.id, entry.version, built.id, built.version
            )));
        }
        expect = Some(entry.sha256);
    }
    let io = |what: &str, path: &Path, e: std::io::Error| {
        PackError::Invalid(format!("cannot {what} {}: {e}", path.display()))
    };
    std::fs::create_dir_all(&out).map_err(|e| io("create", &out, e))?;
    let archive_path = out.join(ARCHIVE);
    std::fs::write(&archive_path, &built.bytes).map_err(|e| io("write", &archive_path, e))?;
    let manifest_path = out.join(MANIFEST_ASSET);
    std::fs::copy(dir.join(&built.manifest_file), &manifest_path)
        .map_err(|e| io("write", &manifest_path, e))?;
    let packed = Packed {
        sha256: hex_sha256(&built.bytes),
        id: built.id,
        version: built.version,
        archive: archive_path,
        manifest: manifest_path,
        files: built.files,
    };
    match &expect {
        Some(expected) if !expected.trim().eq_ignore_ascii_case(&packed.sha256) => {
            Err(PackError::Mismatch { expected: expected.trim().to_ascii_lowercase(), packed })
        }
        _ => Ok(packed),
    }
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
