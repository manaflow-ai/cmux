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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{LayoutEnv, layout};
    use crate::{InstallMode, Platform};

    fn env() -> LayoutEnv {
        LayoutEnv { home: Some("/home/ana".to_owned()), uid: Some(1000), ..LayoutEnv::default() }
    }

    fn package() -> Package {
        Package {
            name: "cmux".to_owned(),
            version: "9.0.0".to_owned(),
            url: "https://files.example.test/cmux.tar.gz".to_owned(),
            sha256: "ab".repeat(32),
            size: 10,
            roles: vec!["all".to_owned()],
        }
    }

    fn input<'a>(
        layout: &'a Layout,
        package: &'a Package,
        guard: Option<&'a str>,
        args: &'a [String],
    ) -> ReexecInput<'a> {
        ReexecInput {
            layout,
            package,
            min_cmux_version: "9.0.0",
            sequence: 42,
            manifest_sha256: &[0x11; 32],
            guard,
            args,
        }
    }

    fn words(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn execs_the_staged_cmux_once_with_the_same_verb_under_server() {
        let l = layout(InstallMode::User, Platform::Linux, &env()).unwrap();
        let pkg = package();
        let args = words("upgrade --json --channel-url=https://c.example");
        let plan = plan(&input(&l, &pkg, None, &args));
        let sha = "ab".repeat(32);
        assert_eq!(
            plan,
            ReexecPlan::Exec {
                binary: l.store.join(&sha).join("bin/cmux"),
                args: words("server upgrade --json --channel-url=https://c.example"),
                marker: format!("42:{}", "11".repeat(32)),
            }
        );
        assert_eq!(reexec_binary(Platform::Windows), "cmux.exe");
    }

    #[test]
    fn the_guard_stops_a_second_reexec() {
        let l = layout(InstallMode::User, Platform::MacOs, &env()).unwrap();
        let pkg = package();
        let args = words("install");
        let ReexecPlan::Refuse(message) = plan(&input(&l, &pkg, Some("41:00"), &args)) else {
            panic!("re-exec'd twice");
        };
        assert!(message.contains("already re-executed once"), "{message}");
        assert!(message.contains("needs cmux 9.0.0"), "{message}");
        assert!(message.contains("41:00"), "{message}");
    }

    #[test]
    fn the_app_mode_never_reexecs_into_the_store() {
        let mut e = env();
        e.mac_app_bundle = Some("/Applications/cmux.app".to_owned());
        let l = layout(InstallMode::User, Platform::MacOs, &e).unwrap();
        let pkg = package();
        let ReexecPlan::Refuse(message) = plan(&input(&l, &pkg, None, &[])) else { panic!() };
        assert!(message.contains("update the app"), "{message}");
    }

    #[test]
    fn a_bad_store_name_is_refused() {
        let l = layout(InstallMode::User, Platform::Linux, &env()).unwrap();
        let mut pkg = package();
        pkg.sha256 = "../../bin".to_owned();
        assert!(matches!(plan(&input(&l, &pkg, None, &[])), ReexecPlan::Refuse(_)));
    }

    #[test]
    fn finds_the_cmux_package_for_the_roles() {
        let other = Package { name: "tool".to_owned(), ..package() };
        let mut only_server = package();
        only_server.roles = vec!["server".to_owned()];
        let m = ChannelManifest {
            schema: 1,
            channel: "stable".to_owned(),
            sequence: 1,
            expires_at: "2027-01-01T00:00:00Z".to_owned(),
            min_cmux_version: "9.0.0".to_owned(),
            packages: vec![other, only_server],
        };
        assert_eq!(cmux_package(&m, &["server"]).map(|p| p.name.as_str()), Some("cmux"));
        assert_eq!(cmux_package(&m, &["postgres"]), None);
        assert_eq!(marker(7, &[0; 32]), format!("7:{}", "0".repeat(64)));
    }
}
