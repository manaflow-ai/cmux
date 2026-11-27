//! Issue 57201: a folder of clones swaps each clone's `.git` to the machine (the projection's
//! nested-repository pass, [`start`]).

use std::path::{Path, PathBuf};
use std::sync::{Arc, PoisonError};

use super::Projected;

/// Issue 57201: the clones in folders below the projected folder at `at` (a folder of clones,
/// itself no repository) swap their `.git` to a machine repository of their own, from their
/// public remote and only what the Mac has unpushed
/// (`cmux_projection::git_swap::run_nested`), so `git` there reads no pack over the Mac's link.
/// In the background, shallowest first, and timed; a pass already running is left to finish.
/// Off with the folder's own swap (`CMUX_PROJECTION_GIT_SWAP=off`, or a state folder fs-v1
/// would not follow the link into, [`swap_link_served`]).
pub(super) fn start(projected: &Arc<Projected>, at: &Path, state: &Path) {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    if !cmux_projection::git_swap::enabled() || !swap_link_served(at, state, home.as_deref()) {
        return;
    }
    let swapping = projected.clone();
    let (at, state) = (at.to_path_buf(), state.to_path_buf());
    let _ = std::thread::Builder::new().name("projection-nested-swap".into()).spawn(move || {
        let Ok(_pass) = swapping.nested_swap.try_lock() else { return };
        let overlay = swapping.overlay.clone();
        let forget = |folder: u64| match swapping
            .mounted
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
        {
            Some(mounted) => mounted.forget_entry(folder, ".git"),
            None => Ok(()),
        };
        for repo in cmux_projection::git_swap::nested_repositories(&at) {
            let started = std::time::Instant::now();
            match cmux_projection::git_swap::run_nested(&overlay, &forget, &at, &repo, &state) {
                Ok(outcome) => eprintln!(
                    "cmux projection: {} {repo}/.git: {outcome:?} in {} ms",
                    at.display(),
                    started.elapsed().as_millis()
                ),
                Err(error) => {
                    eprintln!(
                        "cmux projection: {} {repo}/.git stays projected: {error:#}",
                        at.display()
                    );
                }
            }
        }
    });
}

/// Whether fs-v1, rooted at `home`, follows a `.git` link from `at` into `state`: either the folder
/// is not under `home` (fs-v1 does not serve it), or the state folder is under it too, as the
/// default state folder (`~/.local/state`) is. fs-v1 matches its root as given and canonical.
pub(crate) fn swap_link_served(at: &Path, state: &Path, home: Option<&Path>) -> bool {
    let Some(home) = home else { return true };
    let spellings: Vec<PathBuf> = [Some(home.to_path_buf()), std::fs::canonicalize(home).ok()]
        .into_iter()
        .flatten()
        .collect();
    let canonical = std::fs::canonicalize(at).ok();
    let served = spellings.iter().any(|home| {
        at.starts_with(home) || canonical.as_deref().is_some_and(|at| at.starts_with(home))
    });
    !served || spellings.iter().any(|home| state.starts_with(home))
}
