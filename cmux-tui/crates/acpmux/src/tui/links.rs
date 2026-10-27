//! Links in transcript rows: URLs and file paths become OSC 8 hyperlinks
//! (Cmd-click in Ghostty, iTerm2, kitty, WezTerm, tmux ≥ 3.4) and open on
//! Ctrl-click or Alt-click inside acpmux, which also understands
//! `path:line` and opens it in `$ACPMUX_EDITOR` when set.

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    /// Column range in the row, in display cells.
    pub start: usize,
    pub end: usize,
    /// The URL, or the path as written (may carry `:line`).
    pub target: String,
}

fn is_url_start(s: &str) -> bool {
    s.starts_with("http://")
        || s.starts_with("https://")
        || s.starts_with("file://")
        || s.starts_with("ssh://")
}

/// Does this token read as a file path? Absolute, home, relative with a
/// slash, or a bare `name.ext` with a known source extension.
fn looks_like_path(tok: &str) -> bool {
    let core = tok.split(':').next().unwrap_or(tok);
    if core.len() < 2 {
        return false;
    }
    if core.starts_with('/')
        || core.starts_with("~/")
        || core.starts_with("./")
        || core.starts_with("../")
    {
        return core.len() > 1 && !core.ends_with('/');
    }
    if core.contains('/') && !core.contains("//") {
        // `and/or` and `3/4` are words; `src/main.rs` and `a/b/c` are paths.
        let segs: Vec<&str> = core.split('/').collect();
        let has_ext = segs.last().map(|l| l.contains('.') && !l.starts_with('.')).unwrap_or(false);
        let has_alpha = core.chars().any(|c| c.is_alphabetic());
        return has_alpha
            && (has_ext || segs.len() >= 3)
            && core
                .chars()
                .all(|c| c.is_alphanumeric() || matches!(c, '/' | '.' | '_' | '-' | '+' | '@'));
    }
    if let Some(ext) = Path::new(core).extension().and_then(|e| e.to_str()) {
        let known = [
            "rs", "ts", "tsx", "js", "jsx", "py", "go", "md", "json", "toml", "yaml", "yml",
            "html", "css", "sh", "swift", "c", "h", "cpp", "hpp", "java", "kt", "rb", "sql", "txt",
            "lock", "mjs", "cjs",
        ];
        return known.contains(&ext)
            && core.chars().all(|c| c.is_alphanumeric() || matches!(c, '.' | '_' | '-'));
    }
    false
}

/// Trim punctuation that a sentence leaves stuck to a token.
fn trim_token(tok: &str) -> &str {
    let t = tok.trim_end_matches(['.', ',', ';', ':', ')', ']', '}', '"', '\'', '>', '`']);

    (t.trim_start_matches(['(', '[', '{', '"', '\'', '<', '`'])) as _
}

/// Find links in one row of text. Columns count display cells.
pub fn find(text: &str) -> Vec<Link> {
    let mut out = Vec::new();
    let mut col = 0usize;
    let mut start_col = 0usize;
    let mut tok = String::new();
    let flush = |tok: &mut String, start_col: usize, out: &mut Vec<Link>| {
        if tok.is_empty() {
            return;
        }
        let lead = tok.len() - tok.trim_start_matches(['(', '[', '{', '"', '\'', '<', '`']).len();
        let t = trim_token(tok);
        if !t.is_empty() && (is_url_start(t) || looks_like_path(t)) {
            let lead_cols =
                unicode_width::UnicodeWidthStr::width(tok.get(..lead).unwrap_or_default());
            let w = unicode_width::UnicodeWidthStr::width(t);
            out.push(Link {
                start: start_col + lead_cols,
                end: start_col + lead_cols + w,
                target: t.to_owned(),
            });
        }
        tok.clear();
    };
    for ch in text.chars() {
        let w = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        if ch.is_whitespace() {
            flush(&mut tok, start_col, &mut out);
            col += w;
            continue;
        }
        if tok.is_empty() {
            start_col = col;
        }
        tok.push(ch);
        col += w;
    }
    flush(&mut tok, start_col, &mut out);
    out
}

/// Split `path:line[:col]` into the path and the line.
pub fn split_line(target: &str) -> (&str, Option<u32>) {
    if is_url_start(target) {
        return (target, None);
    }
    let Some((rest, last)) = target.rsplit_once(':') else { return (target, None) };
    let Ok(n) = last.parse::<u32>() else { return (target, None) };
    // `path:12:5` → try once more for the line.
    if let Some((path, l2)) = rest.rsplit_once(':')
        && let Ok(line) = l2.parse::<u32>()
    {
        return (path, Some(line));
    }
    (rest, Some(n))
}

/// Absolute path for a path token, relative to the session's directory.
pub fn resolve(path: &str, cwd: &str) -> PathBuf {
    if let Some(rest) = path.strip_prefix("~/") {
        return dirs::home_dir().unwrap_or_default().join(rest);
    }
    let p = Path::new(path);
    if p.is_absolute() {
        return p.to_path_buf();
    }
    Path::new(cwd).join(p)
}

/// The OSC 8 target: the URL itself, or a `file://` URL for a path.
pub fn href(target: &str, cwd: &str) -> String {
    if is_url_start(target) {
        return target.to_owned();
    }
    let (path, _) = split_line(target);
    format!("file://{}", resolve(path, cwd).display())
}

/// A run of cells drawn this frame that should carry a hyperlink.
#[derive(Debug, Clone)]
pub struct LinkCell {
    pub x: u16,
    pub y: u16,
    pub text: String,
    pub href: String,
}

/// Open a link: URLs with the system opener; paths in `$ACPMUX_EDITOR`
/// (`code -g`, `zed`, `vim`…) when set, else the system opener.
pub fn open(target: &str, cwd: &str) -> String {
    let opener = if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
    if is_url_start(target) {
        let _ = std::process::Command::new(opener).arg(target).spawn();
        return format!("opened {target}");
    }
    let (path, line) = split_line(target);
    let abs = resolve(path, cwd);
    if let Ok(editor) = std::env::var("ACPMUX_EDITOR").or_else(|_| std::env::var("VISUAL")) {
        let mut parts = editor.split_whitespace();
        if let Some(bin) = parts.next() {
            let mut cmd = std::process::Command::new(bin);
            cmd.args(parts);
            let base = bin.rsplit('/').next().unwrap_or(bin);
            match (base, line) {
                ("code" | "code-insiders" | "cursor" | "windsurf", Some(l)) => {
                    cmd.arg("-g").arg(format!("{}:{l}", abs.display()));
                }
                ("zed", Some(l)) | ("subl", Some(l)) | ("hx", Some(l)) => {
                    cmd.arg(format!("{}:{l}", abs.display()));
                }
                ("vim" | "nvim" | "vi" | "emacs" | "nano", Some(l)) => {
                    cmd.arg(format!("+{l}")).arg(&abs);
                }
                _ => {
                    cmd.arg(&abs);
                }
            }
            let _ = cmd.spawn();
            return format!("opened {} in {base}", abs.display());
        }
    }
    let _ = std::process::Command::new(opener).arg(&abs).spawn();
    format!("opened {}", abs.display())
}

#[cfg(test)]
mod tests {
    use super::split_line;

    #[test]
    fn split_line_reads_path_line_and_col() {
        assert_eq!(split_line("src/main.rs:12"), ("src/main.rs", Some(12)));
        assert_eq!(split_line("src/main.rs:12:5"), ("src/main.rs", Some(12)));
        assert_eq!(split_line("src/main.rs"), ("src/main.rs", None));
        assert_eq!(split_line("https://x.dev:8080"), ("https://x.dev:8080", None));
    }

    /// A bare number in a transcript (`42`) is a token with no `:`: it is no
    /// path and line, never a slice before the start of the text.
    #[test]
    fn split_line_takes_a_bare_number_as_no_line() {
        assert_eq!(split_line("42"), ("42", None));
        assert_eq!(split_line(":7"), ("", Some(7)));
    }
}
