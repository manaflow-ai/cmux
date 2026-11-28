//! A workspace on this machine for the person's other machines: a hub carrier circuit that names
//! [`CircuitService::CmuxTuiSession`] reaches this machine's own cmux-tui session daemon (the one
//! its app shows, `CMUX_TUI_SOCKET` in acpmux's environment), so New Workspace on another of the
//! person's Macs opens a workspace and its terminals here, with no ssh.
//!
//! The consent is the person's, on this machine, once (Leo, 2026-11-14: "ok then do that", to
//! option (a) of cmuxterm-hq#11046): "control for my other machines signed in to this account"
//! (`signedInMachines` in `cli/machine_consent.rs`). It is off by default, and signing in never
//! grants it. The first circuit refused for it records an ask (`refusal.json`, with the asking
//! machine's host), which the app on this machine shows as its one consent card; Allow grants it
//! (`_acpmux/machine_consent_set`, the person's connection only), Not now answers it, and either
//! answer means no new ask. A later Off revokes it; a circuit already open stays until it ends.
//! The grant names the account it was given for: once this machine is joined as another account,
//! nothing is granted and the person is asked again.
//!
//! A machine joined from another device (a join line, a pair code, a fleet or Cloud enrollment:
//! any join but signing in on it) needs no ask: the join is the consent, as for screen sharing
//! (hq `docs/design/remote-screen-share-zero-touch.md` Z4, "Joining is the whole consent";
//! `share_host::helper::share_by_join_here`). Nobody sits at a Cloud VM or a lane VM to click
//! Allow, and `cmux ssh` to it must work with zero actions on it (Leo, 2026-11-22: "we need to
//! have these bundled in"). The person's own answer still wins: a Not now or an Off on that
//! machine refuses as before. A Mac signed in on itself keeps its one ask.
//!
//! A machine nobody opened cmux on (a headless box: `CMUX_TUI_SOCKET` unset) still serves the
//! circuit: once admitted, acpmux finds or starts its local session owner with
//! `cmux daemon ensure` and reaches that socket.
//!
//! What grants what: the carrier's Noise handshake proves the dialer is one of this person's
//! live machines (the platform's `peers`). That proof plus this consent is the whole grant: the
//! session daemon then sees a trusted local client, as the app on this machine is.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::cli::cloud_join::{CONSENT_REQUIRED, SIGNED_IN_MACHINES};
use crate::hub::Hub;
use crate::hub_carrier::{ServiceRefusal, SessionGate};

/// The refusal reason once the person answered the ask with Not now, or turned it off.
pub const CONSENT_DECLINED: &str = "consent_declined";

/// What the gate decided, before the socket is checked: admit, or refuse and whether that
/// refusal is the machine's one ask.
#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Admit,
    /// Refused; `ask` when nothing was answered yet, so the app on this machine asks once.
    Refuse {
        refusal: ServiceRefusal,
        ask: bool,
    },
}

/// Whether a circuit from another of the person's machines may open workspaces here, given this
/// machine's consent status (`_acpmux/machine_consent_get`'s answer) and whether this machine
/// was joined from another device (`joined_elsewhere`: the join is the consent unless the person
/// answered here for this account). Otherwise only the word `granted` admits; an unreadable
/// status refuses. `consentRequired` does not matter: this grant is
/// always the person's own, joined or not. The grant and the answer hold only for the account
/// they were given for (`signedInMachinesUser`) while this machine is joined as `account`: after
/// a switch to another account nothing is granted and it is asked again. A pending ask (the last
/// refusal is already this surface's) is not recorded again.
pub fn decide(consent: &Value, account: Option<&str>, joined_elsewhere: bool) -> Decision {
    let for_account = account.is_some_and(|account| {
        consent.pointer("/consent/signedInMachinesUser").and_then(Value::as_str) == Some(account)
    });
    if crate::machine_record::signed_in_machines_granted(consent, account) {
        return Decision::Admit;
    }
    let answered = for_account
        && consent.pointer("/consent/signedInMachinesAnsweredAt").is_some_and(|at| !at.is_null());
    // An unreadable status (no `consent` record) could hide the person's Off: it refuses.
    let readable = consent.get("consent").is_some_and(Value::is_object);
    if joined_elsewhere && account.is_some() && readable && !answered {
        return Decision::Admit;
    }
    let pending =
        consent.pointer("/lastRefusal/surface").and_then(Value::as_str) == Some(SIGNED_IN_MACHINES);
    if answered {
        Decision::Refuse {
            refusal: ServiceRefusal::new(
                CONSENT_DECLINED,
                "the person on that machine has not allowed workspaces from their other \
                 machines; they can turn it on there, in Settings > Devices",
            ),
            ask: false,
        }
    } else {
        Decision::Refuse {
            refusal: ServiceRefusal::new(
                CONSENT_REQUIRED,
                "waiting for the person on that machine to allow workspaces from their other \
                 machines: cmux there asks once",
            ),
            ask: !pending,
        }
    }
}

/// The session daemon's socket, when `path` names one this user owns: an absolute path to a
/// socket (not a symlink) whose owner is this process's user. Anything else refuses, so a
/// circuit never reaches another user's socket or a file put in its place.
pub fn session_socket(path: Option<&Path>) -> Result<PathBuf, ServiceRefusal> {
    let off = || {
        ServiceRefusal::new(
            "service.off",
            "this machine's cmux has no session to open a workspace in (no CMUX_TUI_SOCKET)",
        )
    };
    let path = path.filter(|p| p.is_absolute()).ok_or_else(off)?;
    owned_socket(path).then(|| path.to_path_buf()).ok_or_else(|| {
        ServiceRefusal::new(
            "service.unreachable",
            "this machine's cmux session is not running (its socket is missing or not its own)",
        )
    })
}

#[cfg(unix)]
fn owned_socket(path: &Path) -> bool {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    std::fs::symlink_metadata(path).is_ok_and(|m| {
        // SAFETY: geteuid has no preconditions.
        m.file_type().is_socket() && m.uid() == unsafe { libc::geteuid() }
    })
}
#[cfg(not(unix))]
fn owned_socket(_path: &Path) -> bool {
    false
}

/// How long `cmux daemon ensure` may take to start a session owner (it waits until the owner
/// accepts clients; a cold start is about a second).
const ENSURE_DEADLINE: std::time::Duration = std::time::Duration::from_secs(15);

/// The socket of this machine's local session owner on a box with no `CMUX_TUI_SOCKET` (no app
/// started acpmux): found or started by `cmux daemon ensure`, read from its `socket` field. None
/// when there is no cmux CLI here or it did not answer in time; the gate then refuses as
/// `service.off`. Blocking: called on the gate's blocking task.
fn ensure_local_session() -> Option<PathBuf> {
    let program =
        crate::agent_tools::project_mcp::cmux_program().unwrap_or_else(|| PathBuf::from("cmux"));
    let mut child = cmux_process::Command::new(program)
        .args(["--json", "daemon", "ensure"])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .ok()?;
    // The owner `ensure` starts detaches on its own; `ensure` itself answers and exits. Past the
    // deadline the child is dropped, which ends it.
    if child.wait_timeout(ENSURE_DEADLINE).ok().flatten().is_none() {
        tracing::warn!("cmux daemon ensure did not answer in time");
        return None;
    }
    let mut out = String::new();
    std::io::Read::read_to_string(child.stdout.as_mut()?, &mut out).ok()?;
    ensured_socket(&out)
}

/// The `socket` a `cmux --json daemon ensure` answer names, when it started or found an owner.
pub fn ensured_socket(answer: &str) -> Option<PathBuf> {
    let answer: Value = serde_json::from_str(answer.trim()).ok()?;
    let status = answer.get("status").and_then(Value::as_str)?;
    if !matches!(status, "started" | "running") {
        return None;
    }
    answer.get("socket").and_then(Value::as_str).filter(|s| !s.is_empty()).map(PathBuf::from)
}

/// The daemon's gate: the machine's consent record and its own `CMUX_TUI_SOCKET`.
pub struct ConfiguredSessionGate {
    hub: Weak<Hub>,
}

impl ConfiguredSessionGate {
    pub fn new(hub: &Arc<Hub>) -> Self {
        Self { hub: Arc::downgrade(hub) }
    }
}

/// How long an admission waits for the hub's book to list the dialer.
const BOOK_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

#[async_trait]
impl SessionGate for ConfiguredSessionGate {
    async fn admit(&self, from: &str) -> Result<PathBuf, ServiceRefusal> {
        let hub =
            self.hub.upgrade().ok_or_else(|| ServiceRefusal::new("service.off", "stopping"))?;
        // Defense in depth beside the carrier's handshake (the platform's list of this person's
        // machines): this machine's own read of the hub's book must list the dialer too.
        // A machine that just joined reaches here before the hub's next book does: wait for
        // the book a few seconds rather than refuse the dialer.
        let listed = cmux_tui_util::retry::Patience::new("the hub book", BOOK_WAIT)
            .quiet()
            .spaced(std::time::Duration::from_millis(100), std::time::Duration::from_secs(1))
            .run_async(|| (), {
                let hub = &hub;
                move || async move {
                    hub.mesh_book_machine(from).ok_or(cmux_tui_util::retry::Attempt::Retry(()))
                }
            })
            .await;
        let Ok(host) = listed else {
            return Err(ServiceRefusal::new(
                "machine.unlisted",
                "this machine's hub book does not list the asking machine for its account; \
                 the asking machine is not signed in to this account, or the hub has not \
                 listed it",
            ));
        };
        tokio::task::spawn_blocking(move || {
            let consent = crate::cli::cloud_join::consent_status_for(&json!({}));
            let account = crate::cli::cloud_join::machine_user_id();
            let joined_elsewhere = crate::machine_record::joined_from_another_device();
            match decide(&consent, account.as_deref(), joined_elsewhere) {
                Decision::Admit => {
                    let socket = std::env::var_os(crate::launch_credential::SESSION_SOCKET_ENV)
                        .filter(|s| !s.is_empty())
                        .map(PathBuf::from)
                        .or_else(ensure_local_session);
                    session_socket(socket.as_deref())
                }
                Decision::Refuse { refusal, ask } => {
                    if ask {
                        // The app on this machine shows its one ask (`lastRefusal`).
                        let _ = crate::cli::cloud_join::record_consent_refusal_from(
                            SIGNED_IN_MACHINES,
                            Some(host.as_str()),
                        );
                    }
                    Err(refusal)
                }
            }
        })
        .await
        .unwrap_or_else(|_| Err(ServiceRefusal::new(CONSENT_REQUIRED, "consent unreadable")))
    }
}

#[cfg(test)]
#[path = "session_service_tests.rs"]
mod tests;
