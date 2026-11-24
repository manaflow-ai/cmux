//! Agents get vault placeholders, and this daemon's egress proxy
//! (`cmux-vault-egress`) puts the values into their HTTPS requests, only
//! toward the hosts each entry allows.
//!
//! - A proxy entry (`plan::EnvRecord::proxy`) reaches a spawn as
//!   `NAME=cmux-secret://NAME`; an entry the person opted out
//!   (`delivery: env`, shown as weaker) as its value.
//! - With at least one proxy entry, the spawn also gets `HTTPS_PROXY` (both
//!   cases) at the proxy on 127.0.0.1, loopback in `NO_PROXY`, and the
//!   proxy's CA: `NODE_EXTRA_CA_CERTS` (Node, Bun: Claude Code, pi) to the CA
//!   plus any file it already named, and `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`,
//!   `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO` (OpenSSL, rustls native roots, Python,
//!   curl, git, Go on Linux) to the system bundle plus the CA. Only agent
//!   processes get these; the CA is never added to the OS store, and its key
//!   is kept only in `vault-egress/ca-key.pem` (0600, in the 0700 folder).
//! - A launch whose environment already names an `HTTPS_PROXY` keeps it:
//!   its placeholders are then never filled (fail closed), logged once as
//!   `vault.egress_proxy_conflict`.
//! - A joined machine's team-mode launch (`joined_model_plane.rs`) gets the
//!   same proxy settings ([`machine_credential_env`]) with no vault entry, and
//!   from then on the proxy also serves one built-in entry,
//!   `CMUX_MACHINE_CREDENTIAL`: the machine credential, toward the hub
//!   origin's host only.
//! - The proxy starts on the first spawn that needs it and runs for the
//!   daemon's life. Each request reads the entries again (at most 2 s old),
//!   so a revoke, a removed grant or a narrowed host list holds within that.
//! - Its port outlives the daemon: the port it took is kept in
//!   `vault-egress/port` and the next daemon binds the same one, a new one
//!   only when that is taken ([`bind_stable`]). Agent hosts outlive a daemon
//!   restart (an update every 15 min, a crash), and every agent they run was
//!   given `HTTPS_PROXY` at its spawn: with a new port each restart, each of
//!   them reached a closed port (`ECONNREFUSED`) until restarted by hand
//!   (2026-11-21: 20 chats on one machine `harness_unavailable`). With the
//!   port kept, the tools such an agent runs (git, curl, gh, Python), which
//!   read the trust files anew, keep working. Only the daemon writes the port
//!   down: another acpmux process with a proxy of its own never moves it.
//! - The CA outlives the daemon too ([`kept_or_new_authority`]): its key is
//!   kept in `vault-egress/ca-key.pem` beside its certificate (`ca.pem`), and
//!   the next daemon serves the same CA; a new one only when they are missing,
//!   not a pair, or within 45 days of the end (`CA_RENEW_BEFORE`). A Node
//!   agent reads `NODE_EXTRA_CA_CERTS` once at its start: with a new CA each
//!   start, every Claude an earlier daemon started failed TLS to its model
//!   endpoint (`UNABLE_TO_VERIFY_LEAF_SIGNATURE`, 2026-11-22, two Freestyle
//!   lanes after an hourly restart). The key file is readable by this uid
//!   only; it signs only for this machine's agents and holds no vault value.
//!   The trust files never extend a file of ours a launch inherited
//!   ([`write_trust`]), so they hold the CA once however often it restarts.
//! - Every spawn also gets [`EPOCH_VAR`], naming the CA it trusts (from the
//!   certificate, so the same across daemons that serve it); an agent whose
//!   env names our proxy and another CA is restarted between turns, on
//!   adoption (`hub/stale_host_respawn.rs`) and before an automatic retry
//!   (`hub/auto_resume.rs`), never in a turn ([`stale_proxy_env`]).

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_vault_egress::{Authority, Config, HostPattern, Policy, Resolver, Secret, placeholder};

use super::Given;

/// Where the proxy runs and the trust files its agents get.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Running {
    pub port: u16,
    /// The proxy's CA ([`ca_epoch`]): what [`EPOCH_VAR`] carries.
    pub epoch: String,
    /// The CA, plus whatever `NODE_EXTRA_CA_CERTS` named before.
    pub node_ca: PathBuf,
    /// The system bundle (or the inherited `SSL_CERT_FILE`) plus the CA;
    /// `None` when there is no bundle file to extend (only Node then trusts it).
    pub bundle: Option<PathBuf>,
}

enum Slot {
    Idle,
    Up(Running),
    /// The last start failed then: tried again after [`RETRY_START`].
    Failed(Instant),
}

static SLOT: Mutex<Slot> = Mutex::new(Slot::Idle);
const RETRY_START: Duration = Duration::from_secs(60);
/// How stale the entries the proxy serves may be.
const POLICY_TTL: Duration = Duration::from_secs(2);
static POLICY: Mutex<Option<(Instant, Arc<Policy>)>> = Mutex::new(None);
static CONFLICT_LOGGED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// A launch asked for the machine credential ([`machine_credential_env`]): only then does the
/// policy hold it.
static MACHINE_CREDENTIAL: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// Bundles agents' TLS stacks read when `SSL_CERT_FILE` is unset, first found wins.
const SYSTEM_BUNDLES: &[&str] = &[
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
    "/etc/pki/tls/cacert.pem",
    "/etc/ssl/cert.pem",
];

/// Names the CA a spawn was told to trust ([`Running::epoch`]).
pub(crate) const EPOCH_VAR: &str = "CMUX_VAULT_EGRESS_EPOCH";
/// The file, in `vault-egress/`, that keeps the proxy's port for the next daemon.
const PORT_FILE: &str = "port";
/// The files, in `vault-egress/`, that keep the CA for the next daemon: its
/// key (0600, never given to agents) and its certificate.
const CA_KEY_FILE: &str = "ca-key.pem";
const CA_CERT_FILE: &str = "ca.pem";

/// The proxy's part of the agent pool's key: a spawn made before the proxy
/// started (or on another port, or with another CA) is not reused.
pub(crate) fn stamp() -> String {
    match &*SLOT.lock().unwrap_or_else(|e| e.into_inner()) {
        Slot::Up(running) => format!("{}:{}", running.port, running.epoch),
        _ => "off".to_owned(),
    }
}

/// The running proxy's start, if it runs in this daemon.
fn live_epoch() -> Option<String> {
    match &*SLOT.lock().unwrap_or_else(|e| e.into_inner()) {
        Slot::Up(running) => Some(running.epoch.clone()),
        _ => None,
    }
}

/// Whether an agent started with `env` was sent through this daemon's proxy
/// (its `NODE_EXTRA_CA_CERTS` is `node_ca`, ours) trusting a CA other than
/// `live`'s (None: the proxy has not started in this daemon). Such an agent
/// reaches a proxy whose CA it does not trust: it needs a restart. One an
/// earlier daemon started with the same kept CA is not stale. An agent with
/// no proxy, or another one, is never stale; one from
/// a build before [`EPOCH_VAR`] (ours, no epoch) always is.
pub(crate) fn stale_proxy_env(
    env: &[(String, String)],
    node_ca: &Path,
    live: Option<&str>,
) -> bool {
    let get = |name: &str| env.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str());
    let ours = get("NODE_EXTRA_CA_CERTS").is_some_and(|p| Path::new(p) == node_ca)
        && get("HTTPS_PROXY").is_some_and(|u| u.starts_with("http://127.0.0.1:"));
    ours && get(EPOCH_VAR) != live
}

/// [`stale_proxy_env`] for the running process `pid`, judged against this
/// daemon's proxy; false when its env cannot be read (unknown is not stale).
#[cfg(unix)]
pub(crate) fn stale_proxy_pid(pid: u32) -> bool {
    let Some(env) = crate::agent_host::tree::environ(pid) else { return false };
    let node_ca = crate::config::home().join("vault-egress").join("node-extra-ca.pem");
    stale_proxy_env(&env, &node_ca, live_epoch().as_deref())
}

#[cfg(not(unix))]
pub(crate) fn stale_proxy_pid(_pid: u32) -> bool {
    false
}

/// What a spawn's env gets from `entries` (see the module docs).
pub(crate) fn child_env(entries: Vec<Given>) -> Vec<(String, String)> {
    let wants_proxy = entries.iter().any(|g| g.proxy.is_some());
    let running = if wants_proxy { ensure() } else { None };
    child_env_with(entries, running.as_ref(), &inherited)
}

/// The value a launch would have without the vault: the login env's, else
/// the daemon's own.
pub(super) fn inherited(name: &str) -> Option<String> {
    crate::login_env::allowed_var(name)
        .or_else(|| std::env::var(name).ok())
        .filter(|v| !v.is_empty())
}

pub(crate) fn child_env_with(
    entries: Vec<Given>,
    running: Option<&Running>,
    inherited: &dyn Fn(&str) -> Option<String>,
) -> Vec<(String, String)> {
    let mut out = Vec::with_capacity(entries.len() + 10);
    let mut any_proxy = false;
    for entry in entries {
        match entry.proxy {
            Some(_) => {
                any_proxy = true;
                let held = placeholder(&entry.name);
                out.push((entry.name, held));
            }
            None => out.push((entry.name, entry.value.as_str().to_owned())),
        }
    }
    let Some(running) = running.filter(|_| any_proxy) else { return out };
    match proxy_env(running, inherited) {
        Some(proxy) => out.extend(proxy),
        None => {
            if !CONFLICT_LOGGED.swap(true, std::sync::atomic::Ordering::SeqCst) {
                tracing::warn!(
                    code = "vault.egress_proxy_conflict",
                    "this launch already has an HTTPS proxy; vault placeholders are not filled"
                );
            }
        }
    }
    out
}

/// The settings that send a launch through the proxy at `running` and trust its CA; None when
/// the launch already names an HTTPS proxy (it keeps it).
fn proxy_env(
    running: &Running,
    inherited: &dyn Fn(&str) -> Option<String>,
) -> Option<Vec<(String, String)>> {
    if inherited("HTTPS_PROXY").is_some() || inherited("https_proxy").is_some() {
        return None;
    }
    let mut out = Vec::with_capacity(10);
    let url = format!("http://127.0.0.1:{}", running.port);
    out.push(("HTTPS_PROXY".to_owned(), url.clone()));
    out.push(("https_proxy".to_owned(), url));
    out.push((EPOCH_VAR.to_owned(), running.epoch.clone()));
    let no_proxy = no_proxy(inherited("NO_PROXY").or_else(|| inherited("no_proxy")));
    out.push(("NO_PROXY".to_owned(), no_proxy.clone()));
    out.push(("no_proxy".to_owned(), no_proxy));
    out.push(("NODE_EXTRA_CA_CERTS".to_owned(), running.node_ca.display().to_string()));
    if let Some(bundle) = &running.bundle {
        let bundle = bundle.display().to_string();
        for name in ["SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO"] {
            out.push((name.to_owned(), bundle.clone()));
        }
    }
    Some(out)
}

/// The proxy settings for a joined machine's team-mode launch (`joined_model_plane.rs`), the
/// proxy started for it, and the machine credential served from now on. `launch` reads the
/// launch's own env (its profile). None when the proxy cannot start or the launch already names
/// an HTTPS proxy: its header would go out unfilled, so the launch keeps own mode.
pub(crate) fn machine_credential_env(
    launch: &dyn Fn(&str) -> Option<String>,
) -> Option<Vec<(String, String)>> {
    let running = ensure()?;
    let either = |k: &str| launch(k).filter(|v| !v.is_empty()).or_else(|| inherited(k));
    let env = proxy_env(&running, &either)?;
    if !MACHINE_CREDENTIAL.swap(true, std::sync::atomic::Ordering::SeqCst) {
        // The next request reads the policy again, with the credential.
        *POLICY.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
    Some(env)
}

/// The inherited `NO_PROXY` with loopback added (never the proxy's own
/// traffic to it), and the Cloud machine's internal names.
fn no_proxy(inherited: Option<String>) -> String {
    let mut parts: Vec<String> = inherited
        .unwrap_or_default()
        .split(',')
        .map(|p| p.trim().to_owned())
        .filter(|p| !p.is_empty())
        .collect();
    for local in ["localhost", "127.0.0.1", "::1", ".cmux.internal"] {
        if !parts.iter().any(|p| p == local) {
            parts.push(local.to_owned());
        }
    }
    parts.join(",")
}

/// The running proxy, starting it once (again a minute after a failure).
fn ensure() -> Option<Running> {
    let mut slot = SLOT.lock().unwrap_or_else(|e| e.into_inner());
    match &*slot {
        Slot::Up(running) => return Some(running.clone()),
        Slot::Failed(at) if at.elapsed() < RETRY_START => return None,
        _ => {}
    }
    match start(&crate::config::home()) {
        Ok(running) => {
            tracing::info!(port = running.port, "vault egress proxy started");
            *slot = Slot::Up(running.clone());
            Some(running)
        }
        Err(code) => {
            tracing::warn!(code, "vault egress proxy not started; placeholders are not filled");
            *slot = Slot::Failed(Instant::now());
            None
        }
    }
}

fn start(home: &Path) -> Result<Running, &'static str> {
    let runtime = tokio::runtime::Handle::try_current().map_err(|_| "vault.egress_no_runtime")?;
    let dir = home.join("vault-egress");
    private_folder(&dir).map_err(|_| "vault.egress_trust_files")?;
    let authority = Arc::new(kept_or_new_authority(&dir)?);
    let upstream_tls =
        cmux_vault_egress::upstream_tls_from_os().map_err(|_| "vault.egress_no_roots")?;
    let (node_ca, bundle) =
        write_trust(&dir, authority.pem(), &inherited).map_err(|_| "vault.egress_trust_files")?;
    let argv: Vec<String> = std::env::args().collect();
    let daemon = crate::cli::is_daemon_run(&argv);
    let listener = bind_stable(&dir, daemon).map_err(|_| "vault.egress_bind")?;
    listener.set_nonblocking(true).map_err(|_| "vault.egress_bind")?;
    let port = listener.local_addr().map_err(|_| "vault.egress_bind")?.port();
    let epoch = ca_epoch(authority.pem());
    let config = Arc::new(Config {
        policy: Arc::new(policy_now),
        authority,
        upstream_tls,
        resolver: Resolver::Dns,
    });
    runtime.spawn(async move {
        let result = match tokio::net::TcpListener::from_std(listener) {
            Ok(listener) => cmux_vault_egress::serve(listener, config).await,
            Err(e) => Err(e),
        };
        if let Err(e) = result {
            tracing::error!(code = "vault.egress_stopped", kind = ?e.kind(), "vault egress proxy stopped");
        }
    });
    Ok(Running { port, epoch, node_ca, bundle })
}

/// A loopback listener on the port the last proxy had (`dir/port`), so the
/// agents an earlier daemon started still reach it; on a new port, written
/// down, when there is none yet or another process holds it. Only the daemon
/// (`keep`) writes the port down: another acpmux process that starts a proxy
/// of its own finds the daemon's port held and takes a new one, and writing
/// that down sent the next daemon to it, away from every agent on the old
/// port (a Freestyle lane, 2026-11-22 17:03Z: the file named 45835, which
/// nothing served until the 17:09Z restart moved the daemon there).
fn bind_stable(dir: &Path, keep: bool) -> std::io::Result<std::net::TcpListener> {
    let file = dir.join(PORT_FILE);
    let kept = std::fs::read_to_string(&file).ok().and_then(|t| t.trim().parse::<u16>().ok());
    if let Some(port) = kept.filter(|p| *p != 0)
        && let Ok(listener) = std::net::TcpListener::bind(("127.0.0.1", port))
    {
        return Ok(listener);
    }
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0))?;
    let port = listener.local_addr()?.port();
    if !keep {
        return Ok(listener);
    }
    if kept.is_some() {
        tracing::warn!(
            code = "vault.egress_port_moved",
            from = ?kept,
            port,
            "the vault egress proxy's port was taken: agents started before now restart between turns"
        );
    }
    // Not keeping it costs only the next restart's port, never this start.
    if let Err(e) = replace(&file, &format!("{port}\n")) {
        tracing::warn!(code = "vault.egress_port_not_kept", kind = ?e.kind(), "vault egress port not kept");
    }
    Ok(listener)
}

/// A name for the CA `ca_pem`: the same in every daemon that serves it.
fn ca_epoch(ca_pem: &str) -> String {
    use sha2::Digest as _;
    let digest = sha2::Sha256::digest(ca_pem.trim().as_bytes());
    digest[..16].iter().map(|b| format!("{b:02x}")).collect()
}

/// `dir`, made and owner-only (0700).
fn private_folder(dir: &Path) -> std::io::Result<()> {
    crate::home_fs::create_dirs(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        crate::home_fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// The CA an earlier daemon kept in `dir` ([`CA_KEY_FILE`], [`CA_CERT_FILE`]),
/// when it is still a valid pair; otherwise a new one, kept there for the
/// next daemon. Not keeping it costs only the next restart's CA, never this
/// start. Logs a code, never key material.
fn kept_or_new_authority(dir: &Path) -> Result<Authority, &'static str> {
    let key = std::fs::read_to_string(dir.join(CA_KEY_FILE)).ok().map(zeroize::Zeroizing::new);
    let cert = std::fs::read_to_string(dir.join(CA_CERT_FILE)).ok();
    let why = match (key, cert) {
        (Some(key), Some(cert)) => match Authority::from_kept(&key, &cert) {
            Ok(authority) => return Ok(authority),
            Err(why) => Some(why.code()),
        },
        _ => None,
    };
    let authority = Authority::generate().map_err(|_| "vault.egress_ca")?;
    if let Some(code) = why {
        tracing::warn!(
            code,
            "vault egress CA not reused: a new one; agents started before now restart between turns"
        );
    }
    // The key first: a crash between the two leaves a pair that does not
    // match, and the next daemon makes a new CA.
    let kept = crate::home_fs::write(dir.join(CA_KEY_FILE), authority.key_pem().as_bytes())
        .and_then(|()| crate::home_fs::write(dir.join(CA_CERT_FILE), authority.pem()));
    if let Err(e) = kept {
        tracing::warn!(code = "vault.egress_ca_not_kept", kind = ?e.kind(), "vault egress CA not kept");
    }
    Ok(authority)
}

/// Write the trust files agents get, in `dir` (0700, made by
/// [`private_folder`]; the files hold certificates only, never a key).
fn write_trust(
    dir: &Path,
    ca_pem: &str,
    inherited: &dyn Fn(&str) -> Option<String>,
) -> std::io::Result<(PathBuf, Option<PathBuf>)> {
    private_folder(dir)?;
    let read = |path: &str| std::fs::read_to_string(path).ok().filter(|t| t.contains("-----BEGIN"));
    let joined = |base: Option<String>| {
        let mut text = base.unwrap_or_default();
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str(ca_pem);
        text
    };
    // A file of ours is never a base: a process an agent of ours started inherits
    // `NODE_EXTRA_CA_CERTS` and `SSL_CERT_FILE` naming them, and extending them
    // added our CA once more each start (a Freestyle lane, 2026-11-22: three CAs in
    // node-extra-ca.pem).
    let foreign = |p: &String| !is_ours(dir, Path::new(p));
    crate::home_fs::write(dir.join(CA_CERT_FILE), ca_pem)?;
    let node_ca = dir.join("node-extra-ca.pem");
    let node_base = inherited("NODE_EXTRA_CA_CERTS").filter(foreign).and_then(|p| read(&p));
    replace(&node_ca, &joined(node_base))?;
    let base = inherited("SSL_CERT_FILE")
        .filter(foreign)
        .and_then(|p| read(&p))
        .or_else(|| SYSTEM_BUNDLES.iter().find_map(|p| read(p)));
    let bundle = match base {
        Some(base) => {
            let path = dir.join("ca-bundle.pem");
            replace(&path, &joined(Some(base)))?;
            Some(path)
        }
        None => None,
    };
    Ok((node_ca, bundle))
}

/// Whether `path` is a file in `dir`, the trust files' folder (whichever way
/// either is spelled: a symlinked home, a relative path).
fn is_ours(dir: &Path, path: &Path) -> bool {
    let real = |p: &Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    let parent = path.parent().map(real);
    parent.is_some_and(|p| p == real(dir)) || path.starts_with(dir)
}

/// Write by rename, so a running agent never reads half a bundle.
fn replace(path: &Path, text: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    crate::home_fs::write(&tmp, text)?;
    crate::home_fs::rename(&tmp, path)
}

/// The secrets the proxy serves now (at most [`POLICY_TTL`] old): the
/// proxy entries a spawn would get, with their hosts.
pub(crate) fn policy_now() -> Arc<Policy> {
    if let Some((at, policy)) = &*POLICY.lock().unwrap_or_else(|e| e.into_inner())
        && at.elapsed() < POLICY_TTL
    {
        return policy.clone();
    }
    let machine = MACHINE_CREDENTIAL
        .load(std::sync::atomic::Ordering::SeqCst)
        .then(crate::joined_model_plane::secret_now)
        .flatten();
    let policy = Arc::new(policy_with(machine, super::entries_now()));
    *POLICY.lock().unwrap_or_else(|e| e.into_inner()) = Some((Instant::now(), policy.clone()));
    policy
}

#[cfg(test)]
pub(crate) fn policy_of(entries: Vec<Given>) -> Policy {
    policy_with(None, entries)
}

/// [`policy_of`] with the built-in `machine` entry first (`joined_model_plane::secret`), so no
/// vault entry of the same name takes its place toward the hub.
pub(crate) fn policy_with(machine: Option<Secret>, entries: Vec<Given>) -> Policy {
    Policy::new(
        machine
            .into_iter()
            .chain(entries.into_iter().filter_map(|g| {
                let hosts = g.proxy?.iter().filter_map(|h| HostPattern::parse(h)).collect();
                Some(Secret::new(g.name, g.value, hosts))
            }))
            .collect(),
    )
}

#[cfg(test)]
#[path = "egress_tests.rs"]
mod tests;
