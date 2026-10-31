//! `park-tabs` (`tab-park-v1`): end the shells of terminal tabs but keep the
//! tabs, as keep-layout tabs (`kept_tabs`), so each starts again only when a
//! frontend restarts it (`restart-tab`, `tab-restart-kept-layout-v1`). The
//! classic migration parks the workspaces it brings over in the background,
//! so a session with more terminals than macOS has PTYs comes over whole and
//! each terminal starts when its workspace is first shown
//! (plans/cmux-next/classic-migration-DESIGN.md).

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

/// Records the tabs as kept, then asks each shell to exit. Answers with the
/// surfaces whose terminal was parked; each shows dead with
/// `relaunch: {cwd}` once its host exited.
pub(super) fn park(mux: &Arc<Mux>, params: Params) -> anyhow::Result<Value> {
    let surfaces = resolve_tab_refs(mux, &params.surfaces)?;
    let parked = mux.park_terminal_tabs(&surfaces)?;
    Ok(json!({ "parked": parked }))
}
