//! What the checkout readers ([`super::devcontainer`], [`super::compose`], [`super::nix`]) share:
//! the checkout's repo read from `.git` files, a JSONC reader, the secret-name rule, and the
//! idempotent install steps their `[setup]` lines start with.

use std::path::Path;

use crate::plan::{Repo, Source, SourceKind};

/// Installs docker when the machine lacks it (AutoCloud images bake it in; a custom image may not).
pub const ENSURE_DOCKER: &str =
    "command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sudo sh";

/// Installs mise when absent. Every mise step puts `~/.local/bin` on `PATH` itself, since each
/// `[setup]` line runs in a shell of its own.
pub const ENSURE_MISE: &str = "command -v mise >/dev/null 2>&1 || [ -x \"$HOME/.local/bin/mise\" ] || curl -fsSL https://mise.run | sh";

/// `mise use -g TOOL@VERSION`, runnable right after [`ENSURE_MISE`].
pub fn mise_use(tool: &str, version: &str) -> String {
    format!("export PATH=\"$HOME/.local/bin:$PATH\" && mise use -g {tool}@{version}")
}

/// `apt-get install` of packages, quiet and idempotent.
pub fn apt_install(packages: &str) -> String {
    format!(
        "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq {packages}"
    )
}

/// A source for a checkout reader: labelled by the folder's name, keyed by its path.
pub fn checkout_source(kind: SourceKind, root: &Path) -> Source {
    let prefix = match kind {
        SourceKind::Devcontainer => "devcontainer",
        SourceKind::Compose => "compose",
        SourceKind::Nix => "nix",
        _ => "checkout",
    };
    Source { kind, label: folder_name(root), id: format!("{prefix}:{}", root.display()) }
}

/// The checkout folder's own name ("project" when it has none).
pub fn folder_name(root: &Path) -> String {
    root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "project".into())
}

/// The checkout's repo from its `.git` files (no `git` process): `origin`'s URL with any login
/// removed and the branch `HEAD` names. A checkout with no `.git` folder is carried as files.
pub fn repo_at(root: &Path) -> Repo {
    let mut repo = Repo { path: Some(root.display().to_string()), ..Repo::default() };
    let git = root.join(".git");
    let git_dir = if git.is_dir() {
        git
    } else if let Ok(text) = std::fs::read_to_string(&git)
        && let Some(dir) = text.trim().strip_prefix("gitdir:")
    {
        let dir = Path::new(dir.trim());
        if dir.is_absolute() { dir.to_path_buf() } else { root.join(dir) }
    } else {
        return repo;
    };
    if let Ok(head) = std::fs::read_to_string(git_dir.join("HEAD")) {
        repo.branch = head.trim().strip_prefix("ref: refs/heads/").map(str::to_owned);
    }
    // A linked worktree keeps its config in the common dir.
    let common = std::fs::read_to_string(git_dir.join("commondir"))
        .ok()
        .map(|c| git_dir.join(c.trim()))
        .unwrap_or(git_dir);
    if let Ok(config) = std::fs::read_to_string(common.join("config")) {
        repo.url = origin_url(&config).map(|u| crate::plan::strip_login(&u));
    }
    repo
}

fn origin_url(config: &str) -> Option<String> {
    let mut in_origin = false;
    for line in config.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_origin = line.replace(' ', "") == "[remote\"origin\"]";
            continue;
        }
        if in_origin
            && let Some((key, value)) = line.split_once('=')
            && key.trim() == "url"
        {
            return Some(value.trim().to_owned());
        }
    }
    None
}

/// Whether a variable's name says it holds a secret: its value never enters a plan.
pub fn looks_secret(name: &str) -> bool {
    let upper = name.to_ascii_uppercase();
    ["PASSWORD", "PASSWD", "SECRET", "TOKEN", "KEY", "PRIVATE", "CREDENTIAL"]
        .iter()
        .any(|w| upper.contains(w))
}

/// Whether a value carries a login (`scheme://user:pass@host`): treated as a secret whatever its
/// name.
pub fn value_has_login(value: &str) -> bool {
    value
        .split_once("://")
        .and_then(|(_, rest)| rest.split_once('@'))
        .is_some_and(|(auth, _)| auth.contains(':') && !auth.contains('/'))
}

/// The variable names a `.env` file sets, never its values.
pub fn dotenv_keys(text: &str) -> Vec<String> {
    let mut keys = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        if let Some((key, _)) = line.split_once('=') {
            let key = key.trim();
            if is_env_name(key) && !keys.iter().any(|k| k == key) {
                keys.push(key.to_owned());
            }
        }
    }
    keys
}

pub fn is_env_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// The variables a shell-style value reads: `$X`, `${X}`, `${X:-default}`, `${X?err}`.
pub fn shell_refs(value: &str) -> Vec<String> {
    let mut refs = Vec::new();
    let bytes = value.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'$' {
            if bytes.get(i + 1) == Some(&b'$') {
                i += 2;
                continue;
            }
            let braced = bytes.get(i + 1) == Some(&b'{');
            let start = if braced { i + 2 } else { i + 1 };
            let mut end = start;
            while end < bytes.len() && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_') {
                end += 1;
            }
            let name = &value[start..end];
            if is_env_name(name) && !refs.iter().any(|r| r == name) {
                refs.push(name.to_owned());
            }
            i = end.max(i + 1);
        } else {
            i += 1;
        }
    }
    refs
}

/// One word for `bash`: left bare when it is plain, else single-quoted.
pub fn sh_quote(word: &str) -> String {
    if !word.is_empty()
        && word.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:@%+,".contains(c))
    {
        word.to_owned()
    } else {
        format!("'{}'", word.replace('\'', "'\\''"))
    }
}

/// A path relative to the checkout root, `/`-separated, for a `[setup]` line (which runs in the
/// checkout).
pub fn rel(root: &Path, path: &Path) -> String {
    let rel = path.strip_prefix(root).unwrap_or(path);
    let mut parts: Vec<String> = Vec::new();
    for c in rel.components() {
        match c {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                if parts.last().is_some_and(|p| p != "..") {
                    parts.pop();
                } else {
                    parts.push("..".into());
                }
            }
            c => parts.push(c.as_os_str().to_string_lossy().into_owned()),
        }
    }
    if parts.is_empty() { ".".into() } else { parts.join("/") }
}

/// JSON with comments and trailing commas (devcontainer.json, devbox.json) as plain JSON.
pub fn parse_jsonc(text: &str) -> Result<serde_json::Value, String> {
    serde_json::from_str(&strip_jsonc(text)).map_err(|e| e.to_string())
}

/// Removes `//` and `/* */` comments and trailing commas, leaving strings alone.
pub fn strip_jsonc(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '"' {
            out.push(c);
            i += 1;
            while i < chars.len() {
                let c = chars[i];
                out.push(c);
                i += 1;
                if c == '\\' {
                    if let Some(&next) = chars.get(i) {
                        out.push(next);
                        i += 1;
                    }
                } else if c == '"' {
                    break;
                }
            }
        } else if c == '/' && chars.get(i + 1) == Some(&'/') {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
        } else if c == '/' && chars.get(i + 1) == Some(&'*') {
            i += 2;
            while i < chars.len() && !(chars[i] == '*' && chars.get(i + 1) == Some(&'/')) {
                if chars[i] == '\n' {
                    out.push('\n');
                }
                i += 1;
            }
            i += 2;
        } else {
            out.push(c);
            i += 1;
        }
    }
    // Trailing commas: a comma followed only by whitespace and then `}` or `]` (strings are
    // skipped again so a literal ",]" inside one stays).
    let chars: Vec<char> = out.chars().collect();
    let mut clean = String::with_capacity(out.len());
    let mut i = 0;
    let mut in_string = false;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            clean.push(c);
            if c == '\\' {
                if let Some(&next) = chars.get(i + 1) {
                    clean.push(next);
                    i += 1;
                }
            } else if c == '"' {
                in_string = false;
            }
        } else if c == '"' {
            in_string = true;
            clean.push(c);
        } else if c == ',' {
            let mut j = i + 1;
            while j < chars.len() && chars[j].is_whitespace() {
                j += 1;
            }
            if !matches!(chars.get(j), Some('}') | Some(']')) {
                clean.push(c);
            }
        } else {
            clean.push(c);
        }
        i += 1;
    }
    clean
}
