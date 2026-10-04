//! The error codes each backend Cloud op declares in its catalog row
//! (`backend/catalog/cloud-operations.json`, owner `cloud:CloudDO`). A
//! backend op answers only these codes (backend answer a1c6283b256 (b));
//! the client maps them and turns any other code into
//! `cmux.cloud.protocol_error`. `tests/manifest.rs` checks this table
//! against the backend catalog.

/// Every read: the Worker's own refusals and gates (SSO, client version),
/// an unreachable owner, and an unknown selector.
const READ: &[&str] = &[
    "auth.forbidden",
    "auth.sso_required",
    "auth.unauthenticated",
    "client.too_old",
    "owner.unreachable",
    "selector.not_found",
    "validation.invalid",
];

/// Every mutation: the shared mutation errors (`op-def.ts` `mutationErrors`),
/// the Worker's gates and an unreachable owner.
const MUTATION: &[&str] = &[
    "auth.forbidden",
    "auth.sso_required",
    "auth.unauthenticated",
    "client.too_old",
    "idempotency.conflict",
    "owner.unreachable",
    "revision.conflict",
    "validation.invalid",
];

/// Codes a provider call can add: it may fail for now or be cut off.
const PROVIDER: &[&str] = &["cloud.provider.unavailable", "mutation.indeterminate"];

/// `(op, class base, the op's own codes)`.
const OPS: &[(&str, &[&str], &[&str])] = &[
    ("cloud.machine.list", READ, &[]),
    ("cloud.machine.get", READ, &["cloud.machine.not_found"]),
    (
        "cloud.machine.create",
        MUTATION,
        &[
            "cloud.plan.required",
            "cloud.quota.exceeded",
            "cloud.size.locked",
            "cloud.snapshot.not_found",
        ],
    ),
    ("cloud.machine.rename", MUTATION, &["cloud.machine.not_found"]),
    ("cloud.machine.start", MUTATION, &["cloud.machine.not_found", "cloud.quota.exceeded"]),
    ("cloud.machine.pause", MUTATION, &["cloud.machine.not_found"]),
    (
        "cloud.machine.resize",
        MUTATION,
        &["cloud.machine.not_found", "cloud.quota.exceeded", "cloud.size.locked"],
    ),
    ("cloud.machine.delete", MUTATION, &["cloud.machine.not_found"]),
    ("cloud.machine.idle_policy.set", MUTATION, &["cloud.machine.not_found"]),
    ("cloud.machine.connect_info", READ, &["cloud.machine.not_bound", "cloud.machine.not_found"]),
    (
        "cloud.machine.upgrade",
        MUTATION,
        &["cloud.machine.not_classic", "cloud.machine.not_found", "cloud.upgrade.failed"],
    ),
    ("cloud.snapshot.list", READ, &["cloud.machine.not_found"]),
    ("cloud.snapshot.create", MUTATION, &["cloud.machine.not_found", "cloud.quota.exceeded"]),
    (
        "cloud.snapshot.restore",
        MUTATION,
        &[
            "cloud.plan.required",
            "cloud.quota.exceeded",
            "cloud.size.locked",
            "cloud.snapshot.not_found",
        ],
    ),
    ("cloud.snapshot.delete", MUTATION, &["cloud.snapshot.not_found"]),
    ("cloud.plan.get", READ, &[]),
    ("cloud.billing.checkout", MUTATION, &[]),
    ("cloud.shell.open", MUTATION, &["cloud.machine.not_found", "cloud.machine.paused"]),
    ("cloud.migration.status", READ, &[]),
    ("cloud.migration.start", MUTATION, &["cloud.migration.unavailable"]),
];

/// Ops whose provider call can fail for now or be cut off.
const PROVIDER_OPS: &[&str] = &[
    "cloud.machine.create",
    "cloud.machine.start",
    "cloud.machine.pause",
    "cloud.machine.resize",
    "cloud.machine.delete",
    "cloud.machine.upgrade",
    "cloud.snapshot.create",
    "cloud.snapshot.restore",
    "cloud.snapshot.delete",
    "cloud.shell.open",
];

/// The backend Cloud ops this table describes, in catalog order.
pub fn backend_ops() -> impl Iterator<Item = &'static str> {
    OPS.iter().map(|(name, _, _)| *name)
}

/// The codes backend op `op` declares, sorted; `None` for an op that is not
/// a backend Cloud op.
pub fn declared_errors(op: &str) -> Option<&'static [&'static str]> {
    static TABLE: std::sync::OnceLock<Vec<(&'static str, Vec<&'static str>)>> =
        std::sync::OnceLock::new();
    let table = TABLE.get_or_init(|| {
        OPS.iter()
            .map(|(name, base, own)| {
                let provider: &[&str] = if PROVIDER_OPS.contains(name) { PROVIDER } else { &[] };
                let mut codes: Vec<&'static str> =
                    base.iter().chain(own.iter()).chain(provider.iter()).copied().collect();
                codes.sort_unstable();
                codes.dedup();
                (*name, codes)
            })
            .collect()
    });
    table.iter().find(|(name, _)| *name == op).map(|(_, codes)| codes.as_slice())
}
