//! The feature routes: lines whose `cmd` a feature module answers before the
//! `Command` parse (p05-ipc-062). Each module exports its own `ROUTES`;
//! [`MODULE_ROUTES`] is the one list of them, and [`find`] picks the one
//! route a line's `cmd` names, so no route scans a line for a substring
//! to learn whether it is its own. Chrome's receivers are found by name the
//! same way (`mojo/public/cpp/bindings/lib/multiplex_router.cc`): the
//! router reads the header and hands the message to its one endpoint.
//!
//! A module that has not moved to typed handlers yet (p05-ipc-063..070)
//! is reached through its entry, `try_handle`, which still parses the line
//! once itself. A migration edits only its module's `ROUTES`.

use std::sync::Arc;

use super::{FrameStage, MessageWriter, Mux};

/// A route's entry: answers the line and returns `Some(keep_open)`, or
/// `None` when the line is not one of its requests after all (the `Command`
/// parse then answers it).
pub(super) type RouteEntry = fn(&Arc<Mux>, u64, &str, &MessageWriter) -> Option<bool>;

/// The `cmd` names a route answers.
#[derive(Clone, Copy, Debug)]
pub(super) enum RouteName {
    Exact(&'static str),
    /// Every `cmd` that starts with this family prefix.
    Prefix(&'static str),
}

impl RouteName {
    fn matches(self, cmd: &str) -> bool {
        match self {
            Self::Exact(name) => cmd == name,
            Self::Prefix(prefix) => cmd.starts_with(prefix),
        }
    }
}

/// One feature route.
pub(super) struct Route {
    pub(super) names: &'static [RouteName],
    /// The stage the request watchdog names while the entry runs.
    pub(super) stage: FrameStage,
    pub(super) entry: RouteEntry,
}

/// Every module's routes. A `cmd` names at most one route
/// (`routes_names_are_disjoint` in the tests).
pub(super) const MODULE_ROUTES: &[&[Route]] = &[
    #[cfg(any(debug_assertions, feature = "oracle"))]
    super::oracle_state_command::ROUTES,
    super::loopback_forward::ROUTES,
    #[cfg(unix)]
    super::browser_runtime::ROUTES,
    #[cfg(unix)]
    super::agent_session_attach::ROUTES,
    #[cfg(unix)]
    super::agent_transfer::ROUTES,
    #[cfg(unix)]
    super::agent_inventory::ROUTES,
    #[cfg(unix)]
    super::agent_cli_job::ROUTES,
    #[cfg(unix)]
    super::agent_cli_intents::ROUTES,
    #[cfg(unix)]
    super::agent_inventory::watch::ROUTES,
    #[cfg(unix)]
    super::connection_frame::machine_catalog::ROUTES,
    #[cfg(unix)]
    super::apps::ROUTES,
    #[cfg(unix)]
    super::scripts::ROUTES,
    #[cfg(unix)]
    super::fs_wire::ROUTES,
];

/// The route `cmd` names, if any.
pub(super) fn find(cmd: &str) -> Option<&'static Route> {
    MODULE_ROUTES
        .iter()
        .flat_map(|routes| routes.iter())
        .find(|route| route.names.iter().any(|name| name.matches(cmd)))
}

/// Every route, for the tests.
#[cfg(test)]
pub(super) fn all() -> impl Iterator<Item = &'static Route> {
    MODULE_ROUTES.iter().flat_map(|routes| routes.iter())
}
