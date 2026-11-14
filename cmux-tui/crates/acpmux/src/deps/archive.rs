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
    // A git folder's config and FETCH_HEAD name the remote URL, which can carry a token.
    ".git",
    ".env",
    "credentials",
    "credentials.toml",
    "credentials.json",
    ".docker",
    ".aws",
    ".ssh",
    // cmux's own machine credential and the GitHub CLI's token file.
    "machine-credential.json",
    "hosts.yml",
];

/// Folders under a `node_modules` that are build tools' scratch (rebuilt on
/// their next run), not installed dependencies. Elsewhere `.cache` is kept:
/// Cargo's sparse index lives in one.
const SKIPPED_DIRS: &[&str] =
    &[".cache", ".vite", ".vite-temp", ".turbo", ".parcel-cache", ".next", ".nx"];

/// A file of npm's cache index (`_cacache/index-v5/...`).
fn npm_index(rel: &Path) -> bool {
    let mut parts = rel.components().map(|c| c.as_os_str());
    parts.any(|c| c == "_cacache") && parts.next().is_some_and(|c| c == "index-v5")
}

/// Files that can record a registry URL: npm's cache (`_cacache`, response
/// bodies and tarballs) and the lockfiles kept in node_modules.
fn npm_metadata(rel: &Path) -> bool {
    // Lockfiles package managers keep beside the tree: npm's, Yarn Classic's
    // integrity file (its `lockfileEntries` hold resolved URLs), pnpm's.
    const LOCKS: &[&str] = &[".package-lock.json", ".yarn-integrity", ".modules.yaml", "lock.yaml"];
    rel.components().any(|c| c.as_os_str() == "_cacache")
        || rel.file_name().is_some_and(|n| LOCKS.iter().any(|l| n == *l))
}

/// Whether some URL in `bytes` carries a credential: userinfo
/// (`scheme://user[:pass]@host`) or a query parameter named like one
/// (`?token=`, `&access_key=`, `X-Amz-Signature=`).
fn url_with_userinfo(bytes: &[u8]) -> bool {
    const QUERY_SECRETS: &[&[u8]] =
        &[b"token", b"auth", b"key", b"sig", b"secret", b"password", b"passwd", b"credential"];
    let stop = |b: &u8| matches!(b, b'"' | b'\'' | b'<' | b'>' | b'\\') || b.is_ascii_whitespace();
    let mut rest = bytes;
    while let Some(at) = rest.windows(3).position(|w| w == b"://") {
        let after = rest.get(at + 3..).unwrap_or_default();
        let url =
            after.get(..after.iter().position(stop).unwrap_or(after.len())).unwrap_or_default();
        let authority = url.get(..url.iter().position(|b| *b == b'/').unwrap_or(url.len()));
        if authority.is_some_and(|a| a.contains(&b'@')) {
            return true;
        }
        if let Some(q) = url.iter().position(|b| *b == b'?') {
            let query = url.get(q + 1..).unwrap_or_default().to_ascii_lowercase();
            let names = query
                .split(|b| *b == b'&')
                .map(|p| p.split(|b| *b == b'=').next().unwrap_or_default());
            if names
                .into_iter()
                .any(|name| QUERY_SECRETS.iter().any(|s| name.windows(s.len()).any(|w| w == *s)))
            {
                return true;
            }
        }
        rest = after;
    }
    false
}

/// [`url_with_userinfo`] over a file, read in chunks that overlap by more
/// than any authority worth matching.
fn file_has_userinfo_url(path: &Path) -> io::Result<bool> {
    const CHUNK: usize = 1 << 20;
    const OVERLAP: usize = 1024;
    let mut file = File::open(path)?;
    let mut buf = vec![0u8; CHUNK + OVERLAP];
    let mut kept = 0;
    loop {
        let read = file.read(buf.get_mut(kept..).unwrap_or_default())?;
        if read == 0 {
            return Ok(false);
        }
        let filled = kept + read;
        let window = buf.get(..filled).unwrap_or_default();
        if url_with_userinfo(window) {
            return Ok(true);
        }
        kept = filled.min(OVERLAP);
        buf.copy_within(filled - kept..filled, 0);
    }
}

/// Whether an index line records a header that can carry a credential.
fn secret_header(line: &[u8]) -> bool {
    let lower = line.to_ascii_lowercase();
    ["authorization", "cookie", "_authtoken", "proxy-authorization"]
        .iter()
        .any(|needle| lower.windows(needle.len()).any(|w| w == needle.as_bytes()))
}

/// Whether a folder is a bare git repository: `HEAD`, `objects/` and `refs/`.
fn bare_repo(path: &Path) -> bool {
    path.join("HEAD").is_file() && path.join("objects").is_dir() && path.join("refs").is_dir()
}

fn piped<T>(pipe: Option<&mut T>) -> io::Result<&mut T> {
    pipe.ok_or_else(|| io::Error::other("zstd pipe closed"))
}

/// Name prefixes that may hold a credential: `.env`, `.envrc`, `.env.local`,
/// `.yarnrc.local`, `credentials-prod.json`, `.npmrc.bak` and the like.
const DENIED_PREFIXES: &[&str] = &[".env", ".yarnrc", ".npmrc", ".netrc", ".pypirc", "credentials"];

/// Whether a name may hold a credential: one of `DENIED`, or one starting
/// with a `DENIED_PREFIXES` entry.
pub fn denied(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    if DENIED.contains(&lower.as_str()) {
        return true;
    }
    // A package's source file named for credentials (`credentials-helper.js`)
    // is code, not a secret, and dropping it would break the package.
    let code = CODE_EXTENSIONS.iter().any(|ext| lower.ends_with(ext));
    DENIED_PREFIXES.iter().any(|p| lower.starts_with(p))
        && !(code && lower.starts_with("credentials"))
}

const CODE_EXTENSIONS: &[&str] =
    &[".js", ".cjs", ".mjs", ".ts", ".cts", ".mts", ".map", ".rs", ".py", ".pyi", ".d.ts"];

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
            Sink::Zstd(child) => piped(child.stdin.as_mut())?.write(buf),
            Sink::Gzip(gz) => gz.write(buf),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Sink::Zstd(child) => piped(child.stdin.as_mut())?.flush(),
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
                    // Packing runs in the background, after the install: a higher level and
                    // a long window for a smaller download on every later machine.
                    .args(["-q", "-12", "--long=27", "-T0", "-c"])
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
        // A bare clone (a git dependency's database) names its remote URL in
        // config and FETCH_HEAD, which can carry a token: never packed.
        if bare_repo(&path) {
            packed.denied.push(rel.to_string_lossy().into_owned());
            return Ok(());
        }
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
            if rel.starts_with("node_modules")
                && SKIPPED_DIRS.contains(&name_str.as_ref())
                && entry.file_type().is_ok_and(|t| t.is_dir())
            {
                continue;
            }
            walk(builder, root, &child, packed)?;
        }
    } else if kind.is_file() && npm_index(rel) {
        // npm keeps a request's Authorization header in its cache index when
        // the registry answers `Vary: Authorization`: such entries are dropped.
        let text = std::fs::read(&path)?;
        let kept: Vec<u8> = text
            .split_inclusive(|b| *b == b'\n')
            .filter(|line| !secret_header(line) && !url_with_userinfo(line))
            .flatten()
            .copied()
            .collect();
        if kept.len() != text.len() {
            packed.denied.push(rel.to_string_lossy().into_owned());
        }
        let mut header = tar::Header::new_gnu();
        header.set_metadata(&meta);
        let size = u64::try_from(kept.len()).unwrap_or(u64::MAX);
        header.set_size(size);
        builder.append_data(&mut header, rel, kept.as_slice())?;
        packed.files += 1;
        packed.raw_bytes += size;
    } else if kind.is_file() && npm_metadata(rel) && file_has_userinfo_url(&path)? {
        // A cached registry response or lockfile naming an authenticated URL
        // (`https://user:token@host/...`): left out, costing only a download.
        packed.denied.push(rel.to_string_lossy().into_owned());
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

/// `target` read from the folder `dir` (both relative to the archive root),
/// lexically: None when it is absolute or climbs above the root.
fn within(dir: &Path, target: &Path) -> Option<PathBuf> {
    let mut out = dir.to_path_buf();
    for part in target.components() {
        match part {
            Component::Normal(name) => out.push(name),
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    return None;
                }
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    Some(out)
}

/// Whether a path is, or passes through, one of the links written so far.
fn through_link(path: &Path, links: &std::collections::HashSet<PathBuf>) -> bool {
    path.ancestors().any(|a| links.contains(a))
}

/// Whether every `..` in a link target comes before its first name.
fn leading_parents_only(target: &Path) -> bool {
    let mut named = false;
    for part in target.components() {
        match part {
            Component::Normal(_) => named = true,
            Component::ParentDir if named => return false,
            _ => {}
        }
    }
    true
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
            Source::Zstd(child) => piped(child.stdout.as_mut())?.read(buf),
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
    links: bool,
) -> io::Result<Unpacked> {
    let file = File::open(archive)?;
    let mut source = match codec {
        Codec::Zstd => Source::Zstd(
            Command::new("zstd")
                // The window an archive packed with --long=27 needs; older (-3) ones decode the same.
                .args(["-q", "-d", "--long=27", "-c"])
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
        // Mode bits only: an archive from a shared scope never plants a setuid file.
        tar.set_preserve_permissions(false);
        tar.set_preserve_mtime(true);
        tar.set_overwrite(true);
        tar.set_unpack_xattrs(false);
        // Symlinks written so far: nothing is written through one, so a `..`
        // never climbs out of a folder that a link stood in for.
        let mut written_links: std::collections::HashSet<PathBuf> = Default::default();
        for entry in tar.entries()? {
            let mut entry = entry?;
            let path = entry.path()?.into_owned();
            if through_link(&path, &written_links) {
                out.outside += 1;
                continue;
            }
            if path.components().any(|c| denied(&c.as_os_str().to_string_lossy())) {
                out.denied += 1;
                continue;
            }
            if !allowed.iter().any(|prefix| path.starts_with(prefix)) {
                out.outside += 1;
                continue;
            }
            // A link must land inside the plan's folders too: tar's own bound is
            // all of `dest`, so `registry/cache -> ../bin` followed by
            // `registry/cache/cargo` would write `~/.cargo/bin/cargo`.
            if let Some(target) = entry.link_name()? {
                // Merging into a folder that holds more than the archive: a
                // chain of links that each stay inside could still leave it.
                if !links {
                    out.outside += 1;
                    continue;
                }
                let kind = entry.header().entry_type();
                let resolved = if kind.is_symlink() {
                    // `..` only leads the target (`../pkg/bin.js`): after a
                    // name it could climb out of a folder that is itself a link
                    // (`anchor -> .` then `alias -> anchor/../.env`).
                    if !leading_parents_only(&target) {
                        out.outside += 1;
                        continue;
                    }
                    path.parent().and_then(|dir| within(dir, &target))
                } else {
                    within(Path::new(""), &target).filter(|t| !through_link(t, &written_links))
                };
                if !resolved.is_some_and(|r| allowed.iter().any(|prefix| r.starts_with(prefix))) {
                    out.outside += 1;
                    continue;
                }
                if kind.is_symlink() {
                    written_links.insert(path.clone());
                }
            }
            // tar 0.4.46: `Entry::unpack_in(&mut self, dst) -> io::Result<bool>`,
            // false when the entry's path would leave `dest`.
            let inside: bool = entry.unpack_in(dest)?;
            if !inside {
                return Err(io::Error::other("archive entry outside its folder"));
            }
            out.entries += 1;
        }
        Ok(())
    })();
    if let Source::Zstd(mut child) = source {
        // On success read to the end, so zstd's last write never meets a closed
        // pipe; on an error stop reading and kill it, since a child blocked on
        // a full pipe would never exit.
        if result.is_ok()
            && let Some(mut stdout) = child.stdout.take()
        {
            let _ = io::copy(&mut stdout, &mut io::sink());
        }
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

#[cfg(all(test, unix))]
mod tests;
