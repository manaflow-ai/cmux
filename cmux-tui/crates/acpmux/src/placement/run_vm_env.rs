//! The environment a run VM's command gets: the caller's, byte for byte, but the variables that
//! name this host or carry a secret ([`DROPPED`], the one list). The fork's shell starts from an
//! empty environment, takes every forwarded variable, then for each dropped name the caller had,
//! the fork's own value when it has one (its own machine id, its own ssh socket). A dropped name
//! the caller did not have stays unset, so the fork's login environment never leaks in.

use std::ffi::{OsStr, OsString};

/// The variables a run VM never gets from its caller, and why: (rule, why). A rule is an exact
/// name, a `PREFIX*`, or a `*SUFFIX` or `*PART*` over the upper-cased name. Nothing else is held
/// back (`run_vm_env_tests.rs` and the conformance case `whole-env` hold the rest to reaching it).
pub const DROPPED: &[(&str, &str)] = &[
    // This host's identity: on the fork the fork's own value is the true one.
    ("CMUX_VM_ID", "this machine's Cloud id (the fork has its own)"),
    ("HOSTNAME", "this host's name"),
    ("HOST", "this host's name (zsh, tcsh)"),
    ("SSH_CONNECTION", "this host's ssh session"),
    ("SSH_CLIENT", "this host's ssh session"),
    ("SSH_TTY", "this host's terminal"),
    ("DISPLAY", "this host's display"),
    ("WAYLAND_DISPLAY", "this host's display"),
    ("XDG_RUNTIME_DIR", "this host's runtime folder"),
    ("XDG_SESSION_ID", "this host's login session"),
    ("DBUS_SESSION_BUS_ADDRESS", "this host's session bus"),
    ("INVOCATION_ID", "this host's systemd unit run"),
    ("JOURNAL_STREAM", "this host's journal socket"),
    ("NOTIFY_SOCKET", "this host's systemd socket"),
    ("LISTEN_FDS", "descriptors this host's process was handed"),
    ("LISTEN_PID", "a process id on this host"),
    ("LISTEN_FDNAMES", "descriptors this host's process was handed"),
    ("MANAGERPID", "a process id on this host"),
    ("TMUX", "this host's tmux server"),
    ("TMUX_PANE", "this host's tmux pane"),
    ("STY", "this host's screen session"),
    ("XAUTHORITY", "this host's display cookie"),
    ("*_SOCK", "a socket on this host (SSH_AUTH_SOCK, GPG_AGENT_SOCK)"),
    ("*_SOCKET", "a socket on this host"),
    ("*_PID", "a process id on this host (SSH_AGENT_PID)"),
    // Secret-bearing: a credential stays on the machine it was given to.
    ("*TOKEN*", "a token"),
    ("*SECRET*", "a secret"),
    ("*PASSWORD*", "a password"),
    ("*PASSWD*", "a password"),
    ("*PASSPHRASE*", "a passphrase"),
    ("*CREDENTIAL*", "a credential (GOOGLE_APPLICATION_CREDENTIALS)"),
    ("*_KEY", "a key (OPENAI_API_KEY, AWS_SECRET_ACCESS_KEY)"),
    ("*_KEY_ID", "a key id (AWS_ACCESS_KEY_ID)"),
    ("*API_KEY*", "an API key"),
    ("*PRIVATE_KEY*", "a private key"),
    ("*COOKIE*", "a cookie"),
    ("*_AUTH", "an auth value (NPM_CONFIG__AUTH)"),
];

/// Whether `name` is held back from a run VM ([`DROPPED`]).
pub fn dropped(name: &OsStr) -> bool {
    let up = name.to_string_lossy().to_ascii_uppercase();
    DROPPED.iter().any(|(rule, _)| match (rule.strip_prefix('*'), rule.strip_suffix('*')) {
        (Some(inner), Some(_)) => up.contains(inner.trim_end_matches('*')),
        (Some(suffix), None) => up.ends_with(suffix),
        (None, Some(prefix)) => up.starts_with(prefix),
        (None, None) => up == *rule,
    })
}

/// What a caller's environment sends: every variable not [`dropped`] as raw `KEY=VALUE` bytes,
/// and the names it held back (so the fork fills those, and only those, from its own).
pub fn forward(env: impl IntoIterator<Item = (OsString, OsString)>) -> (Vec<Vec<u8>>, Vec<String>) {
    let (mut sent, mut held) = (Vec::new(), Vec::new());
    for (k, v) in env {
        if dropped(&k) {
            held.push(k.to_string_lossy().into_owned());
            continue;
        }
        let mut kv = k.as_encoded_bytes().to_vec();
        kv.push(b'=');
        kv.extend_from_slice(v.as_encoded_bytes());
        sent.push(kv);
    }
    (sent, held)
}

/// The fork's environment for a command: the `sent` variables, then each `held` name from the
/// fork's `own` environment where it has one.
#[cfg(unix)]
pub fn fork_env(
    sent: &[Vec<u8>],
    held: &[String],
    own: impl Fn(&str) -> Option<OsString>,
) -> Vec<(OsString, OsString)> {
    use std::os::unix::ffi::OsStringExt as _;
    let mut out = Vec::with_capacity(sent.len() + held.len());
    for kv in sent {
        let Some(eq) = kv.iter().position(|b| *b == b'=') else { continue };
        let (k, rest) = kv.split_at(eq);
        let (k, v) = (k.to_vec(), rest.get(1..).unwrap_or_default().to_vec());
        out.push((OsString::from_vec(k), OsString::from_vec(v)));
    }
    for name in held {
        if let Some(v) = own(name) {
            out.push((OsString::from(name), v));
        }
    }
    out
}

#[cfg(all(test, unix))]
#[path = "run_vm_env_tests.rs"]
mod tests;
