//! The feature routes: lines whose `cmd` a feature module answers before the
//! `Command` parse. Each module exports its own `ROUTES`;
//! [`MODULE_ROUTES`] is the one list of them, and [`find`] picks the one
//! route a line's `cmd` names, so no route scans a line for a substring
//! to learn whether it is its own. Chrome's receivers are found by name the
//! same way (`mojo/public/cpp/bindings/lib/multiplex_router.cc`): the
//! router reads the header and hands the message to its one endpoint.
//!
//! A route's entry decodes the line once itself, or reads its params from
//! the head ([`RequestHead::params`]). A migration edits only its module's
//! `ROUTES`.
//!
//! A `cmux.protocol/2` line names an `operation`, not a `cmd`. The
//! operations outside the operation catalog that a module answers (the page
//! router's routed namespaces, spec/page-router.json) are found the same
//! way, by name in the module's own table: [`OPERATION_ROUTES`] lists those
//! modules and [`find_operation`] picks the one route an `operation` names.
//!
//! Most route names are not in spec/sdk-schema.json yet, so the generated
//! v12 table (`cmux_ipc::methods`) cannot resolve them: [`find`] looks a
//! `cmd` up in a name map built once from every route's exact names, and
//! only a `cmd` no exact name holds tries the prefixes of the families
//! whose names are open (`agent-session-`, `apps-`, ...).

use std::collections::HashMap;
use std::sync::{Arc, LazyLock};

use super::{FrameStage, MessageWriter, Mux, RequestHead};

/// The line a route's entry answers, with the head the frame read.
pub(super) struct RouteLine<'l> {
    pub(super) mux: &'l Arc<Mux>,
    pub(super) client: u64,
    pub(super) message: &'l str,
    pub(super) writer: &'l MessageWriter,
    #[expect(dead_code, reason = "read by the typed handlers that decode only params")]
    pub(super) head: &'l RequestHead<'l>,
}

/// A route's entry: answers the line and returns `Some(keep_open)`, or
/// `None` when the line is not one of its requests after all (the `Command`
/// parse then answers it).
pub(super) type RouteEntry = fn(&RouteLine<'_>) -> Option<bool>;

/// The `cmd` names a route answers.
#[derive(Clone, Copy, Debug)]
pub(super) enum RouteName {
    Exact(&'static str),
    /// Every name of a module's command list.
    OneOf(&'static [&'static str]),
    /// Every `cmd` that starts with this family prefix and that no exact
    /// name holds.
    Prefix(&'static str),
}

impl RouteName {
    /// The exact names this holds (none for a prefix).
    pub(super) fn exact(&self) -> &[&'static str] {
        match self {
            Self::Exact(name) => std::slice::from_ref(name),
            Self::OneOf(names) => names,
            Self::Prefix(_) => &[],
        }
    }

    fn prefix(self) -> Option<&'static str> {
        match self {
            Self::Prefix(prefix) => Some(prefix),
            Self::Exact(_) | Self::OneOf(_) => None,
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

/// Every module's routes. An exact name belongs to one route and two
/// prefixes never overlap (`connection_frame_routes_names_are_disjoint`).
pub(super) const MODULE_ROUTES: &[&[Route]] = &[
    #[cfg(any(debug_assertions, feature = "oracle"))]
    super::oracle_state_command::ROUTES,
    #[cfg(any(debug_assertions, feature = "bench"))]
    super::debug_crash_inject::ROUTES,
    super::loopback_forward::ROUTES,
    super::energy_op::ROUTES,
    super::frontend_visibility::ROUTES,
    super::memory_limit::ROUTES,
    #[cfg(unix)]
    super::browser_runtime::ROUTES,
    #[cfg(unix)]
    super::agent_session_attach::agent_session_observe::ROUTES,
    #[cfg(unix)]
    super::agent_session_attach::ROUTES,
    #[cfg(unix)]
    super::agent_transfer::access_requests::ROUTES,
    #[cfg(unix)]
    super::agent_transfer::agent_update::ROUTES,
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

/// The route `cmd` names, if any: the one that holds it exactly, else the
/// one whose family prefix it starts with.
pub(super) fn find(cmd: &str) -> Option<&'static Route> {
    static EXACT: LazyLock<HashMap<&'static str, &'static Route>> = LazyLock::new(|| {
        all()
            .flat_map(|route| {
                route.names.iter().flat_map(RouteName::exact).map(move |name| (*name, route))
            })
            .collect()
    });
    EXACT.get(cmd).copied().or_else(|| {
        all().find(|route| {
            route
                .names
                .iter()
                .filter_map(|name| name.prefix())
                .any(|prefix| cmd.starts_with(prefix))
        })
    })
}

/// Every route.
pub(super) fn all() -> impl Iterator<Item = &'static Route> {
    MODULE_ROUTES.iter().flat_map(|routes| routes.iter())
}

/// One v2 operation route: operations outside the operation catalog that a
/// module's own table names.
pub(super) struct OperationRoute {
    /// Whether the module's table names `operation`.
    pub(super) names: fn(&str) -> bool,
    /// The stage the request watchdog names while the entry runs.
    pub(super) stage: FrameStage,
    pub(super) entry: RouteEntry,
}

/// Every module's v2 operation routes. No operation is named by two
/// routes, and none is a catalog operation
/// (`connection_frame_page_routed_operations_are_not_catalog_operations`).
pub(super) const OPERATION_ROUTES: &[&[OperationRoute]] = &[
    super::page_router::OPERATION_ROUTES,
    // A held v2 handler for the sequencing tests.
    #[cfg(test)]
    super::connection_frame::sequenced_lines_tests::OPERATION_ROUTES,
];

/// The v2 operation route that names `operation`, if any.
pub(super) fn find_operation(operation: &str) -> Option<&'static OperationRoute> {
    OPERATION_ROUTES.iter().flat_map(|routes| routes.iter()).find(|route| (route.names)(operation))
}
