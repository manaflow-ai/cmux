//! Op dispatch: name and alias lookup, origin rules, idempotency, then the
//! op group (`machine`, `snapshot`, `plan`, `auth`, `network`, `domain`).

mod auth;
mod delete_retry;
mod domain;
mod machine;
mod machine_projection;
mod network;
mod network_args;
mod network_firewall;
mod network_models;
mod plan;
mod snapshot;

pub use machine_projection::{Projection, WatchEvent};

use crate::api::{CloudError, ControlPlane, Ctx, Ledger, Origin, Request, codes, upstream_key};
use serde_json::Value;

/// How an op is guarded before it runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// `class: read`: no idempotency key.
    Read,
    /// `class: mutation`: an idempotency key is required.
    Mutation,
    /// A destructive mutation: also only for origin `user`.
    UserOnly,
}

/// Every op of `catalog/cloud-catalog.json` this server serves.
const OPS: &[(&str, Kind)] = &[
    ("cloud.auth.status", Kind::Read),
    ("cloud.machine.list", Kind::Read),
    ("cloud.machine.watch", Kind::Read),
    ("cloud.machine.get", Kind::Read),
    ("cloud.machine.create", Kind::Mutation),
    ("cloud.machine.rename", Kind::Mutation),
    ("cloud.machine.start", Kind::Mutation),
    ("cloud.machine.pause", Kind::Mutation),
    ("cloud.machine.resize", Kind::Mutation),
    ("cloud.machine.delete", Kind::UserOnly),
    ("cloud.machine.stats", Kind::Read),
    ("cloud.machine.idle_policy.set", Kind::Mutation),
    ("cloud.snapshot.list", Kind::Read),
    ("cloud.snapshot.create", Kind::Mutation),
    ("cloud.snapshot.restore", Kind::Mutation),
    ("cloud.snapshot.fork", Kind::Mutation),
    ("cloud.snapshot.delete", Kind::UserOnly),
    ("cloud.plan.get", Kind::Read),
    ("cloud.usage.get", Kind::Read),
    // Attach (crate::link): connect may start a paused machine, so all three
    // are mutations with a key.
    ("cloud.machine.connect", Kind::Mutation),
    ("cloud.machine.disconnect", Kind::Mutation),
    ("cloud.rescue.open", Kind::Mutation),
    // Network, domains and publications (R71 C6). Firewall and publication
    // changes decide what reaches a machine, so only a person makes them.
    ("cloud.network.list", Kind::Read),
    // Attach and a new key give a device a path into the network: a person
    // only (any valid public key would let the caller join as that device).
    ("cloud.tunnel.attach", Kind::UserOnly),
    ("cloud.tunnel.detach", Kind::Mutation),
    ("cloud.tunnel.rotate_key", Kind::UserOnly),
    ("cloud.firewall.list", Kind::Read),
    ("cloud.firewall.get", Kind::Read),
    ("cloud.firewall.create", Kind::UserOnly),
    ("cloud.firewall.delete", Kind::UserOnly),
    ("cloud.domain.list", Kind::Read),
    ("cloud.domain.verify", Kind::Mutation),
    ("cloud.publication.list", Kind::Read),
    ("cloud.publication.create", Kind::UserOnly),
    ("cloud.publication.update", Kind::UserOnly),
    ("cloud.publication.delete", Kind::UserOnly),
    ("cloud.publication.verify", Kind::Mutation),
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
/// `machine` and `snapshot` (a restore needs only the snapshot).
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
        if name == "cloud.snapshot.restore" && k == "machine" {
            continue;
        }
        out.insert(k.to_owned(), v.clone());
    }
    Value::Object(out)
}

/// Machine mutations whose result carries the projection `revision` its
/// change reached, so a client settles its intent when its mirror has seen
/// that revision on `cloud.machine.watch` (no refetch). Deletes keep their
/// `{ok: true}` result; the `removed` event for the id settles them.
const REVISION_RESULTS: &[&str] = &[
    "cloud.machine.create",
    "cloud.machine.rename",
    "cloud.machine.start",
    "cloud.machine.pause",
    "cloud.machine.resize",
    "cloud.snapshot.restore",
    "cloud.snapshot.fork",
];

/// Verify ops read fresh DNS and certificate state (and may take a waiting
/// publication live): a same-key replay of an old answer would be stale, so
/// they run every time, like the live link ops.
const RERUN_OPS: &[&str] = &["cloud.domain.verify", "cloud.publication.verify"];

/// Creates the Cloud API does not dedup by key. After an attempt with no
/// answer (the relay failed), a same-key retry is refused with
/// `outcome_unknown`: the caller lists first. A 4xx answer made nothing, so
/// it frees the key.
const NO_UPSTREAM_DEDUP: &[&str] = &["cloud.firewall.create", "cloud.publication.create"];

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
        edge: crate::ports::Edge,
    ) -> Self {
        Self {
            control_plane,
            projection: Projection::default(),
            ledger: Ledger::default(),
            attach,
            edge,
        }
    }

    /// The forward and route state with the link state it follows.
    pub(crate) fn edge_parts(&mut self) -> (&mut crate::ports::Edge, &crate::link::LinkSupervisor) {
        self.attach.supervisor.pump();
        (&mut self.edge, &self.attach.supervisor)
    }

    /// Closes forwards and routes whose link went down or was replaced.
    pub fn reconcile_edge(&mut self) {
        let (edge, links) = self.edge_parts();
        edge.reconcile(links);
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

    /// Runs one request.
    pub fn handle(&mut self, request: &Request) -> Result<Value, CloudError> {
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
            return self.run(name, &args, request.origin, None);
        }
        let key = key.ok_or_else(|| {
            CloudError::new(
                codes::IDEMPOTENCY_KEY_REQUIRED,
                format!("{name} needs an idempotency key"),
            )
        })?;
        if key.len() > 128 {
            return Err(CloudError::invalid("an idempotency key has at most 128 characters"));
        }
        if crate::link::ops::live_state_op(name)
            || crate::ports::live_state_op(name)
            || RERUN_OPS.contains(&name)
        {
            // The answer is live state (a carrier, a forward, or DNS and
            // certificate state): a replay of an old answer would be stale.
            // These ops are idempotent by themselves, so they run every time.
            let upstream = upstream_key(name, &args, key);
            return self.run(name, &args, request.origin, Some(&upstream));
        }
        if NO_UPSTREAM_DEDUP.contains(&name) && self.ledger.unfinished(key, name, &args) {
            return Err(CloudError::new(
                codes::OUTCOME_UNKNOWN,
                format!(
                    "an earlier {name} with this key got no answer: list first, then retry with a new key"
                ),
            ));
        }
        if let Some(done) = self.ledger.replay(key, name, &args)? {
            return Ok(done);
        }
        // A delete retried after an attempt whose outcome is unknown: a 404
        // now means that attempt (or another) deleted it (delete_retry.rs).
        let gone_is_done =
            delete_retry::is_delete(name) && self.ledger.outcome_unknown(key, name, &args);
        self.ledger.attempt(key, name, &args);
        let upstream = upstream_key(name, &args, key);
        let outcome = match self.run(name, &args, request.origin, Some(&upstream)) {
            Err(error) if gone_is_done && error.code == codes::NOT_FOUND => {
                delete_retry::gone_answer(name, &args).ok_or(error)
            }
            other => other,
        };
        match outcome {
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
            Err(error) => {
                // Bad args never changed anything: the key stays free for the fix.
                let refused = NO_UPSTREAM_DEDUP.contains(&name)
                    && error.status.is_some_and(|s| (400..500).contains(&s));
                if error.code == codes::INVALID_ARGS || refused {
                    self.ledger.forget(key);
                } else {
                    self.ledger.failed(key, !delete_retry::outcome_unknown(&error));
                }
                Err(error)
            }
        }
    }

    fn run(
        &mut self,
        name: &str,
        args: &Value,
        origin: Origin,
        key: Option<&str>,
    ) -> Result<Value, CloudError> {
        if crate::link::ops::serves(name) {
            return crate::link::ops::run(self, name, args, origin, key);
        }
        if crate::fs::serves(name) {
            return crate::fs::run(self, name, args, origin, key);
        }
        if crate::ports::serves(name) {
            return crate::ports::run(self, name, args, origin, key);
        }
        let mut ctx = Ctx::new(&mut self.control_plane, &mut self.projection, name, key);
        let group = name.split('.').nth(1).unwrap_or_default();
        match group {
            "auth" => auth::run(&mut ctx, name, args),
            "machine" => machine::run(&mut ctx, name, args),
            "snapshot" => snapshot::run(&mut ctx, name, args),
            "plan" | "usage" => plan::run(&mut ctx, name, args),
            "network" | "tunnel" | "firewall" => network::run(&mut ctx, name, args),
            "domain" | "publication" => domain::run(&mut ctx, name, args),
            _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
        }
    }
}
