//! File requests: read with a hash, write and edit under a hash precondition,
//! list, glob and grep. Every write is atomic (a temp file in the same folder,
//! then rename), so a reader never sees half a file.

use super::HandError;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Largest file read or written in one request.
pub const MAX_FILE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_LIST: usize = 5_000;
const DEFAULT_LIMIT: usize = 1_000;
/// Folders never searched by glob and grep (still readable by path).
const SKIP_DIRS: &[&str] = &[".git", "node_modules", "target", ".venv"];
/// Kernel file systems a search never enters (endless or blocking reads).
const SKIP_ROOTS: &[&str] = &["/proc", "/sys", "/dev"];

pub fn sha256_hex(bytes: &[u8]) -> String {
    let d = Sha256::digest(bytes);
    d.iter().map(|b| format!("{b:02x}")).collect()
}

fn read_text(path: &Path) -> Result<Option<String>, HandError> {
    match std::fs::metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(HandError::io(path, e)),
        Ok(m) if m.is_dir() => {
            return Err(HandError::new("fs.is_dir", format!("{} is a folder", path.display())));
        }
        Ok(m) if m.len() > MAX_FILE_BYTES => {
            return Err(HandError::new(
                "fs.too_large",
                format!("{} is {} bytes (max {MAX_FILE_BYTES})", path.display(), m.len()),
            ));
        }
        Ok(_) => {}
    }
    let bytes = std::fs::read(path).map_err(|e| HandError::io(path, e))?;
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| HandError::new("fs.not_text", format!("{} is not UTF-8 text", path.display())))
}

/// `expect`: a hex SHA-256 the current file must have, or `"absent"` for a
/// file that must not exist yet. None: no check.
fn check_expect(path: &Path, current: Option<&str>, expect: Option<&str>) -> Result<(), HandError> {
    let Some(want) = expect else { return Ok(()) };
    let have = current.map(|t| sha256_hex(t.as_bytes()));
    let ok = match (want, &have) {
        ("absent", None) => true,
        (w, Some(h)) => w.eq_ignore_ascii_case(h),
        _ => false,
    };
    if ok {
        Ok(())
    } else {
        Err(HandError::new(
            "fs.stale",
            format!(
                "{} changed: expected {want}, found {}",
                path.display(),
                have.as_deref().unwrap_or("absent")
            ),
        )
        .with_detail(json!({ "sha256": have })))
    }
}

pub fn atomic_write(path: &Path, text: &str) -> Result<(), HandError> {
    use std::io::Write;
    if text.len() as u64 > MAX_FILE_BYTES {
        return Err(HandError::new(
            "fs.too_large",
            format!("{} bytes (max {MAX_FILE_BYTES})", text.len()),
        ));
    }
    let dir = path.parent().ok_or_else(|| HandError::new("fs.bad_path", "no parent folder"))?;
    std::fs::create_dir_all(dir).map_err(|e| HandError::io(dir, e))?;
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.hand-{}.tmp", uuid::Uuid::now_v7().simple()));
    let perms = std::fs::metadata(path).ok().map(|m| m.permissions());
    let result = (|| -> std::io::Result<()> {
        let mut o = std::fs::OpenOptions::new();
        o.write(true).create_new(true);
        // Never wider than the file it replaces, not even for a moment.
        #[cfg(unix)]
        {
            use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
            o.mode(perms.as_ref().map_or(0o644, |p| p.mode() & 0o7777));
        }
        let mut f = o.open(&tmp)?;
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
        if let Some(p) = perms {
            std::fs::set_permissions(&tmp, p)?;
        }
        std::fs::rename(&tmp, path)
    })();
    if let Err(e) = result {
        let _ = std::fs::remove_file(&tmp);
        return Err(HandError::io(path, e));
    }
    Ok(())
}

pub fn read(
    path: &Path,
    start_line: Option<u64>,
    end_line: Option<u64>,
) -> Result<Value, HandError> {
    let text = read_text(path)?.ok_or_else(|| {
        HandError::new("fs.not_found", format!("{} does not exist", path.display()))
    })?;
    let sha = sha256_hex(text.as_bytes());
    let lines = text.lines().count() as u64;
    let body = match (start_line, end_line) {
        (None, None) => text,
        (s, e) => {
            let s = s.unwrap_or(1).max(1);
            let e = e.unwrap_or(u64::MAX);
            text.split_inclusive('\n')
                .skip((s - 1) as usize)
                .take(e.saturating_sub(s - 1) as usize)
                .collect()
        }
    };
    Ok(json!({ "path": path, "text": body, "sha256": sha, "lines": lines }))
}

pub fn write(path: &Path, text: &str, expect: Option<&str>) -> Result<Value, HandError> {
    let current = read_text(path)?;
    check_expect(path, current.as_deref(), expect)?;
    atomic_write(path, text)?;
    Ok(
        json!({ "path": path, "sha256": sha256_hex(text.as_bytes()), "bytes": text.len(), "created": current.is_none() }),
    )
}

/// Exact-match replace. Each `old` must occur exactly once in the text as the
/// earlier edits left it; 0 or 2+ matches fail the whole request.
pub fn edit(path: &Path, edits: &[(String, String)], expect: &str) -> Result<Value, HandError> {
    let mut text = read_text(path)?.ok_or_else(|| {
        HandError::new("fs.not_found", format!("{} does not exist", path.display()))
    })?;
    check_expect(path, Some(&text), Some(expect))?;
    if edits.is_empty() {
        return Err(HandError::new("fs.edit.empty", "edits is empty"));
    }
    for (i, (old, new)) in edits.iter().enumerate() {
        if old.is_empty() {
            return Err(HandError::new("fs.edit.empty_old", format!("edit {i}: old is empty")));
        }
        let n = text.matches(old.as_str()).count();
        if n != 1 {
            let code = if n == 0 { "fs.edit.no_match" } else { "fs.edit.ambiguous" };
            return Err(HandError::new(
                code,
                format!(
                    "edit {i}: old text found {n} times in {} (needs exactly 1)",
                    path.display()
                ),
            )
            .with_detail(json!({ "edit": i, "matches": n })));
        }
        text = text.replacen(old.as_str(), new, 1);
    }
    atomic_write(path, &text)?;
    Ok(json!({ "path": path, "sha256": sha256_hex(text.as_bytes()), "edits": edits.len() }))
}

pub fn list(path: &Path) -> Result<Value, HandError> {
    let mut entries = Vec::new();
    let rd = std::fs::read_dir(path).map_err(|e| HandError::io(path, e))?;
    for e in rd.flatten().take(MAX_LIST) {
        let ft = e.file_type().ok();
        let kind = match ft {
            Some(t) if t.is_dir() => "dir",
            Some(t) if t.is_symlink() => "link",
            _ => "file",
        };
        let size = e.metadata().map(|m| m.len()).unwrap_or(0);
        entries
            .push(json!({ "name": e.file_name().to_string_lossy(), "kind": kind, "size": size }));
    }
    entries.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    Ok(json!({ "path": path, "entries": entries }))
}

/// A glob as a regex over `/`-separated relative paths: `**` any folders,
/// `*` and `?` within one name, `{a,b}` alternatives.
pub fn glob_regex(pattern: &str) -> Result<regex::Regex, HandError> {
    let mut re = String::from("^");
    let chars: Vec<char> = pattern.chars().collect();
    let mut i = 0;
    let mut depth = 0;
    while let Some(&c) = chars.get(i) {
        match c {
            '*' if chars.get(i + 1) == Some(&'*') => {
                i += 1;
                if chars.get(i + 1) == Some(&'/') {
                    i += 1;
                    re.push_str("(?:.*/)?");
                } else {
                    re.push_str(".*");
                }
            }
            '*' => re.push_str("[^/]*"),
            '?' => re.push_str("[^/]"),
            '{' => {
                depth += 1;
                re.push_str("(?:");
            }
            '}' if depth > 0 => {
                depth -= 1;
                re.push(')');
            }
            ',' if depth > 0 => re.push('|'),
            other => re.push_str(&regex::escape(&other.to_string())),
        }
        i += 1;
    }
    re.push('$');
    regex::Regex::new(&re).map_err(|e| HandError::new("fs.bad_pattern", e.to_string()))
}

/// Files under `root` (depth first, sorted), skipping SKIP_DIRS and symlinks.
fn walk(root: &Path, mut visit: impl FnMut(&Path, &str) -> bool) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        let mut items: Vec<_> = rd.flatten().collect();
        items.sort_by_key(|e| std::cmp::Reverse(e.file_name()));
        for e in items {
            let Ok(ft) = e.file_type() else { continue };
            let p = e.path();
            if ft.is_dir() {
                if !SKIP_DIRS.contains(&e.file_name().to_string_lossy().as_ref())
                    && !SKIP_ROOTS.iter().any(|r| p == Path::new(r))
                {
                    stack.push(p);
                }
            } else if ft.is_file() {
                let rel = p.strip_prefix(root).unwrap_or(&p).to_string_lossy().replace('\\', "/");
                if !visit(&p, &rel) {
                    return;
                }
            }
        }
    }
}

pub fn glob(root: &Path, pattern: &str, limit: Option<usize>) -> Result<Value, HandError> {
    let re = glob_regex(pattern)?;
    let limit = limit.unwrap_or(DEFAULT_LIMIT).min(MAX_LIST);
    let mut paths: Vec<String> = Vec::new();
    let mut truncated = false;
    walk(root, |_, rel| {
        if re.is_match(rel) {
            if paths.len() == limit {
                truncated = true;
                return false;
            }
            paths.push(rel.to_owned());
        }
        true
    });
    paths.sort();
    Ok(json!({ "root": root, "paths": paths, "truncated": truncated }))
}

pub fn grep(
    root: &Path,
    pattern: &str,
    glob_pattern: Option<&str>,
    limit: Option<usize>,
) -> Result<Value, HandError> {
    let re =
        regex::Regex::new(pattern).map_err(|e| HandError::new("fs.bad_pattern", e.to_string()))?;
    let only = glob_pattern.map(glob_regex).transpose()?;
    let limit = limit.unwrap_or(DEFAULT_LIMIT).min(MAX_LIST);
    let mut hits = Vec::new();
    let mut truncated = false;
    let single: Option<PathBuf> = root.is_file().then(|| root.to_path_buf());
    let mut scan = |p: &Path, rel: &str| -> bool {
        if only.as_ref().is_some_and(|g| !g.is_match(rel)) {
            return true;
        }
        let Ok(Some(text)) = read_text(p) else { return true };
        for (n, line) in text.lines().enumerate() {
            if re.is_match(line) {
                if hits.len() == limit {
                    truncated = true;
                    return false;
                }
                let shown: String = line.chars().take(400).collect();
                hits.push(json!({ "path": rel, "line": n + 1, "text": shown }));
            }
        }
        true
    };
    match single {
        Some(f) => {
            let name = f.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            scan(&f, &name);
        }
        None => walk(root, scan),
    }
    Ok(json!({ "root": root, "matches": hits, "truncated": truncated }))
}
