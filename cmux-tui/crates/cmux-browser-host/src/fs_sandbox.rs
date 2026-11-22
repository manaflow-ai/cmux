//! The REPL's file sandbox (`__cmuxNative.fs`, driver-protocol.md "Native
//! host contract"): paths resolve against the session root; absolute paths
//! must stay inside the root or the temporary directory. Results are
//! `{"ok": value}` or `{"error": {"code", "message"}}`.

use serde_json::{Value, json};
use std::path::{Component, Path, PathBuf};

pub struct FsSandbox {
    root: PathBuf,
    tmp: PathBuf,
    /// Files the driver reported through `download.finished`: readable
    /// (readFile, stat, exists), never writable. The newest
    /// [`READABLE_KEPT`] are kept.
    readable: std::sync::Mutex<std::collections::VecDeque<PathBuf>>,
}

/// Reported downloads a session can still read.
const READABLE_KEPT: usize = 64;

fn err(code: &str, message: impl Into<String>) -> Value {
    json!({"error": {"code": code, "message": message.into()}})
}

fn io_err(error: &std::io::Error, path: &str) -> Value {
    use std::io::ErrorKind;
    let code = match error.kind() {
        ErrorKind::NotFound => "ENOENT",
        ErrorKind::PermissionDenied => "EACCES",
        ErrorKind::AlreadyExists => "EEXIST",
        ErrorKind::NotADirectory => "ENOTDIR",
        ErrorKind::IsADirectory => "EISDIR",
        ErrorKind::DirectoryNotEmpty => "ENOTEMPTY",
        _ => "EINVAL",
    };
    err(code, format!("{error}: {path}"))
}

/// Lexical normalization (no symlink resolution of missing paths).
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

impl FsSandbox {
    /// A sandbox whose temporary directory is its own, next to nothing else.
    pub fn new(root: impl Into<PathBuf>) -> FsSandbox {
        let root = root.into();
        let tmp = std::env::temp_dir().join("cmux-browser-host").join(format!(
            "{}-{}",
            std::process::id(),
            normalize(&root).display().to_string().replace('/', "_")
        ));
        FsSandbox::with_tmp(root, tmp)
    }

    /// A sandbox over `root` plus a temporary directory `tmp` (both created).
    pub fn with_tmp(root: impl Into<PathBuf>, tmp: impl Into<PathBuf>) -> FsSandbox {
        let (root, tmp) = (root.into(), tmp.into());
        let _ = std::fs::create_dir_all(&root);
        let _ = std::fs::create_dir_all(&tmp);
        // Canonical forms, so `/var` and `/private/var` (macOS) compare equal.
        let canonical = |p: &Path| p.canonicalize().unwrap_or_else(|_| normalize(p));
        FsSandbox { root: canonical(&root), tmp: canonical(&tmp), readable: Default::default() }
    }

    /// The session's temporary directory (`__cmuxNative.tmpdir`).
    pub fn tmp(&self) -> &Path {
        &self.tmp
    }

    /// The absolute path for `path`, or `EACCES` when it leaves the sandbox.
    /// The deepest existing ancestor is canonicalized (symlinks resolved)
    /// and the missing rest appended, so no link on the way can point out.
    fn resolve(&self, path: &str) -> Result<PathBuf, Value> {
        let joined =
            if Path::new(path).is_absolute() { PathBuf::from(path) } else { self.root.join(path) };
        let full = normalize(&joined);
        let mut existing = full.as_path();
        let mut rest: Vec<&std::ffi::OsStr> = Vec::new();
        let resolved = loop {
            if let Ok(real) = existing.canonicalize() {
                break rest.iter().rev().fold(real, |acc, part| acc.join(part));
            }
            // A component that exists but does not canonicalize is a
            // dangling symlink: following it could create its target anywhere.
            if std::fs::symlink_metadata(existing).is_ok() {
                return Err(err("EACCES", format!("{path} goes through a broken symbolic link")));
            }
            match (existing.parent(), existing.file_name()) {
                (Some(parent), Some(name)) => {
                    rest.push(name);
                    existing = parent;
                }
                _ => break full.clone(),
            }
        };
        if resolved.starts_with(&self.root) || resolved.starts_with(&self.tmp) {
            Ok(resolved)
        } else {
            Err(err("EACCES", format!("{path} is outside the session's files")))
        }
    }

    /// Makes a file the driver reported through `download.finished`
    /// readable (an absolute path; its canonical form is kept).
    pub fn allow_read(&self, path: &str) {
        let Ok(real) = Path::new(path).canonicalize() else {
            return;
        };
        let mut readable = self.readable.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        readable.retain(|kept| *kept != real);
        readable.push_back(real);
        while readable.len() > READABLE_KEPT {
            readable.pop_front();
        }
    }

    /// `resolve`, or a reported download (read operations only).
    fn resolve_read(&self, path: &str) -> Result<PathBuf, Value> {
        self.resolve(path).or_else(|error| {
            let real = Path::new(path)
                .is_absolute()
                .then(|| Path::new(path).canonicalize().ok())
                .flatten();
            let readable = self.readable.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            match real {
                Some(real) if readable.contains(&real) => Ok(real),
                _ => Err(error),
            }
        })
    }

    pub fn call(&self, op: &str, args: &Value) -> Value {
        match self.run(op, args) {
            Ok(value) => json!({"ok": value}),
            Err(error) => error,
        }
    }

    fn run(&self, op: &str, args: &Value) -> Result<Value, Value> {
        let path_arg = |name: &str| -> String {
            args.get(name).and_then(Value::as_str).unwrap_or("").to_owned()
        };
        let resolved = |name: &str| self.resolve(&path_arg(name));
        let readable = |name: &str| self.resolve_read(&path_arg(name));
        let flag = |name: &str| args.get(name).and_then(Value::as_bool).unwrap_or(false);
        let shown = path_arg("path");
        let shown = shown.as_str();
        match op {
            "readFile" => {
                let path = readable("path")?;
                let bytes = std::fs::read(&path).map_err(|e| io_err(&e, shown))?;
                Ok(json!(base64_encode(&bytes)))
            }
            "writeFile" => {
                let path = resolved("path")?;
                let data = base64_decode(args.get("base64").and_then(Value::as_str).unwrap_or(""))
                    .ok_or_else(|| err("EINVAL", "writeFile: base64 is not valid"))?;
                let result = if flag("append") {
                    use std::io::Write;
                    std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&path)
                        .and_then(|mut f| f.write_all(&data))
                } else {
                    std::fs::write(&path, &data)
                };
                result.map_err(|e| io_err(&e, shown))?;
                Ok(Value::Null)
            }
            "mkdir" => {
                let path = resolved("path")?;
                let result = if flag("recursive") {
                    std::fs::create_dir_all(&path)
                } else {
                    std::fs::create_dir(&path)
                };
                result.map_err(|e| io_err(&e, shown))?;
                Ok(Value::Null)
            }
            "readdir" => {
                let path = resolved("path")?;
                let mut entries: Vec<Value> = std::fs::read_dir(&path)
                    .map_err(|e| io_err(&e, shown))?
                    .filter_map(Result::ok)
                    .map(|entry| {
                        let kind = entry.file_type().map(|t| file_type(&t)).unwrap_or("other");
                        json!({"name": entry.file_name().to_string_lossy(), "type": kind})
                    })
                    .collect();
                entries.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
                Ok(Value::Array(entries))
            }
            "stat" => {
                let path = readable("path")?;
                let meta = std::fs::symlink_metadata(&path).map_err(|e| io_err(&e, shown))?;
                let ms = |t: std::io::Result<std::time::SystemTime>| {
                    t.ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_millis() as u64)
                        .unwrap_or(0)
                };
                Ok(json!({
                    "size": meta.len(),
                    "type": file_type(&meta.file_type()),
                    "mtimeMs": ms(meta.modified()),
                    "birthtimeMs": ms(meta.created()),
                }))
            }
            "rm" => {
                let path = resolved("path")?;
                if path == self.root || path == self.tmp {
                    return Err(err(
                        "EACCES",
                        "rm: refusing to remove the session root or the temporary directory",
                    ));
                }
                let result = match std::fs::symlink_metadata(&path) {
                    Ok(meta) if meta.is_dir() => {
                        if flag("recursive") {
                            std::fs::remove_dir_all(&path)
                        } else {
                            std::fs::remove_dir(&path)
                        }
                    }
                    Ok(_) => std::fs::remove_file(&path),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound && flag("force") => Ok(()),
                    Err(e) => Err(e),
                };
                result.map_err(|e| io_err(&e, shown))?;
                Ok(Value::Null)
            }
            "rename" | "copyFile" => {
                let from = resolved("from")?;
                let to = resolved("to")?;
                let result = if op == "rename" {
                    std::fs::rename(&from, &to)
                } else {
                    std::fs::copy(&from, &to).map(|_| ())
                };
                result.map_err(|e| io_err(&e, &path_arg("from")))?;
                Ok(Value::Null)
            }
            "exists" => Ok(json!(readable("path").map(|p| p.exists()).unwrap_or(false))),
            "resolve" => Ok(json!(resolved("path")?.display().to_string())),
            other => Err(err("EINVAL", format!("unknown fs operation {other}"))),
        }
    }
}

fn file_type(t: &std::fs::FileType) -> &'static str {
    if t.is_symlink() {
        "symlink"
    } else if t.is_dir() {
        "directory"
    } else if t.is_file() {
        "file"
    } else {
        "other"
    }
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let mut acc = 0u32;
    let mut bits = 0;
    for c in text.bytes().filter(|c| !c.is_ascii_whitespace() && *c != b'=') {
        let v = ALPHABET.iter().position(|a| *a == c)? as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sandbox() -> (FsSandbox, PathBuf, PathBuf) {
        let base = std::env::temp_dir().join(format!(
            "fs-sandbox-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("t").replace("::", "-")
        ));
        let _ = std::fs::remove_dir_all(&base);
        let root = base.join("root");
        let outside = base.join("outside");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        (FsSandbox::with_tmp(&root, base.join("tmp")), root, outside)
    }

    #[test]
    fn intermediate_symlinks_cannot_leave_the_root() {
        let (fs, root, outside) = sandbox();
        std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
        let made = fs.call("mkdir", &json!({"path": "link/a/b", "recursive": true}));
        assert_eq!(made["error"]["code"], "EACCES", "{made}");
        assert!(!outside.join("a").exists());
        let written = fs.call("writeFile", &json!({"path": "link/x.txt", "base64": "aGk="}));
        assert_eq!(written["error"]["code"], "EACCES");
    }

    #[test]
    fn a_dangling_final_symlink_cannot_write_outside() {
        let (fs, root, outside) = sandbox();
        std::os::unix::fs::symlink(outside.join("created.txt"), root.join("dang")).unwrap();
        let written = fs.call("writeFile", &json!({"path": "dang", "base64": "aGk="}));
        assert_eq!(written["error"]["code"], "EACCES", "{written}");
        assert!(!outside.join("created.txt").exists());
    }

    #[test]
    fn the_temp_root_is_the_sessions_own() {
        let (fs, _root, _outside) = sandbox();
        let shared = std::env::temp_dir().join("not-this-session.txt");
        let read =
            fs.call("writeFile", &json!({"path": shared.display().to_string(), "base64": ""}));
        assert_eq!(read["error"]["code"], "EACCES", "{read}");
        let tmp = fs.call("resolve", &json!({"path": "."}));
        assert!(tmp["ok"].is_string());
    }

    #[test]
    fn base64_round_trips() {
        for sample in [&b""[..], b"h", b"hi", b"hi!", b"\x00\xff\x10binary"] {
            assert_eq!(base64_decode(&base64_encode(sample)).unwrap(), sample);
        }
        assert_eq!(base64_encode(b"hi"), "aGk=");
        assert!(base64_decode("@@").is_none());
    }
}
