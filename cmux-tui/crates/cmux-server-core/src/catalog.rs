//! The `server.*` operations of server.md 13 as static data, for the
//! operation catalog generator (CLI, MCP, palette).
//!
//! `host.revoke` is in the table because it shares the revoke flow;
//! `server.db.backup.status` comes from server.md 8.4.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Owner {
    /// The local `server` supervisor (or one of its roles, named).
    Local(&'static str),
    TeamDo,
    PairingDo,
    /// Local start, finished by a Durable Object.
    LocalAndPairingDo,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Risk {
    Read,
    Mutate,
    /// Removes data or access; policy decided at the owner (server.md 12).
    Destructive,
}

/// MCP exposure (server.md 13, column MCP).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mcp {
    Default,
    OptIn,
    /// The agent may request it; the user approves in the feed.
    Approval,
    Never,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ServerOp {
    pub name: &'static str,
    pub owner: Owner,
    /// CLI path under `cmux`; `None` when exempt (app or installer path).
    pub cli: Option<&'static str>,
    pub risk: Risk,
    pub mcp: Mcp,
    /// Only `origin: user` may run it (never an agent or MCP).
    pub user_origin_only: bool,
}

const fn op(
    name: &'static str,
    owner: Owner,
    cli: Option<&'static str>,
    risk: Risk,
    mcp: Mcp,
) -> ServerOp {
    let user_origin_only = matches!(mcp, Never);
    ServerOp { name, owner, cli, risk, mcp, user_origin_only }
}

use Mcp::{Approval, Never, OptIn};
use Owner::{Local, LocalAndPairingDo, TeamDo};
use Risk::{Destructive, Mutate, Read};

pub static SERVER_OPS: &[ServerOp] = &[
    op("server.status", Local("server"), Some("server status"), Read, Mcp::Default),
    op("server.up", Local("server"), Some("server up"), Mutate, OptIn),
    op("server.down", Local("server"), Some("server down"), Mutate, OptIn),
    op("server.install", Local("server"), Some("server install"), Mutate, Never),
    op("server.uninstall", Local("server"), Some("server uninstall"), Destructive, Never),
    op("server.upgrade", Local("updater"), Some("server upgrade"), Mutate, OptIn),
    op("server.rollback", Local("updater"), Some("server rollback"), Mutate, OptIn),
    op("server.pin", Local("updater"), Some("server pin"), Mutate, OptIn),
    op("server.roles.set", Local("server"), Some("server roles set"), Mutate, OptIn),
    op("server.pair.begin", LocalAndPairingDo, Some("server pair"), Mutate, Never),
    op("server.pair.status", LocalAndPairingDo, Some("server pair status"), Read, Never),
    op("server.pair.approve", TeamDo, Some("servers add"), Mutate, Never),
    op("server.enroll_self", TeamDo, None, Mutate, Never),
    op("server.unpair", Local("server"), Some("server unpair"), Destructive, Never),
    op("host.revoke", TeamDo, Some("servers revoke"), Destructive, Never),
    op("server.health.get", Local("health"), Some("server health"), Read, Mcp::Default),
    op("server.health.fix", Local("health"), Some("server health fix"), Mutate, Never),
    op("server.health.revert", Local("health"), Some("server health revert"), Mutate, Never),
    op("server.db.list", Local("postgres"), Some("server db list"), Read, Mcp::Default),
    op("server.db.url", Local("postgres"), Some("server db url"), Read, Mcp::Default),
    op("server.db.create", Local("postgres"), Some("server db create"), Mutate, OptIn),
    op("server.db.drop", Local("postgres"), Some("server db drop"), Destructive, Never),
    op("server.db.limits.set", Local("postgres"), Some("server db limits set"), Mutate, Never),
    op("server.db.backup", Local("postgres"), Some("server db backup"), Mutate, Never),
    op(
        "server.db.backup.status",
        Local("postgres"),
        Some("server db backup status"),
        Read,
        Mcp::Default,
    ),
    op("server.db.restore", Local("postgres"), Some("server db restore"), Destructive, Never),
    op("server.db.upgrade", Local("postgres"), Some("server db upgrade"), Destructive, Never),
    op("server.db.expose", Local("postgres"), Some("server db expose"), Mutate, Never),
    op("server.app.list", Local("apps"), Some("server app list"), Read, Mcp::Default),
    op("server.app.logs", Local("apps"), Some("server app logs"), Read, Mcp::Default),
    op("server.app.start", Local("apps"), Some("server app start"), Mutate, OptIn),
    op("server.app.stop", Local("apps"), Some("server app stop"), Mutate, OptIn),
    op("server.app.restart", Local("apps"), Some("server app restart"), Mutate, OptIn),
    op("server.app.deploy", Local("apps"), Some("server app deploy"), Mutate, OptIn),
    op("server.software.list", Local("server"), Some("server software list"), Read, Mcp::Default),
    op(
        "server.software.install",
        Local("server"),
        Some("server software install"),
        Mutate,
        Approval,
    ),
    op(
        "server.software.remove",
        Local("server"),
        Some("server software remove"),
        Destructive,
        Approval,
    ),
    op(
        "server.software.system_install",
        Local("server"),
        Some("server software system-install"),
        Mutate,
        Approval,
    ),
];

pub fn find(name: &str) -> Option<&'static ServerOp> {
    SERVER_OPS.iter().find(|o| o.name == name)
}
