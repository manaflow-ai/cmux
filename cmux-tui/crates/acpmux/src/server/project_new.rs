//! `_acpmux/project_new {name}`: a new, empty project for a chat to build in.
//! The New Tab's New project (webviews `newtab/newProject.ts`) asks for one,
//! then starts its chat there. The folder is made in the person's projects
//! folder (`~/Projects`, else the first of `~/projects`, `~/Developer`,
//! `~/code` and `~/src` that exists, else a new `~/Projects`), under `name`,
//! or `name-2` and on when that is taken; never an existing folder. It gets an
//! empty git repository (`git init`), and acpmux's record trusts it, as a
//! Trust click would: the person made it for this chat. The answer is
//! `{cwd, name, git}`; when `git init` fails no folder is left and the request
//! fails, since the chat was promised a repository.
//!
//! Only over the local unix socket and from the app's agent pane
//! (`Origin::LocalApp`), as a worktree (`new_worktree.rs`): a Web client or a
//! peer makes no folder on this machine and records no trust here, and neither
//! does the phone, whose prompts reach the local socket stamped `via: cloud-mobile`
//! by the mobile relay (`remote_guard::cloud_mobile`).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};

use super::Origin;
use crate::hub::Hub;
use crate::rpc::RpcError;

/// The longest name kept; the web shortens what it derives from a prompt well under this.
const NAME_MAX: usize = 64;
/// `name-2` through `name-9999`; past that the person picks another name (the error says so).
const SUFFIX_MAX: u32 = 9999;
/// The projects folders tried, in order, under the home folder; the first is made when none is there.
const PROJECT_ROOTS: [&str; 5] = ["Projects", "projects", "Developer", "code", "src"];

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    params: &Value,
) -> Result<Value, RpcError> {
    if !allowed(origin, params) {
        return Err(RpcError::invalid_params(
            "a project folder is made only from the app or the local unix socket",
        )
        .with_data(json!({"reason": "project_new.origin_refused"})));
    }
    let name = params.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
    if !valid_name(&name) {
        return Err(RpcError::invalid_params(
            "name must be 1 to 64 letters, digits, '.', '_' or '-', not starting with '.' or '-'",
        )
        .with_data(json!({"reason": "project_new.name"})));
    }
    let home = dirs::home_dir().ok_or_else(|| RpcError::internal("no home directory"))?;
    let gate = hub.trust_gate();
    let made = tokio::task::spawn_blocking(move || -> Result<PathBuf, String> {
        let paths = gate.or_else(crate::trust::Paths::current).ok_or("no home directory")?;
        let cwd = make(&projects_root(&home), &name)?;
        if let Err(failure) = crate::trust::set(&paths, &cwd.to_string_lossy(), "trusted") {
            // The folder is the one just made, empty but for its new repository: take it back, so
            // a retry makes `name` again instead of leaving `name` behind and making `name-2`.
            let _ = std::fs::remove_dir_all(&cwd);
            return Err(match failure {
                crate::trust::Failure::Invalid(message)
                | crate::trust::Failure::Record(message) => message,
            });
        }
        Ok(cwd)
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?
    .map_err(|e| RpcError::invalid_params(format!("no project folder: {e}")))?;
    // A start waiting on this folder's Trust card goes on (`hub/trust_wait.rs`).
    hub.trust_changed();
    let cwd = made;
    let name = cwd.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    Ok(json!({"cwd": cwd, "name": name, "git": true}))
}

/// The app's pane, or the local socket for someone at this Mac: not a Web client, a peer,
/// or the phone through the local mobile relay.
fn allowed(origin: Origin, params: &Value) -> bool {
    match origin {
        Origin::LocalApp => true,
        Origin::Local => !super::remote_guard::cloud_mobile(params),
        Origin::Web | Origin::Peer => false,
    }
}

/// A folder name that stays one plain path component: no separator, no `..`, no hidden or
/// option-like first character.
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= NAME_MAX
        && !name.starts_with('.')
        && !name.starts_with('-')
        && name.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
}

/// The first projects folder under `home` that exists, else `home/Projects`.
fn projects_root(home: &Path) -> PathBuf {
    PROJECT_ROOTS
        .iter()
        .map(|root| home.join(root))
        .find(|root| root.is_dir())
        .unwrap_or_else(|| home.join(PROJECT_ROOTS[0]))
}

/// Makes `root/name` (or the first free `name-N`), canonical, with an empty git repository in it.
/// When `git init` fails the folder just made is taken back.
fn make(root: &Path, name: &str) -> Result<PathBuf, String> {
    std::fs::create_dir_all(root).map_err(|e| format!("{}: {e}", root.display()))?;
    let mut made = None;
    for n in 1..=SUFFIX_MAX {
        let folder = if n == 1 { root.join(name) } else { root.join(format!("{name}-{n}")) };
        // create_dir, not create_dir_all: an existing folder is never taken over.
        match std::fs::create_dir(&folder) {
            Ok(()) => {
                made = Some(folder);
                break;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("{}: {e}", folder.display())),
        }
    }
    let folder = made.ok_or_else(|| {
        format!("{name} through {name}-{SUFFIX_MAX} are taken: choose another name")
    })?;
    let folder = std::fs::canonicalize(&folder).unwrap_or(folder);
    let git = git_init(&folder, std::env::vars_os().map(|(key, _)| key))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if !git {
        // Only the folder made above, empty: `git init` wrote nothing that worked.
        let _ = std::fs::remove_dir_all(&folder);
        return Err("git init failed: is git installed?".to_owned());
    }
    Ok(folder)
}

/// `git init` in `folder`, without Git's own variables of the daemon's environment (`inherited`):
/// `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and the rest would point it at another repository.
fn git_init(
    folder: &Path,
    inherited: impl IntoIterator<Item = std::ffi::OsString>,
) -> std::process::Command {
    let mut init = std::process::Command::new("git");
    for key in inherited {
        if key.to_string_lossy().starts_with("GIT_") {
            init.env_remove(key);
        }
    }
    init.args(["init", "-q"]).current_dir(folder);
    init
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-project-new-{tag}-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn project_new_refuses_the_phone_web_and_peers() {
        let plain = json!({"name": "app"});
        let phone = json!({"name": "app", "_meta": {"acpmux": {"via": "cloud-mobile"}}});
        assert!(allowed(Origin::LocalApp, &plain));
        assert!(allowed(Origin::Local, &plain));
        assert!(!allowed(Origin::Local, &phone), "the mobile relay's phone prompt makes no folder");
        assert!(!allowed(Origin::Web, &plain));
        assert!(!allowed(Origin::Peer, &plain));
    }

    #[test]
    fn project_new_names_stay_one_plain_folder() {
        for good in ["habit-tracker", "a", "Notes_2.0", &"x".repeat(NAME_MAX)] {
            assert!(valid_name(good), "{good}");
        }
        let long = "x".repeat(NAME_MAX + 1);
        for bad in
            ["", ".", "..", ".git", "-rf", "a/b", "../up", "a b", "émoji", "a\0b", long.as_str()]
        {
            assert!(!valid_name(bad), "{bad:?}");
        }
    }

    #[test]
    fn project_new_makes_a_git_repo_and_never_takes_an_existing_folder() {
        let root = scratch("make");
        std::fs::create_dir(root.join("habit-tracker")).unwrap();
        std::fs::write(root.join("habit-tracker").join("keep.txt"), "mine").unwrap();
        let cwd = make(&root, "habit-tracker").unwrap();
        assert_eq!(cwd.file_name().unwrap(), "habit-tracker-2");
        assert!(cwd.join(".git").is_dir());
        // The taken folder is untouched.
        assert_eq!(
            std::fs::read_to_string(root.join("habit-tracker").join("keep.txt")).unwrap(),
            "mine"
        );
        let third = make(&root, "habit-tracker").unwrap();
        assert_eq!(third.file_name().unwrap(), "habit-tracker-3");
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn project_new_git_init_drops_the_daemons_git_variables() {
        let inherited = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "HOME", "PATH"]
            .map(std::ffi::OsString::from);
        let init = git_init(Path::new("/tmp/x"), inherited);
        let removed: Vec<_> = init
            .get_envs()
            .filter(|(_, value)| value.is_none())
            .map(|(key, _)| key.to_owned())
            .collect();
        assert_eq!(
            removed,
            ["GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"].map(std::ffi::OsString::from)
        );
        assert_eq!(init.get_current_dir(), Some(Path::new("/tmp/x")));
    }

    #[test]
    fn project_new_root_is_the_first_projects_folder_there() {
        let home = scratch("root");
        assert_eq!(projects_root(&home), home.join("Projects"));
        std::fs::create_dir(home.join("code")).unwrap();
        assert_eq!(projects_root(&home), home.join("code"));
        std::fs::create_dir(home.join("Developer")).unwrap();
        assert_eq!(projects_root(&home), home.join("Developer"));
        std::fs::remove_dir_all(&home).unwrap();
    }
}
