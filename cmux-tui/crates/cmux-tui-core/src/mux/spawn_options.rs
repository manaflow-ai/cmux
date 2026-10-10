//! How a placement command starts its terminal, and the caller-minted ids
//! of a pane creation (`split-client-keys-v1`,
//! plans/cmux-next/remote-state-ownership.md S1).

use std::sync::Arc;

use crate::Surface;
use crate::resource::{ResourceError, TabPublicId, TabResourceIdentity, TerminalPublicId};

/// Creation fields carrying the caller-minted public ids of a new pane and
/// of its tab.
pub(crate) const CLIENT_PANE_ID_FIELD: &str = "pane_id";
pub(crate) const CLIENT_TAB_ID_FIELD: &str = "tab_id";

/// How to start the terminal a placement command creates.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TerminalSpawnOptions {
    pub cwd: Option<String>,
    /// Extra environment for the new terminal's child only.
    pub env: Vec<(String, String)>,
    /// Caller-chosen terminal host id (32 lowercase hex, UUIDv4), so the
    /// caller can put it in `env` before the child starts.
    pub terminal_id: Option<String>,
    /// The program and arguments to run instead of the bare default shell
    /// (`terminal-shell-args-v1` resolves `shell_args` into it).
    pub argv: Option<Vec<String>>,
    /// `split-client-keys-v1`: the caller-minted public ids of the new pane
    /// (`pane_<32 hex>`) and of its tab (`tab_<32 hex>`). Only pane
    /// creations (`split`, `new-pane`, `new-pane-right`) read them.
    pub pane_id: Option<String>,
    pub tab_id: Option<String>,
}

impl TerminalSpawnOptions {
    pub fn new(cwd: Option<String>, env: Vec<(String, String)>) -> Self {
        Self { cwd, env, ..Self::default() }
    }
}

/// A pane creation's tab surface and whether a retry of the same keyed
/// request returned the first result.
pub struct PaneSurfaceCreation {
    pub surface: Arc<Surface>,
    pub replayed: bool,
}

/// A new terminal tab identity under the caller's tab id, else a random one.
pub(crate) fn terminal_identity(
    tab_id: Option<TabPublicId>,
) -> Result<TabResourceIdentity, ResourceError> {
    let tab_id = match tab_id {
        Some(tab_id) => tab_id,
        None => TabPublicId::random()?,
    };
    Ok(TabResourceIdentity::persisted_terminal(tab_id, TerminalPublicId::random()?))
}
