//! Op dispatch: name and alias lookup, origin rules, idempotency, then the
//! op group (`machine`, `snapshot`, `plan`, `migration`, `auth`).

mod auth;
mod declared;
mod delete_retry;
mod machine;
mod machine_projection;
mod migration;
mod plan;
mod snapshot;

pub use declared::{backend_ops, declared_errors};
pub use machine_projection::{Projection, WatchEvent};

use crate::api::{CloudError, ControlPlane, Ctx, Ledger, Origin, Request, codes, upstream_key};
use crate::rescue::iface::OpenToken;
use serde_json::Value;
use std::sync::Arc;

/// How an op is guarded before it runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// `class: read`: no idempotency key.
    Read,
    /// `class: mutation`: an idempotency key is required.
    Mutation,
    /// A destructive or money mutation: also only for origin `user`
    /// (contract 1.1: the host stamps it after its native confirmation).
    UserOnly,
}

/// Every op of `catalog/cloud-catalog.json` this server serves.
const OPS: &[(&str, Kind)] = &[
    ("cloud.auth.status", Kind::Read),
    ("cloud.machine.list", Kind::Read),
    ("cloud.machine.watch", Kind::Read),
    ("cloud.machine.get", Kind::Read),
    // Create and resize spend money (resize may go up; only the plan knows),
    // delete destroys: a person confirms them (contract 1.1).
    ("cloud.machine.create", Kind::UserOnly),
    ("cloud.machine.rename", Kind::Mutation),
    ("cloud.machine.start", Kind::Mutation),
    ("cloud.machine.pause", Kind::Mutation),
    ("cloud.machine.resize", Kind::UserOnly),
    ("cloud.machine.delete", Kind::UserOnly),
    ("cloud.machine.idle_policy.set", Kind::Mutation),
    ("cloud.machine.connect_info", Kind::Read),
    ("cloud.snapshot.list", Kind::Read),
    ("cloud.snapshot.create", Kind::Mutation),
    // A restore makes a new machine: it costs money like create.
    ("cloud.snapshot.restore", Kind::UserOnly),
    ("cloud.snapshot.delete", Kind::UserOnly),
    ("cloud.plan.get", Kind::Read),
    ("cloud.billing.checkout", Kind::UserOnly),
    // Classic migration (contract 4): one way per user, then per machine.
    ("cloud.migration.status", Kind::Read),
    ("cloud.migration.start", Kind::UserOnly),
    ("cloud.machine.upgrade", Kind::UserOnly),
    // Attach (crate::link): connect may start a paused machine, so all three
    // are mutations with a key.
    ("cloud.machine.connect", Kind::Mutation),
    ("cloud.machine.disconnect", Kind::Mutation),
    ("cloud.rescue.open", Kind::Mutation),
    // Files (crate::fs): reads through the Cloud API file routes; remove is
    // destructive, so only a person may run it.
    ("cloud.fs.list", Kind::Read),
    ("cloud.fs.stat", Kind::Read),
    ("cloud.fs.read", Kind::Read),
    ("cloud.fs.write", Kind::Mutation),
    ("cloud.fs.mkdir", Kind::Mutation),
    ("cloud.fs.remove", Kind::UserOnly),
    // Transfers read or write any local file the server can: a person picks
    // the path (native file panel), never an agent.
    ("cloud.file.push", Kind::UserOnly),
    ("cloud.file.pull", Kind::UserOnly),
    // Stopping a transfer only stops work a person started: no gesture.
    ("cloud.file.transfer.list", Kind::Read),
    ("cloud.file.transfer.cancel", Kind::Mutation),
    // Ports and browser routes (crate::ports).
    ("cloud.port.list", Kind::Read),
    ("cloud.port.forward", Kind::Mutation),
    ("cloud.port.close", Kind::Mutation),
    ("cloud.browser.open", Kind::Mutation),
];

/// Other names for ops: the `resume` verb and the old relay names
/// (`backend/catalog/cloud-relay-operations.json`). The catalog fragment has
/// no `aliases` field yet, so this table is the only place they live.
const ALIASES: &[(&str, &str)] = &[
    ("cloud.machine.resume", "cloud.machine.start"),
    ("vm.list", "cloud.machine.list"),
    ("vm.get", "cloud.machine.get"),
    ("vm.create", "cloud.machine.create"),
    ("vm.update", "cloud.machine.rename"),
    ("vm.start", "cloud.machine.start"),
    ("vm.resume", "cloud.machine.start"),
    ("vm.pause", "cloud.machine.pause"),
    ("vm.resize", "cloud.machine.resize"),
    ("vm.delete", "cloud.machine.delete"),
    ("vm.snapshot.list", "cloud.snapshot.list"),
    ("vm.snapshot.create", "cloud.snapshot.create"),
    ("vm.snapshot.restore", "cloud.snapshot.restore"),
    ("vm.snapshot.delete", "cloud.snapshot.delete"),
];

/// The canonical catalog name of `op`: the fragment name (`cloud.…`), the
/// full name (`cmux.cloud.…`) or an alias.
pub fn canonical_name(op: &str) -> Option<&'static str> {
    let short = op.strip_prefix("cmux.").unwrap_or(op);
    let short = ALIASES.iter().find(|(alias, _)| *alias == short).map_or(short, |(_, name)| name);
    OPS.iter().find(|(name, _)| *name == short).map(|(name, _)| *name)
}

/// Every canonical op name the server serves, in catalog order.
pub fn op_names() -> impl Iterator<Item = &'static str> {
    OPS.iter().map(|(name, _)| *name)
}

/// How the catalog guards an op: `(mutation, user_only)`; `None` for an
/// unknown op. Tests compare it with the fragment's `class` and `gesture`.
pub fn op_policy(name: &str) -> Option<(bool, bool)> {
    OPS.iter().find(|(n, _)| *n == name).map(|(_, k)| (*k != Kind::Read, *k == Kind::UserOnly))
}

/// The relay names take `vm_id` and `snapshot_id`; the fragment ops take
/// `machine` and `snapshot` (a snapshot restore or delete needs only the
/// snapshot).
fn relay_args(called: &str, name: &str, args: &Value) -> Value {
    let (true, Value::Object(map)) = (called.starts_with("vm."), args) else {
        return args.clone();
    };
    let mut out = serde_json::Map::new();
    for (k, v) in map {
        let k = match k.as_str() {
            "vm_id" => "machine",
            "snapshot_id" => "snapshot",
            other => other,
        };
        if matches!(name, "cloud.snapshot.restore" | "cloud.snapshot.delete") && k == "machine" {
            continue;
        }
        out.insert(k.to_owned(), v.clone());
    }
    Value::Object(out)
}

/// Machine mutations whose result carries the projection `revision` its
/// change reached, so a client settles its intent when its mirror has seen
/// that revision on `cloud.machine.watch` (no refetch). Deletes keep their
/// `{deleted: true}` result; the `removed` event for the id settles them.
const REVISION_RESULTS: &[&str] = &[
    "cloud.machine.create",
    "cloud.machine.rename",
    "cloud.machine.start",
    "cloud.machine.pause",
    "cloud.machine.resize",
    "cloud.machine.idle_policy.set",
    "cloud.machine.upgrade",
    "cloud.snapshot.restore",
];

/// Ops that need the host's `open_token` (stamped after the user's
/// gesture). The op itself checks it; a ledger replay checks it too.
const TOKEN_OPS: &[&str] = &["cloud.rescue.open"];

/// A request that passed the guards: its canonical name, its args (relay
/// names mapped), and its trimmed key (`Some` exactly for mutations).
pub(crate) struct Admitted {
    pub(crate) name: &'static str,
    pub(crate) args: Value,
    pub(crate) key: Option<String>,
}

/// The guards every op passes before it runs: a known name, the origin
/// rule, and the key rule of its class.
pub(crate) fn admit(request: &Request) -> Result<Admitted, CloudError> {
    let name = canonical_name(&request.op).ok_or_else(|| {
        CloudError::new(codes::UNKNOWN_OP, format!("{} is not a Cloud op", request.op))
    })?;
    let kind = kind_of(name);
    let args = relay_args(&request.op, name, &request.args);
    let key = request.idempotency_key.as_deref().map(str::trim).filter(|k| !k.is_empty());
    if kind == Kind::UserOnly && request.origin != Origin::User {
        return Err(CloudError::new(
            codes::ORIGIN_REFUSED,
            format!("{name} needs a person: confirm it in cmux"),
        ));
    }
    if kind == Kind::Read {
        if key.is_some() {
            return Err(CloudError::new(
                codes::IDEMPOTENCY_KEY_FORBIDDEN,
                format!("{name} is a read and takes no idempotency key"),
            ));
        }
        return Ok(Admitted { name, args, key: None });
    }
    let key = key.ok_or_else(|| {
        CloudError::new(codes::IDEMPOTENCY_KEY_REQUIRED, format!("{name} needs an idempotency key"))
    })?;
    if key.len() > 128 {
        return Err(CloudError::invalid("an idempotency key has at most 128 characters"));
    }
    Ok(Admitted { name, args, key: Some(key.to_owned()) })
}

fn kind_of(name: &str) -> Kind {
    OPS.iter().find(|(n, _)| *n == name).map_or(Kind::Read, |(_, k)| *k)
}

/// The Cloud app server: the only writer of the machine projection on this
/// machine. One request at a time.
pub struct Server<C> {
    control_plane: C,
    projection: Projection,
    ledger: Ledger,
    attach: crate::link::Attach,
    edge: crate::ports::Edge,
    /// Host-only ops this server sent and their answers (crate::api::host).
    host: crate::api::host::HostRequests,
}

impl<C> Server<C> {
    pub fn attach(&self) -> &crate::link::Attach {
        &self.attach
    }

    pub fn attach_mut(&mut self) -> &mut crate::link::Attach {
        &mut self.attach
    }
}

impl<C: ControlPlane> Server<C> {
    /// A server with no link configuration (attach ops answer typed errors).
    pub fn new(control_plane: C) -> Self {
        Self::with_attach(control_plane, crate::link::Attach::unconfigured())
    }

    pub fn with_attach(control_plane: C, attach: crate::link::Attach) -> Self {
        Self::with_parts(control_plane, attach, crate::ports::Edge::real())
    }

    /// A server with its attach state and its files and ports edge (tests
    /// pass fakes for the link, the tunnel and the transfer).
    pub fn with_parts(
        control_plane: C,
        attach: crate::link::Attach,
        mut edge: crate::ports::Edge,
    ) -> Self {
        // The pinned host keys are read once, at start.
        if let Some(path) = attach.env().known_hosts_path() {
            edge.load_known_hosts(path);
        }
        Self {
            control_plane,
            projection: Projection::default(),
            ledger: Ledger::default(),
            attach,
            edge,
            host: crate::api::host::HostRequests::default(),
        }
    }

    /// Host-only requests this server sent (`cmux.host.*`).
    pub(crate) fn host_requests(&mut self) -> &mut crate::api::host::HostRequests {
        &mut self.host
    }

    /// `host.request` frames to send to the host, in order.
    pub fn take_host_frames(&mut self) -> Vec<Value> {
        self.host.take_outbox()
    }

    /// The forward and route state with the link state it follows.
    pub(crate) fn edge_parts(&mut self) -> (&mut crate::ports::Edge, &crate::link::LinkSupervisor) {
        self.attach.supervisor.pump();
        (&mut self.edge, &self.attach.supervisor)
    }

    /// Closes forwards and routes whose link went down or was replaced, by
    /// the link state as last pumped: the serve loop pumps and sends the
    /// link events first, so each close follows the change that caused it.
    pub fn reconcile_edge(&mut self) {
        self.edge.reconcile(&self.attach.supervisor);
    }

    /// Blocks until every running file transfer has ended (embedders and
    /// tests; the serve loop never blocks on a copy).
    pub fn wait_transfers(&mut self) {
        self.edge.transfers.wait_all();
    }

    /// `cloud.file.transfer.changed` events: transfers that ended since the
    /// last call, in the order they ended.
    pub fn take_transfer_events(&mut self) -> Vec<crate::fs::TransferEvent> {
        self.edge.transfers.take_events()
    }

    /// Wakes the serve loop after each link event and each transfer end.
    pub(crate) fn set_wake(&mut self, wake: crate::link::LinkWake) {
        self.attach.supervisor_mut().set_wake(Arc::clone(&wake));
        self.edge.transfers.set_wake(wake);
    }

    /// Forwards and routes closed by link state since the last call.
    pub fn take_edge_events(&mut self) -> Vec<crate::ports::EdgeDown> {
        self.edge.take_events()
    }

    /// One Cloud API call context for an attach op.
    pub(crate) fn ctx<'a>(&'a mut self, op: &'a str, key: Option<&'a str>) -> Ctx<'a, C> {
        Ctx::new(&mut self.control_plane, &mut self.projection, op, key)
    }

    pub fn control_plane(&self) -> &C {
        &self.control_plane
    }

    pub fn control_plane_mut(&mut self) -> &mut C {
        &mut self.control_plane
    }

    pub fn projection(&self) -> &Projection {
        &self.projection
    }

    /// `cloud.machine.watch` events since the last call, in order, for the
    /// host.
    pub fn take_events(&mut self) -> Vec<WatchEvent> {
        self.projection.take_events()
    }

    /// Link events for the host lines (`cloud.link.changed`) since the
    /// last call, in order.
    pub fn take_link_events(&mut self) -> Vec<crate::connector::iface::CarrierEvent> {
        self.attach.take_host_link_events()
    }

    /// Applies one team wire event (`cloud.machine.upsert`,
    /// `cloud.machine.removed`; other Cloud events change no machine) to
    /// the projection by revision (`crate::api::events`).
    pub fn team_event(&mut self, event: &str, data: &Value) -> Result<(), CloudError> {
        crate::api::events::apply(&mut self.projection, event, data)
    }

    /// Runs one request.
    pub fn handle(&mut self, request: &Request) -> Result<Value, CloudError> {
        let Admitted { name, args, key } = admit(request)?;
        let Some(key) = key.as_deref() else {
            return self.run(name, &args, request, None);
        };
        if crate::link::ops::live_state_op(name)
            || crate::ports::live_state_op(name)
            || crate::fs::live_state_op(name)
        {
            // The answer is live state (a carrier, a forward or a
            // transfer): a replay of an old answer would be stale. These
            // ops are idempotent by themselves, so they run every time.
            let upstream = upstream_key(name, &args, key);
            return self.run(name, &args, request, Some(&upstream));
        }
        if let Some(done) = self.ledger.replay(key, name, &args)? {
            // The host's open token is never cached: a replay of an op that
            // needs one answers only a request that carries one.
            if TOKEN_OPS.contains(&name) {
                let token = request.open_token.clone().unwrap_or_else(|| OpenToken(String::new()));
                token.check().map_err(crate::link::ops::backend_error)?;
            }
            return Ok(done);
        }
        self.ledger.attempt(key, name, &args);
        // The caller's key goes to the backend unchanged: the backend's
        // ledger compares the op and params itself (`idempotency.conflict`),
        // and a retry after an unknown outcome must carry the same key
        // (delete_retry.rs).
        match self.run(name, &args, request, Some(key)) {
            Ok(mut result) => {
                // Recorded with the result, so a same-key replay answers the
                // same revision and emits nothing new.
                if REVISION_RESULTS.contains(&name)
                    && let Value::Object(fields) = &mut result
                {
                    fields.insert("revision".into(), self.projection.revision().into());
                }
                self.ledger.succeed(key, result.clone());
                Ok(result)
            }
            // Bad args never changed anything: the key stays free for the fix.
            Err(error) if error.code == codes::INVALID_ARGS => {
                self.ledger.forget(key);
                Err(error)
            }
            // The attempt stays open: the same-key retry reaches the backend.
            Err(error) if delete_retry::indeterminate(&error) => {
                Err(delete_retry::retry_with_same_key(name, error))
            }
            Err(error) => Err(error),
        }
    }

    fn run(
        &mut self,
        name: &str,
        args: &Value,
        request: &Request,
        key: Option<&str>,
    ) -> Result<Value, CloudError> {
        let origin = request.origin;
        if crate::link::ops::serves(name) {
            let token = request.open_token.as_ref();
            return crate::link::ops::run(self, name, args, origin, key, token);
        }
        if crate::fs::serves(name) {
            return crate::fs::run(self, name, args, origin, key);
        }
        if crate::ports::serves(name) {
            return crate::ports::run(self, name, args, origin, key);
        }
        let mut ctx = Ctx::new(&mut self.control_plane, &mut self.projection, name, key)
            .with_origin(request.origin);
        let group = name.split('.').nth(1).unwrap_or_default();
        match group {
            "auth" => auth::run(&mut ctx, name, args),
            _ if name == "cloud.machine.upgrade" => migration::run(&mut ctx, name, args),
            "machine" => machine::run(&mut ctx, name, args),
            "snapshot" => snapshot::run(&mut ctx, name, args),
            "plan" | "billing" => plan::run(&mut ctx, name, args),
            "migration" => migration::run(&mut ctx, name, args),
            _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
        }
    }
}
