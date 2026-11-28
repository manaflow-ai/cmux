//! The two path rules a spawn uses: `~` expansion (`NSString.expandingTildeInPath`) and a folder's
//! name (`WorkspaceSpawn.folderName`).

/// `path` with a leading `~` (alone, or followed by `/`) replaced by `home`, as
/// `NSString.expandingTildeInPath` does for the person's own home. An expanded path loses its
/// trailing slashes (`~/` is `home`), as NSString's path methods give it. `~user` and any other
/// path come back as they are: the app never names another user's home here.
pub fn expand_tilde(path: &str, home: &str) -> String {
    let rest = if path == "~" {
        ""
    } else if let Some(rest) = path.strip_prefix("~/") {
        rest
    } else {
        return path.to_owned();
    };
    let home = trim_trailing_slashes(home);
    let joined = if rest.is_empty() { home.to_owned() } else { format!("{home}/{rest}") };
    trim_trailing_slashes(&joined).to_owned()
}

fn trim_trailing_slashes(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() && path.starts_with('/') { "/" } else { trimmed }
}

/// The components of `path` once `.` is dropped and `..` takes back the one before it
/// (`URL.standardizedFileURL`). A relative `path` is first put under `base` (the process's
/// folder, as `URL(fileURLWithPath:)` resolves it); with no `base` it stays relative.
pub fn standardized_components(path: &str, base: Option<&str>) -> Vec<String> {
    let full = match base {
        Some(base) if !path.starts_with('/') => format!("{base}/{path}"),
        _ => path.to_owned(),
    };
    let mut parts: Vec<String> = Vec::new();
    for part in full.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.last().is_some_and(|last| last != "..") {
                    parts.pop();
                } else if !full.starts_with('/') {
                    parts.push("..".to_owned());
                }
            }
            other => parts.push(other.to_owned()),
        }
    }
    parts
}

/// A folder's name for a workspace opened on it (`WorkspaceSpawn.folderName`): the last component of
/// the standardized path, trimmed of whitespace and newlines; nil for the root, an empty name, or a
/// relative path that standardizes to nothing. `base` resolves a relative path (see
/// [`standardized_components`]).
pub fn folder_name(directory: &str, base: Option<&str>) -> Option<String> {
    let parts = standardized_components(directory, base);
    let last = parts.last()?;
    let name = last.trim();
    if name.is_empty() || name == "/" || name == ".." { None } else { Some(name.to_owned()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tilde_expands_only_the_persons_home() {
        assert_eq!(expand_tilde("~", "/Users/a"), "/Users/a");
        assert_eq!(expand_tilde("~/", "/Users/a"), "/Users/a");
        assert_eq!(expand_tilde("~/src/x", "/Users/a/"), "/Users/a/src/x");
        assert_eq!(expand_tilde("~/src/x/", "/Users/a"), "/Users/a/src/x");
        assert_eq!(expand_tilde("~bob/x", "/Users/a"), "~bob/x");
        assert_eq!(expand_tilde("/tmp/~", "/Users/a"), "/tmp/~");
        assert_eq!(expand_tilde("", "/Users/a"), "");
        assert_eq!(expand_tilde("~", "/"), "/");
    }

    #[test]
    fn folder_name_is_the_standardized_last_component() {
        assert_eq!(folder_name("/Users/a/proj", None).as_deref(), Some("proj"));
        assert_eq!(folder_name("/Users/a/proj/", None).as_deref(), Some("proj"));
        assert_eq!(folder_name("/Users/a/proj/./", None).as_deref(), Some("proj"));
        assert_eq!(folder_name("/Users/a/proj/sub/..", None).as_deref(), Some("proj"));
        assert_eq!(folder_name("/Users/a/  spaced  ", None).as_deref(), Some("spaced"));
        assert_eq!(folder_name("/", None), None);
        assert_eq!(folder_name("/..", None), None);
        assert_eq!(folder_name("/a/   ", None), None);
        assert_eq!(folder_name("proj", Some("/work")).as_deref(), Some("proj"));
        assert_eq!(folder_name("..", Some("/work/x")).as_deref(), Some("work"));
    }
}
