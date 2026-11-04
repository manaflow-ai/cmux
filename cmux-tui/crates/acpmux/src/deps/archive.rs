//! Packing and unpacking a cache: a tar of the plan's folders, compressed by
//! the system `zstd` when there is one (much faster to unpack), else gzip in
//! process. The codec is part of the key, so a machine without `zstd` never
//! reads a zstd archive.
//!
//! Credentials files are never packed, and never unpacked from an archive
//! that holds one anyway.

use std::fs::File;
use std::io::{self, BufWriter, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, Stdio};

/// File and folder names that may hold a credential, matched exactly (case-insensitively).
const DENIED: &[&str] = &[
    ".npmrc",
    ".yarnrc",
    ".yarnrc.yml",
    ".netrc",
    "_netrc",
    ".pypirc",
    ".pgpass",
    "auth.json",
    ".git-credentials",
    ".gitconfig",
    ".env",
    "credentials",
    "credentials.toml",
    "credentials.json",
    ".docker",
    ".aws",
    ".ssh",
];

/// Folders that are build output or tool scratch, not installed dependencies.
const SKIPPED_DIRS: &[&str] = &[".cache"];

/// Whether a name may hold a credential: one of `DENIED`, or `.env.<anything>`.
pub fn denied(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    DENIED.contains(&lower.as_str()) || lower.starts_with(".env.")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Codec {
    Zstd,
    Gzip,
}

impl Codec {
    pub fn name(self) -> &'static str {
        match self {
            Codec::Zstd => "zstd",
            Codec::Gzip => "gzip",
        }
    }

    /// zstd when the system has it.
    pub fn here() -> Codec {
        let zstd = Command::new("zstd")
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if zstd { Codec::Zstd } else { Codec::Gzip }
    }
}

/// What a pack wrote.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Packed {
    pub files: u64,
    /// Bytes of file content before compression.
    pub raw_bytes: u64,
    /// Credentials files left out (names only, relative to the root).
    pub denied: Vec<String>,
}

/// A compressor writing to `out`: a `zstd` child, or gzip in process.
enum Sink {
    Zstd(Child),
    Gzip(flate2::write::GzEncoder<BufWriter<File>>),
}

impl Write for Sink {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Sink::Zstd(child) => child.stdin.as_mut().expect("piped").write(buf),
            Sink::Gzip(gz) => gz.write(buf),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Sink::Zstd(child) => child.stdin.as_mut().expect("piped").flush(),
            Sink::Gzip(gz) => gz.flush(),
        }
    }
}

impl Sink {
    fn new(codec: Codec, out: &Path) -> io::Result<Sink> {
        let file = File::create(out)?;
        Ok(match codec {
            Codec::Zstd => Sink::Zstd(
                Command::new("zstd")
                    .args(["-q", "-3", "-T0", "-c"])
                    .stdin(Stdio::piped())
                    .stdout(file)
                    .stderr(Stdio::null())
                    .spawn()?,
            ),
            Codec::Gzip => Sink::Gzip(flate2::write::GzEncoder::new(
                BufWriter::new(file),
                flate2::Compression::fast(),
            )),
        })
    }

    fn finish(self) -> io::Result<()> {
        match self {
            Sink::Zstd(mut child) => {
                drop(child.stdin.take());
                let status = child.wait()?;
                if !status.success() {
                    return Err(io::Error::other(format!("zstd exited with {status}")));
                }
                Ok(())
            }
            Sink::Gzip(gz) => gz.finish()?.flush(),
        }
    }
}

/// Pack `include` (folders under `root`; missing ones are skipped) into `out`.
pub fn pack(root: &Path, include: &[PathBuf], codec: Codec, out: &Path) -> io::Result<Packed> {
    let mut packed = Packed::default();
    let mut builder = tar::Builder::new(Sink::new(codec, out)?);
    builder.follow_symlinks(false);
    builder.mode(tar::HeaderMode::Complete);
    for rel in include {
        if !safe_relative(rel) {
            return Err(io::Error::other("cache folder is not a plain relative path"));
        }
        if std::fs::symlink_metadata(root.join(rel)).is_ok_and(|m| m.is_dir()) {
            walk(&mut builder, root, rel, &mut packed)?;
        }
    }
    builder.into_inner()?.finish()?;
    Ok(packed)
}

fn walk(
    builder: &mut tar::Builder<Sink>,
    root: &Path,
    rel: &Path,
    packed: &mut Packed,
) -> io::Result<()> {
    let path = root.join(rel);
    let meta = std::fs::symlink_metadata(&path)?;
    let kind = meta.file_type();
    if kind.is_dir() {
        builder.append_dir(rel, &path)?;
        let mut names: Vec<_> = std::fs::read_dir(&path)?.filter_map(Result::ok).collect();
        names.sort_by_key(|e| e.file_name());
        for entry in names {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            let child = rel.join(&name);
            if denied(&name_str) {
                packed.denied.push(child.to_string_lossy().into_owned());
                continue;
            }
            if SKIPPED_DIRS.contains(&name_str.as_ref())
                && entry.file_type().is_ok_and(|t| t.is_dir())
            {
                continue;
            }
            walk(builder, root, &child, packed)?;
        }
    } else if kind.is_file() || kind.is_symlink() {
        builder.append_path_with_name(&path, rel)?;
        if kind.is_file() {
            packed.files += 1;
            packed.raw_bytes += meta.len();
        }
    }
    // Sockets, fifos and devices are never dependencies.
    Ok(())
}

fn safe_relative(path: &Path) -> bool {
    path.components().all(|c| matches!(c, Component::Normal(_))) && path.components().count() > 0
}

/// A decompressing reader of `archive`: a `zstd -d` child, or gzip in process.
enum Source {
    Zstd(Child),
    Gzip(Box<flate2::read::GzDecoder<io::BufReader<File>>>),
}

impl Read for Source {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Source::Zstd(child) => child.stdout.as_mut().expect("piped").read(buf),
            Source::Gzip(gz) => gz.read(buf),
        }
    }
}

/// What an unpack wrote.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Unpacked {
    pub entries: u64,
    /// Credentials entries the archive held and that were not written.
    pub denied: u64,
    /// Entries outside the plan's folders, not written.
    pub outside: u64,
}

/// Unpack `archive` into `dest`, writing only entries under one of `allowed`
/// (the plan's folders): an archive from a shared scope can never write a
/// tool's binaries or config beside its cache (`~/.cargo/bin`,
/// `~/.cargo/config.toml`). Entries outside `dest` (absolute, `..`, or
/// through a symlink) are refused by tar's `unpack_in`; credentials entries
/// are skipped.
pub fn unpack(
    archive: &Path,
    codec: Codec,
    dest: &Path,
    allowed: &[PathBuf],
) -> io::Result<Unpacked> {
    let file = File::open(archive)?;
    let mut source = match codec {
        Codec::Zstd => Source::Zstd(
            Command::new("zstd")
                .args(["-q", "-d", "-c"])
                .stdin(file)
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()?,
        ),
        Codec::Gzip => {
            Source::Gzip(Box::new(flate2::read::GzDecoder::new(io::BufReader::new(file))))
        }
    };
    std::fs::create_dir_all(dest)?;
    let mut out = Unpacked::default();
    let result = (|| {
        let mut tar = tar::Archive::new(&mut source);
        tar.set_preserve_permissions(true);
        tar.set_preserve_mtime(true);
        tar.set_overwrite(true);
        tar.set_unpack_xattrs(false);
        for entry in tar.entries()? {
            let mut entry = entry?;
            let path = entry.path()?.into_owned();
            if path.components().any(|c| denied(&c.as_os_str().to_string_lossy())) {
                out.denied += 1;
                continue;
            }
            if !allowed.iter().any(|prefix| path.starts_with(prefix)) {
                out.outside += 1;
                continue;
            }
            if !entry.unpack_in(dest)? {
                return Err(io::Error::other("archive entry outside its folder"));
            }
            out.entries += 1;
        }
        Ok(())
    })();
    if let Source::Zstd(mut child) = source {
        // Stop reading first: a child blocked on a full pipe would never exit.
        drop(child.stdout.take());
        if result.is_err() {
            let _ = child.kill();
        }
        let status = child.wait()?;
        result?;
        if !status.success() {
            return Err(io::Error::other(format!("zstd exited with {status}")));
        }
        return Ok(out);
    }
    result.map(|()| out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn round_trip(codec: Codec) {
        let src = tempfile::tempdir().unwrap();
        let nm = src.path().join("node_modules");
        write(&nm.join("left-pad/index.js"), "module.exports = 1");
        write(&nm.join("left-pad/.npmrc"), "//registry.npmjs.org/:_authToken=secret");
        write(&nm.join("pkg/.env.local"), "TOKEN=secret");
        write(&nm.join(".cache/babel/x.json"), "{}");
        write(&nm.join(".bin/.keep"), "");
        #[cfg(unix)]
        std::os::unix::fs::symlink("../left-pad/index.js", nm.join(".bin/left-pad")).unwrap();
        write(&src.path().join(".npmrc"), "outside the packed folder");

        let out = tempfile::tempdir().unwrap();
        let archive = out.path().join("a.tar");
        let packed = pack(src.path(), &["node_modules".into()], codec, &archive).unwrap();
        assert_eq!(packed.files, 2, "{packed:?}");
        let mut denied = packed.denied.clone();
        denied.sort();
        assert_eq!(denied, ["node_modules/left-pad/.npmrc", "node_modules/pkg/.env.local"]);

        let dest = tempfile::tempdir().unwrap();
        let unpacked = unpack(&archive, codec, dest.path(), &["node_modules".into()]).unwrap();
        assert_eq!(unpacked.denied, 0);
        assert_eq!(unpacked.outside, 0);
        let got = dest.path().join("node_modules");
        assert_eq!(
            std::fs::read_to_string(got.join("left-pad/index.js")).unwrap(),
            "module.exports = 1"
        );
        assert!(!got.join("left-pad/.npmrc").exists());
        assert!(!got.join("pkg/.env.local").exists());
        assert!(!got.join(".cache").exists());
        assert!(!dest.path().join(".npmrc").exists());
        #[cfg(unix)]
        assert_eq!(
            std::fs::read_link(got.join(".bin/left-pad")).unwrap(),
            PathBuf::from("../left-pad/index.js")
        );
    }

    #[test]
    fn gzip_round_trip_never_carries_credentials() {
        round_trip(Codec::Gzip);
    }

    #[test]
    fn zstd_round_trip_never_carries_credentials() {
        if Codec::here() != Codec::Zstd {
            eprintln!("zstd is not installed here; the gzip test covers the archive");
            return;
        }
        round_trip(Codec::Zstd);
    }

    #[test]
    fn unpack_writes_only_the_plan_folders_never_credentials_and_refuses_escapes() {
        let out = tempfile::tempdir().unwrap();
        let archive = out.path().join("a.tar.gz");
        {
            let gz = flate2::write::GzEncoder::new(
                File::create(&archive).unwrap(),
                flate2::Compression::fast(),
            );
            let mut b = tar::Builder::new(gz);
            let mut header = tar::Header::new_gnu();
            header.set_size(6);
            header.set_mode(0o644);
            header.set_cksum();
            b.append_data(&mut header.clone(), "node_modules/x/.npmrc", &b"secret"[..]).unwrap();
            b.append_data(&mut header.clone(), "node_modules/x/ok.js", &b"okay!!"[..]).unwrap();
            b.append_data(&mut header, "bin/cargo", &b"#!evil"[..]).unwrap();
            b.into_inner().unwrap().finish().unwrap();
        }
        let dest = tempfile::tempdir().unwrap();
        let unpacked =
            unpack(&archive, Codec::Gzip, dest.path(), &["node_modules".into()]).unwrap();
        assert_eq!(unpacked, Unpacked { entries: 1, denied: 1, outside: 1 });
        assert!(!dest.path().join("bin/cargo").exists());
        assert!(!dest.path().join("node_modules/x/.npmrc").exists());
        assert!(dest.path().join("node_modules/x/ok.js").exists());
        assert!(pack(dest.path(), &["../x".into()], Codec::Gzip, &out.path().join("b")).is_err());
    }

    #[test]
    fn credential_names() {
        for name in
            [".npmrc", ".NPMRC", ".env", ".env.production", "credentials.toml", ".yarnrc.yml"]
        {
            assert!(denied(name), "{name}");
        }
        for name in ["index.js", "environment.js", "env", "credentials-helper.js"] {
            assert!(!denied(name), "{name}");
        }
    }
}
