//! Re-exec into a newer `cmux` (decision SV-R2).
//!
//! A verified manifest whose `min_cmux_version` is above the running
//! version cannot be applied by this binary. The I/O crate stages the
//! manifest's `cmux` package into the store exactly like any package
//! (streaming SHA-256, exact size, safe unpack), then asks [`plan`] what to
//! do: exec the staged [`REEXEC_BINARY`] once with the same verb and
//! arguments, or refuse with the "needs newer cmux" error (exit 4).
//!
//! Loop guard: the exec carries [`GUARD_ENV`] set to a [`marker`] that
//! names the manifest (sequence and SHA-256). A process that starts with
//! the guard set never re-execs again; if it is still too old it refuses,
//! so a bad release can cost at most one extra exec, never a loop. The
//! guard can only stop a re-exec, so reading it from the environment cannot
//! widen trust.

use crate::layout::{Layout, ServiceKind};
use crate::manifest::{ChannelManifest, Package};
use crate::platform::{HostPath, Platform};

/// Set on the re-exec'd process; its value is a [`marker`].
pub const GUARD_ENV: &str = "CMUX_SERVER_REEXEC";

/// The package that carries the `cmux` binary.
pub const CMUX_PACKAGE: &str = "cmux";

/// The binary in that package's `bin/` that owns the server verbs: the
/// `cmux` CLI, which mounts them as `cmux server <verb> …` (decision D1;
/// its daemon lifecycle is `cmux daemon`). It is re-exec'd under that name,
/// so the `cmux` surface (chosen from argv0) routes `server` to the machine
/// server.
pub const REEXEC_BINARY: &str = "cmux";

/// The noun in front of the verb: `cmux server <verb> …`.
pub const REEXEC_NOUN: &str = "server";

/// [`REEXEC_BINARY`]'s file name on `platform`.
pub fn reexec_binary(platform: Platform) -> String {
    platform.cmux_exe().to_owned()
}

/// `<sequence>:<manifest sha256 hex>`: the manifest a re-exec was for.
pub fn marker(sequence: u64, manifest_sha256: &[u8; 32]) -> String {
    let hex: String = manifest_sha256.iter().map(|b| format!("{b:02x}")).collect();
    format!("{sequence}:{hex}")
}

/// The manifest's `cmux` package for a machine with `roles`.
pub fn cmux_package<'a>(manifest: &'a ChannelManifest, roles: &'a [&str]) -> Option<&'a Package> {
    manifest.packages_for(roles).find(|p| p.name == CMUX_PACKAGE)
}

/// Everything [`plan`] decides from.
#[derive(Clone, Copy, Debug)]
pub struct ReexecInput<'a> {
    pub layout: &'a Layout,
    /// The manifest's `cmux` package, already staged and verified in the
    /// store by the caller.
    pub package: &'a Package,
    pub min_cmux_version: &'a str,
    pub sequence: u64,
    pub manifest_sha256: &'a [u8; 32],
    /// The value of [`GUARD_ENV`] in this process, if set.
    pub guard: Option<&'a str>,
    /// The verb's arguments, built from the parse result (verb, flags,
    /// positionals; [`plan`] puts [`REEXEC_NOUN`] in front).
    pub args: &'a [String],
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReexecPlan {
    /// Exec `binary` with `args`, adding `GUARD_ENV=marker` to the
    /// environment. Nothing runs after it in this process.
    Exec { binary: HostPath, args: Vec<String>, marker: String },
    /// Do not exec: refuse with this message (exit 4).
    Refuse(String),
}

/// Decides between one re-exec and a refusal.
pub fn plan(input: &ReexecInput<'_>) -> ReexecPlan {
    let min = input.min_cmux_version;
    let marker = marker(input.sequence, input.manifest_sha256);
    if let ServiceKind::AppServiceAgent { .. } = input.layout.service {
        return ReexecPlan::Refuse(format!(
            "manifest {marker} needs cmux {min} or newer; this server runs the app's bundled \
             cmux, so update the app"
        ));
    }
    let Some(dir) = input.layout.store_package(&input.package.sha256) else {
        return ReexecPlan::Refuse(format!(
            "manifest {marker}: the cmux package sha256 {:?} is not a store name",
            input.package.sha256
        ));
    };
    let binary = dir.join("bin").join(&reexec_binary(input.layout.platform));
    if let Some(guard) = input.guard {
        return ReexecPlan::Refuse(format!(
            "manifest {marker} needs cmux {min} or newer; this process was already re-executed \
             once (for manifest {guard}) and is still too old. The verified package is at {}",
            binary.as_str()
        ));
    }
    let mut args = vec![REEXEC_NOUN.to_owned()];
    args.extend(input.args.iter().cloned());
    ReexecPlan::Exec { binary, args, marker }
}
