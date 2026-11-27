//! The Mac's project remotes, read where its folders actually exist.
//!
//! The app forwards this catalog over its existing authenticated machine
//! link before Cloud chat startup and repo actions. A Cloud machine stores
//! only repository names, never the Mac's paths or remote credentials, so
//! an agent there resolves names from the same catalog as the app.

use std::collections::HashSet;
use std::path::Path;
use std::time::{Duration, Instant};

use cmux_git::run::{self, GitFailure};
use serde_json::{Value, json};

use crate::Mux;

const CATALOG_DEADLINE: Duration = Duration::from_secs(5);
const REMOTE_DEADLINE: Duration = Duration::from_millis(500);
const MAX_REMOTE_BYTES: usize = 64 * 1024;

/// A visible project list's GitHub remotes, in project recency order.
///
/// `complete: false` means a bounded git read timed out or was truncated;
/// callers keep the last complete catalog and ask to retry instead of
/// replacing it with a partial list that could silently resolve a name to
/// the wrong repository. A missing or non-git project is a normal skip.
pub(crate) fn local_catalog(mux: &Mux) -> anyhow::Result<Value> {
    let projects = mux.read_registry_state(|connection| {
        crate::state::projects_store::list_value(connection, false, None, None)
    })?;
    let paths: Vec<&str> = projects
        .get("projects")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|project| project.get("path").and_then(Value::as_str))
        .collect();
    let deadline = Instant::now() + CATALOG_DEADLINE;
    Ok(catalog(&paths, |path| read_remote(path, deadline)))
}

fn read_remote(path: &str, deadline: Instant) -> RemoteRead {
    // Recent folders may have moved or been removed since project.observe.
    // spawn() reports a missing cwd as Unavailable, which must not make a
    // stale recent entry block every future complete catalog forever.
    match std::fs::metadata(path) {
        Ok(metadata) if !metadata.is_dir() => return RemoteRead::Absent,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return RemoteRead::Absent,
        Err(_) => return RemoteRead::Incomplete,
        Ok(_) => {}
    }

    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return RemoteRead::Incomplete;
    }
    // No network or executable repository configuration: cmux-git's
    // read runner strips GIT_* and disables hooks, transports and
    // fsmonitor. --local excludes unrelated user-level remote entries.
    match run::run_git_within(
        Path::new(path),
        &[],
        &["config", "--local", "--null", "--get-regexp", r"^remote\..*\.url$"],
        MAX_REMOTE_BYTES,
        remaining.min(REMOTE_DEADLINE),
    ) {
        Ok(output) if output.truncated => RemoteRead::Incomplete,
        Ok(output) => RemoteRead::Config(output.stdout),
        Err(GitFailure::TimedOut | GitFailure::Unavailable(_)) => RemoteRead::Incomplete,
        Err(GitFailure::Exit(_)) => RemoteRead::Absent,
    }
}

enum RemoteRead {
    Config(Vec<u8>),
    Absent,
    Incomplete,
}

fn catalog(paths: &[&str], mut read: impl FnMut(&str) -> RemoteRead) -> Value {
    let mut seen = HashSet::new();
    let mut repos = Vec::new();
    for path in paths {
        let data = match read(path) {
            RemoteRead::Config(data) => data,
            RemoteRead::Absent => continue,
            RemoteRead::Incomplete => return json!({"repos": repos, "complete": false}),
        };
        // `git config --null --get-regexp` separates key and value by
        // newline, records by NUL; a newline inside a value is not a URL.
        for record in data.split(|byte| *byte == 0) {
            let Some(newline) = record.iter().position(|byte| *byte == b'\n') else { continue };
            let Some(value) = record.get(newline + 1..) else { continue };
            let Ok(remote) = std::str::from_utf8(value) else { continue };
            let Some(name) = github_name(remote) else { continue };
            if seen.insert(name.to_ascii_lowercase()) {
                // A remote does not reveal visibility. Treat it as private
                // conservatively until the connector supplies that fact.
                repos.push(json!({"fullName": name, "private": true, "source": "local"}));
            }
        }
    }
    json!({"repos": repos, "complete": true})
}

/// Accept GitHub's HTTPS, SSH URL and scp-like remote forms only. The
/// return value cannot contain host credentials, query strings or paths.
fn github_name(remote: &str) -> Option<String> {
    if remote.bytes().any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control()) {
        return None;
    }
    let path = if let Some(path) = remote.strip_prefix("git@github.com:") {
        path.to_owned()
    } else {
        let url = url::Url::parse(remote).ok()?;
        if !matches!(url.scheme(), "https" | "ssh")
            || !url.host_str()?.eq_ignore_ascii_case("github.com")
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || url.port().is_some()
            || (url.scheme() == "https" && !url.username().is_empty())
            || (url.scheme() == "ssh" && !matches!(url.username(), "" | "git"))
        {
            return None;
        }
        url.path().strip_prefix('/')?.to_owned()
    };
    let path = path.strip_suffix(".git").unwrap_or(&path);
    let (owner, name) = path.split_once('/')?;
    if owner.is_empty()
        || owner.len() > 39
        || !owner.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        || name.is_empty()
        || name.len() > 100
        || matches!(name, "." | "..")
        || !name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-._".contains(&byte))
    {
        return None;
    }
    Some(format!("{owner}/{name}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cloud_repo_local_parses_github_remotes_without_transmitting_credentials() {
        for remote in [
            "https://github.com/Manaflow-AI/cmux.git",
            "git@github.com:Manaflow-AI/cmux.git",
            "ssh://git@github.com/Manaflow-AI/cmux.git",
        ] {
            assert_eq!(github_name(remote).as_deref(), Some("Manaflow-AI/cmux"));
        }
        for remote in [
            "https://github.com.attacker.test/o/r.git",
            "https://github.com@attacker.test/o/r.git",
            "https://secret@github.com/o/r.git",
            "https://u:secret@github.com/o/r.git",
            "https://github.com/o/r?token=secret",
            "https://github.com/o/r#secret",
            "git@github.com:o/../r",
            "git@github.com:o/r\nsecret",
            "file:///tmp/o/r",
            "https://gitlab.com/o/r",
        ] {
            assert_eq!(github_name(remote), None, "{remote}");
        }
    }

    #[test]
    fn cloud_repo_local_keeps_project_priority_and_all_github_remotes() {
        let result = catalog(&["recent", "missing", "older"], |path| {
            match path {
            "recent" => RemoteRead::Config(
                b"remote.origin.url\ngit@github.com:o/r.git\0remote.upstream.url\nhttps://github.com/upstream/r.git\0".to_vec(),
            ),
            "missing" => RemoteRead::Absent,
            _ => RemoteRead::Config(
                b"remote.origin.url\nhttps://github.com/O/R.git\0remote.extra.url\nhttps://github.com/other/tool.git\0".to_vec(),
            ),
        }
        });
        assert_eq!(result["complete"], true);
        assert_eq!(
            result["repos"],
            json!([
                {"fullName":"o/r", "private":true, "source":"local"},
                {"fullName":"upstream/r", "private":true, "source":"local"},
                {"fullName":"other/tool", "private":true, "source":"local"}
            ])
        );
        assert!(!result.to_string().contains("older"));
    }

    #[test]
    fn cloud_repo_local_never_presents_timed_out_scan_as_complete() {
        let mut reads = 0;
        let result = catalog(&["slow", "later"], |_| {
            reads += 1;
            RemoteRead::Incomplete
        });
        assert_eq!(reads, 1);
        assert_eq!(result, json!({"repos":[],"complete":false}));
    }

    #[test]
    fn cloud_repo_local_deleted_recent_folder_does_not_block_catalog() {
        let path = std::env::temp_dir()
            .join(format!("cmux-repo-deleted-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir(&path).unwrap();
        std::fs::remove_dir(&path).unwrap();
        let result = catalog(&[path.to_str().unwrap()], |path| {
            read_remote(path, Instant::now() + CATALOG_DEADLINE)
        });
        assert_eq!(result, json!({"repos":[],"complete":true}));
    }
}
