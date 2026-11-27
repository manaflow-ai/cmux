//! `park-tabs` (`tab-park-v1`): end the shells of terminal tabs but keep the
//! tabs, as keep-layout tabs (`kept_tabs`), so each starts again only when a
//! frontend restarts it (`restart-tab`, `tab-restart-kept-layout-v1`). The
//! classic migration parks the workspaces it brings over in the background,
//! so a session with more terminals than macOS has PTYs comes over whole and
//! each terminal starts when its workspace is first shown
//! (plans/cmux-next/classic-migration-DESIGN.md). The app's freeing tier parks
//! idle terminals of hibernated workspaces (`workspaces.freeing.*`).
//!
//! The daemon parks only what is safe to end, whoever asks
//! (`mux/park_eligibility.rs`): a shell idle at its prompt that runs no
//! process at all, or an idle agent with a resumable session. Every other
//! named tab is answered in `refused` with the reason.

use super::*;

/// Advertises `park-tabs`. Unix owners only, as `restart-tab`.
pub(super) const CAPABILITY: &str = "tab-park-v1";

/// `park-tabs`.
#[derive(Deserialize)]
pub(super) struct Params {
    /// The tabs: numeric surface ids or public `tab_...` ids. Tabs that are
    /// not terminals, or whose shell already ended, are left as they are.
    #[serde(alias = "tabs")]
    surfaces: Vec<TabRef>,
}

/// Records the tabs as kept, then asks each shell to exit. A terminal that
/// is not idle (`mux/park_eligibility.rs`: a client attached, kept by
/// `set-terminal-keep`, a process or command running, no prompt, a program
/// status) keeps running. Answers with the surfaces whose terminal was
/// parked, each showing dead with `relaunch: {cwd}` once its host exited,
/// and `refused`: each named surface whose terminal keeps running, with why.
pub(super) fn park(mux: &Arc<Mux>, params: Params) -> anyhow::Result<Value> {
    let surfaces = resolve_tab_refs(mux, &params.surfaces)?;
    let (parked, refused) = mux.park_idle_terminal_tabs(&surfaces, mux.park_tabs_rules())?;
    let refused: Vec<Value> = refused
        .into_iter()
        .map(|(surface, reason)| json!({ "surface": surface, "reason": reason.as_str() }))
        .collect();
    Ok(json!({ "parked": parked, "refused": refused }))
}
