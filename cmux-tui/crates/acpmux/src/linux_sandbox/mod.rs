//! Linux remote chains enforce `sandbox/remote-chain.sb`, parsed by `rules`.
//! bwrap isolates mounts, PIDs and networking; seccomp and the user-notify
//! supervisor enforce persistence names and mutations. The proxy restricts
//! outbound ports and destinations; a dedicated forwarder allows only the
//! configured IPv4 loopback API port. Probe and session canary must both pass.
pub(crate) mod bwrap;
pub(crate) mod init;
pub(crate) mod keeper;
pub(crate) mod lookup;
pub(crate) mod proxy;
pub(crate) mod rules;
pub(crate) mod seccomp;
pub(crate) mod supervisor;

/// glibc sysdeps/generic/unsecvars.h (including legacy MALLOC_CHECK_) plus
/// every LD_* control: none may reach an unsandboxed Linux exec.
#[cfg(target_os = "linux")]
pub(crate) fn loader_env_key(key: &str) -> bool {
    key.starts_with("LD_")
        || matches!(
            key,
            "GCONV_PATH"
                | "GETCONF_DIR"
                | "GLIBC_TUNABLES"
                | "HOSTALIASES"
                | "LOCALDOMAIN"
                | "LOCPATH"
                | "MALLOC_ARENA_MAX"
                | "MALLOC_ARENA_TEST"
                | "MALLOC_CHECK_"
                | "MALLOC_TCACHE_COUNT"
                | "MALLOC_TCACHE_MAX"
                | "MALLOC_TCACHE_UNSORTED_LIMIT"
                | "MALLOC_PERTURB_"
                | "MALLOC_TOP_PAD_"
                | "MALLOC_TRACE"
                | "MALLOC_MMAP_MAX_"
                | "MALLOC_MMAP_THRESHOLD_"
                | "MALLOC_TRIM_THRESHOLD_"
                | "NIS_PATH"
                | "NLSPATH"
                | "RESOLV_HOST_CONF"
                | "RES_OPTIONS"
                | "TMPDIR"
                | "TZDIR"
        )
}

/// Finite scan of inherited and explicitly merged keys; never mutates the daemon env.
#[cfg(target_os = "linux")]
pub(crate) fn scrub_loader_env(command: &mut tokio::process::Command) {
    let keys: Vec<_> = std::env::vars_os()
        .map(|(k, _)| k)
        .chain(command.as_std().get_envs().map(|(k, _)| k.to_owned()))
        .filter(|k| crate::linux_sandbox::keeper::loader_env_key(&k.to_string_lossy()))
        .collect();
    for key in keys {
        command.env_remove(key);
    }
}
