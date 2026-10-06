//! Directory input is resolved against the selected session, never the TUI process cwd.
use super::*;
use std::path::{Path, PathBuf};

pub fn cd_argument(text: &str) -> Option<&str> {
    let text = text.trim();
    if text == "cd" {
        return Some("");
    }
    let rest = text.strip_prefix("cd ").or_else(|| text.strip_prefix("cd\t"))?.trim();
    if rest.contains(['\n', '\r', ';', '|', '&', '`']) || rest.contains("$(") {
        return None;
    }
    Some(rest)
}
/// The value without surrounding whitespace and one pair of matching quotes.
pub fn unquote(value: &str) -> &str {
    let value = value.trim();
    if value.len() >= 2
        && ((value.starts_with('"') && value.ends_with('"'))
            || (value.starts_with('\'') && value.ends_with('\'')))
    {
        &value[1..value.len() - 1]
    } else {
        value
    }
}
pub fn resolve(base: &Path, value: &str, home: &Path, previous: Option<&str>) -> Result<PathBuf> {
    let value = unquote(value);
    let path = match value {
        "-" => PathBuf::from(previous.ok_or_else(|| anyhow::anyhow!("No previous directory yet"))?),
        "~" => home.to_owned(),
        "" => base.to_owned(),
        s if s.starts_with("~/") => home.join(&s[2..]),
        s => base.join(s),
    };
    Ok(path)
}
pub fn children(path: &Path) -> Vec<PathBuf> {
    let mut entries: Vec<_> = std::fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    entries.sort();
    entries
}
impl App {
    pub(super) fn current_directory(&self) -> String {
        self.draft()
            .map(|d| d.cwd.clone())
            .or_else(|| {
                self.selected_session()
                    .and_then(|s| s.get("cwd").and_then(Value::as_str).map(str::to_owned))
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| {
                std::env::current_dir().unwrap_or_default().to_string_lossy().into_owned()
            })
    }
    pub(super) fn remote_directory(&self) -> bool {
        self.draft().and_then(|d| d.peer.as_ref()).is_some()
            || self.selected_session().and_then(|s| s.get("peer").and_then(Value::as_str)).is_some()
    }
    pub(super) fn resolve_directory(&self, path: &str) -> Result<PathBuf> {
        // Unquote first: `cd '~/x'` must not expand the local home remotely.
        if self.remote_directory() && unquote(path).starts_with('~') {
            anyhow::bail!("Use an absolute path on the remote host");
        }
        // `cd -` goes back within this draft, never to another session's path.
        resolve(
            Path::new(&self.current_directory()),
            path,
            &dirs::home_dir().unwrap_or_default(),
            self.draft().and_then(|d| d.previous_cwd.as_deref()),
        )
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cd_keeps_spaced_paths_and_does_not_capture_shell_commands() {
        assert_eq!(cd_argument("cd"), Some(""));
        assert_eq!(cd_argument("cd .."), Some(".."));
        assert_eq!(cd_argument("cd 'My Project'"), Some("'My Project'"));
        assert_eq!(cd_argument("cd ../foo && ls"), None);
        assert_eq!(cd_argument("cdrom test"), None);
        let base = Path::new("/work/repo");
        let home = Path::new("/Users/me");
        assert_eq!(resolve(base, "..", home, None).unwrap(), base.join(".."));
        assert_eq!(resolve(base, "'My Project'", home, None).unwrap(), base.join("My Project"));
        assert_eq!(resolve(base, "~/fun", home, None).unwrap(), home.join("fun"));
        assert_eq!(resolve(base, "-", home, Some("/old")).unwrap(), Path::new("/old"));
        assert!(resolve(base, "-", home, None).is_err());
        assert_eq!(unquote(" '~/p' "), "~/p");
    }
}
