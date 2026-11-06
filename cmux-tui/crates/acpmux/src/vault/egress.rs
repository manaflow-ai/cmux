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
//!   is only in this daemon's memory.
//! - A launch whose environment already names an `HTTPS_PROXY` keeps it:
//!   its placeholders are then never filled (fail closed), logged once as
//!   `vault.egress_proxy_conflict`.
//! - The proxy starts on the first spawn that needs it and runs for the
//!   daemon's life. Each request reads the entries again (at most 2 s old),
//!   so a revoke, a removed grant or a narrowed host list holds within that.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_vault_egress::{Authority, Config, HostPattern, Policy, Resolver, Secret, placeholder};

use super::Given;

/// Where the proxy runs and the trust files its agents get.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Running {
    pub port: u16,
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

/// Bundles agents' TLS stacks read when `SSL_CERT_FILE` is unset, first found wins.
const SYSTEM_BUNDLES: &[&str] = &[
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
    "/etc/pki/tls/cacert.pem",
    "/etc/ssl/cert.pem",
];

/// The proxy's part of the agent pool's key: a spawn made before the proxy
/// started (or on another port) is not reused.
pub(crate) fn stamp() -> String {
    match &*SLOT.lock().unwrap_or_else(|e| e.into_inner()) {
        Slot::Up(running) => running.port.to_string(),
        _ => "off".to_owned(),
    }
}

/// What a spawn's env gets from `entries` (see the module docs).
pub(crate) fn child_env(entries: Vec<Given>) -> Vec<(String, String)> {
    let wants_proxy = entries.iter().any(|g| g.proxy.is_some());
    let running = if wants_proxy { ensure() } else { None };
    child_env_with(entries, running.as_ref(), &inherited)
}

/// The value a launch would have without the vault: the login env's, else
/// the daemon's own.
fn inherited(name: &str) -> Option<String> {
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
    if inherited("HTTPS_PROXY").is_some() || inherited("https_proxy").is_some() {
        if !CONFLICT_LOGGED.swap(true, std::sync::atomic::Ordering::SeqCst) {
            tracing::warn!(
                code = "vault.egress_proxy_conflict",
                "this launch already has an HTTPS proxy; vault placeholders are not filled"
            );
        }
        return out;
    }
    let url = format!("http://127.0.0.1:{}", running.port);
    out.push(("HTTPS_PROXY".to_owned(), url.clone()));
    out.push(("https_proxy".to_owned(), url));
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
    out
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
    let authority = Arc::new(Authority::generate().map_err(|_| "vault.egress_ca")?);
    let upstream_tls =
        cmux_vault_egress::upstream_tls_from_os().map_err(|_| "vault.egress_no_roots")?;
    let (node_ca, bundle) = write_trust(&home.join("vault-egress"), authority.pem(), &inherited)
        .map_err(|_| "vault.egress_trust_files")?;
    let listener =
        std::net::TcpListener::bind(("127.0.0.1", 0)).map_err(|_| "vault.egress_bind")?;
    listener.set_nonblocking(true).map_err(|_| "vault.egress_bind")?;
    let port = listener.local_addr().map_err(|_| "vault.egress_bind")?.port();
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
    Ok(Running { port, node_ca, bundle })
}

/// Write the trust files agents get, in `dir` (0700; the files hold
/// certificates only, never a key).
fn write_trust(
    dir: &Path,
    ca_pem: &str,
    inherited: &dyn Fn(&str) -> Option<String>,
) -> std::io::Result<(PathBuf, Option<PathBuf>)> {
    std::fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    let read = |path: &str| std::fs::read_to_string(path).ok().filter(|t| t.contains("-----BEGIN"));
    let joined = |base: Option<String>| {
        let mut text = base.unwrap_or_default();
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str(ca_pem);
        text
    };
    std::fs::write(dir.join("ca.pem"), ca_pem)?;
    let node_ca = dir.join("node-extra-ca.pem");
    let node_base = inherited("NODE_EXTRA_CA_CERTS").and_then(|p| read(&p));
    replace(&node_ca, &joined(node_base))?;
    let base = inherited("SSL_CERT_FILE")
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

/// Write by rename, so a running agent never reads half a bundle.
fn replace(path: &Path, text: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)
}

/// The secrets the proxy serves now (at most [`POLICY_TTL`] old): the
/// proxy entries a spawn would get, with their hosts.
pub(crate) fn policy_now() -> Arc<Policy> {
    if let Some((at, policy)) = &*POLICY.lock().unwrap_or_else(|e| e.into_inner())
        && at.elapsed() < POLICY_TTL
    {
        return policy.clone();
    }
    let policy = Arc::new(policy_of(super::entries_now()));
    *POLICY.lock().unwrap_or_else(|e| e.into_inner()) = Some((Instant::now(), policy.clone()));
    policy
}

pub(crate) fn policy_of(entries: Vec<Given>) -> Policy {
    Policy::new(
        entries
            .into_iter()
            .filter_map(|g| {
                let hosts = g.proxy?.iter().filter_map(|h| HostPattern::parse(h)).collect();
                Some(Secret::new(g.name, g.value, hosts))
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use zeroize::Zeroizing;

    fn given(name: &str, value: &str, proxy: Option<&[&str]>) -> Given {
        Given {
            name: name.to_owned(),
            value: Zeroizing::new(value.to_owned()),
            proxy: proxy.map(|h| h.iter().map(|s| (*s).to_owned()).collect()),
        }
    }

    fn running() -> Running {
        Running {
            port: 41234,
            node_ca: PathBuf::from("/h/vault-egress/node-extra-ca.pem"),
            bundle: Some(PathBuf::from("/h/vault-egress/ca-bundle.pem")),
        }
    }

    fn get<'a>(env: &'a [(String, String)], name: &str) -> Option<&'a str> {
        env.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }

    #[test]
    fn proxy_entries_are_placeholders_and_env_entries_are_values() {
        let env = child_env_with(
            vec![
                given("GITHUB_TOKEN", "ghp_secret_value", Some(&["api.github.com"])),
                given("DATABASE_URL", "postgres://u:pw@db/x", None),
            ],
            Some(&running()),
            &|_| None,
        );
        assert_eq!(get(&env, "GITHUB_TOKEN"), Some("cmux-secret://GITHUB_TOKEN"));
        assert_eq!(get(&env, "DATABASE_URL"), Some("postgres://u:pw@db/x"));
        assert_eq!(get(&env, "HTTPS_PROXY"), Some("http://127.0.0.1:41234"));
        assert_eq!(get(&env, "https_proxy"), Some("http://127.0.0.1:41234"));
        assert_eq!(get(&env, "NO_PROXY"), Some("localhost,127.0.0.1,::1,.cmux.internal"));
        assert_eq!(get(&env, "NODE_EXTRA_CA_CERTS"), Some("/h/vault-egress/node-extra-ca.pem"));
        assert_eq!(get(&env, "SSL_CERT_FILE"), Some("/h/vault-egress/ca-bundle.pem"));
        assert!(!env.iter().any(|(_, v)| v.contains("ghp_secret_value")));
    }

    #[test]
    fn no_proxy_entry_means_no_proxy_settings() {
        let env = child_env_with(vec![given("A", "a", None)], Some(&running()), &|_| None);
        assert_eq!(env, vec![("A".to_owned(), "a".to_owned())]);
    }

    #[test]
    fn a_proxy_that_did_not_start_still_withholds_the_value() {
        let env =
            child_env_with(vec![given("T", "secret", Some(&["x.example.com"]))], None, &|_| None);
        assert_eq!(env, vec![("T".to_owned(), "cmux-secret://T".to_owned())]);
    }

    #[test]
    fn an_existing_https_proxy_is_kept_and_the_value_still_withheld() {
        let inherited = |n: &str| (n == "HTTPS_PROXY").then(|| "http://corp:3128".to_owned());
        let env = child_env_with(
            vec![given("T", "secret", Some(&["x.example.com"]))],
            Some(&running()),
            &inherited,
        );
        assert_eq!(env, vec![("T".to_owned(), "cmux-secret://T".to_owned())]);
    }

    #[test]
    fn no_proxy_keeps_what_the_launch_had() {
        assert_eq!(
            no_proxy(Some(" corp.lan, localhost ,".into())),
            "corp.lan,localhost,127.0.0.1,::1,.cmux.internal"
        );
    }

    #[test]
    fn policy_holds_only_proxy_entries_with_their_valid_hosts() {
        let policy = policy_of(vec![
            given("T", "secret", Some(&["api.github.com", "not a host"])),
            given("E", "env-value", None),
        ]);
        assert_eq!(policy.secrets().len(), 1);
        assert_eq!(policy.secrets()[0].name(), "T");
        assert_eq!(policy.secrets()[0].hosts().len(), 1);
        assert!(policy.intercepts("api.github.com", 443));
    }

    #[test]
    fn trust_files_extend_what_the_launch_trusted() {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().join("base.pem");
        std::fs::write(&base, "-----BEGIN CERTIFICATE-----\nBASE\n-----END CERTIFICATE-----")
            .unwrap();
        let node = dir.path().join("node.pem");
        std::fs::write(&node, "-----BEGIN CERTIFICATE-----\nNODE\n-----END CERTIFICATE-----\n")
            .unwrap();
        let (b, n) = (base.display().to_string(), node.display().to_string());
        let inherited = move |name: &str| match name {
            "SSL_CERT_FILE" => Some(b.clone()),
            "NODE_EXTRA_CA_CERTS" => Some(n.clone()),
            _ => None,
        };
        let ca = "-----BEGIN CERTIFICATE-----\nOURS\n-----END CERTIFICATE-----\n";
        let out = dir.path().join("egress");
        let (node_ca, bundle) = write_trust(&out, ca, &inherited).unwrap();
        let node_text = std::fs::read_to_string(node_ca).unwrap();
        assert!(node_text.contains("NODE") && node_text.ends_with(ca));
        let bundle_text = std::fs::read_to_string(bundle.unwrap()).unwrap();
        assert!(
            bundle_text.starts_with("-----BEGIN CERTIFICATE-----\nBASE")
                && bundle_text.ends_with(ca)
        );
    }
}
