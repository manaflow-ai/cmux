//! Move one tailnet node from one machine to another (RFD 0169, "identity handoff").
//!
//! The user's tailnet sees one stable cmux node per user. The VM under it changes (a resize, a
//! resume elsewhere, a spare swapped in), and the node's identity moves with the work: the old
//! holder stops `tailscaled` and hands over its state file (machine key, node key, login), and
//! the new holder starts `tailscaled` on that state. The tailnet never sees a new device: same
//! name, same addresses, same node key, no new auth key.
//!
//! One holder at a time: two machines running one node key fight over its endpoint. So the old
//! holder stops before the state leaves it, the new holder starts only after, and the old one
//! deletes its copy once the new one is online ([`forget_command`]). If the new holder cannot
//! come up, [`restore_command`] starts the old one again on the copy it still has.
//!
//! Steps, run by the caller over the Cloud exec and file APIs (pure here, like the join):
//!
//! 1. Old holder: [`release_command`] (one exec, seconds). Its answer carries the state as one
//!    base64 word ([`parse_released`]); the caller keeps it as a [`Secret`] in memory only.
//! 2. New holder: `prepare_command`, then the state written 0600 to [`STAGED_STATE_FILE`]
//!    ([`Released::staged_contents`]), [`vm_adopt_script`] 0700 to `SCRIPT_FILE`, then
//!    `start_command` and `read_command` until `read_answer` ends: the same detached run as a
//!    join (installing Tailscale can outlast one exec). It ends with the join's result line.
//! 3. Old holder: [`forget_command`]; on a failed step 2, [`restore_command`] instead.
//!
//! The gap the user sees is stop to online. Both machines print their clock at that moment
//! ([`parse_released`]'s `stopped_at_ms`, [`online_at_ms`]), so the gap is measured on the
//! machines, not through the caller's polling.

use crate::{JOIN_TIMEOUT_SECS, ROOT, RUN_DIR, Secret};

/// Where `tailscaled` keeps its state on a VM (the Linux package's default).
pub const STATE_FILE: &str = "/var/lib/tailscale/tailscaled.state";

/// Where the new holder finds the state the caller wrote (tmpfs, 0600, deleted by the script on
/// every exit path). Base64 text, as [`release_command`] printed it.
pub const STAGED_STATE_FILE: &str = "/run/cmux-tailnet/node.state";

/// The largest state a release may hand over. A node's state file is a few KB; this bounds what
/// the caller holds in memory and writes, whatever a broken machine prints.
pub const MAX_STATE_BYTES: usize = 256 * 1024;

/// Stops `tailscaled` (a systemd unit, else the process), as used by both scripts.
const STOP: &str = "if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then root systemctl disable --now tailscaled >/dev/null 2>&1 || root systemctl stop tailscaled >/dev/null 2>&1 || true; fi; \
root pkill -x tailscaled >/dev/null 2>&1 || true; \
i=0; while pgrep -x tailscaled >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 50 ] && { echo 'cmux-tailnet: tailscaled did not stop' >&2; exit 3; }; sleep 0.2; done";

/// Starts `tailscaled` on [`STATE_FILE`]: the systemd unit where there is one, else a detached
/// process with the package's default flags.
const START: &str = "if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then root systemctl enable --now tailscaled >&2; \
else root mkdir -p /var/run/tailscale; root setsid tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock </dev/null >>/var/log/cmux-tailnet-tailscaled.log 2>&1 & fi";

/// Once the node is `Running` on the new holder: start a WireGuard handshake from here to every
/// online peer (one TSMP ping each, `tailscale ping --tsmp`, detached, at most 64 peers, 3 s at
/// worst; milliseconds when the peer answers).
///
/// Why: the new holder's first map request carries its new disco key before it has found its
/// own endpoints, so control pushes peers the new disco key next to the old holder's endpoints.
/// A peer (the user's laptop) drops its session on the disco change, sends one handshake down
/// that dead path, and WireGuard retries only after REKEY_TIMEOUT (5 s), even though the right
/// endpoint arrives about 0.8 s later: the laptop saw ~7 s instead of ~2.5 s on 9 of 20 moves
/// (`testing/handoff-e2e.sh`, verbose tailscaled logs). A handshake started from this side
/// reaches the peer from this machine's real endpoint and gives it a session at once. TSMP runs
/// through WireGuard but around the packet filter, so it works where the policy refuses this
/// node dialing the user's devices. A disco ping alone starts no handshake (it did not help);
/// disco pings before the TSMP ping delayed the handshake past its use (measured worse).
const PEER_KICK: &str = "( i=0; until tailscale status --json --peers=false 2>/dev/null | tr -d '\\n' | grep -q '\"Addrs\": *\\[ *\"'; do i=$((i+1)); [ $i -gt 20 ] && break; sleep 0.1; done; tailscale status --self=false 2>/dev/null | awk '($1 ~ /^100\\./ || $1 ~ /^fd7a:/) && $0 !~ / offline/ {print $1}' | head -n 64 | while read -r ip; do tailscale ping --tsmp -c 1 --timeout 3s \"$ip\" & done; wait ) </dev/null >/dev/null 2>&1 &";

/// One exec on the old holder: stop `tailscaled`, print its state as one base64 word, print the
/// machine's clock at the stop. The state file stays on the machine until [`forget_command`], so
/// [`restore_command`] can bring the node back here if the move fails.
pub fn release_command() -> String {
    format!(
        "{ROOT}; f={STATE_FILE}; \
if root test -L \"$f\" || ! root test -s \"$f\"; then echo 'cmux-tailnet: no node state on this machine (not on a tailnet, or not through system Tailscale)' >&2; exit 3; fi; \
{STOP}; \
printf 'cmux-tailnet-stopped-at %s\\n' \"$(date +%s%3N)\"; \
printf 'cmux-tailnet-state '; root base64 -w0 \"$f\" || exit 1; echo; \
echo cmux-tailnet-released"
    )
}

/// What [`release_command`] handed over.
#[derive(Debug)]
pub struct Released {
    /// The state file, base64. A secret: the node's private keys.
    pub state: Secret,
    /// The old holder's clock when `tailscaled` had stopped (ms since the epoch), if it said.
    pub stopped_at_ms: Option<u64>,
}

impl Released {
    /// What the caller writes, 0600, to [`STAGED_STATE_FILE`] on the new holder.
    pub fn staged_contents(&self) -> String {
        format!("{}\n", self.state.expose())
    }
}

/// Reads [`release_command`]'s stdout. `Err` is why there is no state to move, in words.
pub fn parse_released(stdout: &str) -> Result<Released, String> {
    if !stdout.lines().any(|l| l.trim() == "cmux-tailnet-released") {
        return Err("the old machine did not hand over its node state".to_owned());
    }
    let mut state = None;
    let mut stopped_at_ms = None;
    for line in stdout.lines() {
        if let Some(word) = line.strip_prefix("cmux-tailnet-state ") {
            state = Some(word.trim());
        } else if let Some(ms) = line.strip_prefix("cmux-tailnet-stopped-at ") {
            stopped_at_ms = ms.trim().parse().ok();
        }
    }
    let state = state.unwrap_or_default();
    if state.is_empty() {
        return Err("the old machine's node state is empty".to_owned());
    }
    if state.len() > MAX_STATE_BYTES {
        return Err(format!(
            "the old machine's node state is {} bytes, more than a node's state ever is",
            state.len()
        ));
    }
    if !state.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'=')) {
        return Err("the old machine's node state is not base64".to_owned());
    }
    Ok(Released { state: Secret::new(state), stopped_at_ms })
}

/// The new holder's script (run as root, detached, like the join script): install Tailscale if
/// missing, stop any `tailscaled`, put the handed-over state in place (0600), start `tailscaled`
/// on it and wait until the node is `Running`. No auth key: the state is already signed in. Ends
/// with the join's `cmux-tailnet-joined` line (`parse_joined`) after `cmux-tailnet-online-at`.
pub fn vm_adopt_script() -> String {
    let mut s = String::new();
    s.push_str("#!/bin/sh\n# cmux: take over the user's tailnet node from the machine that held it (cmux-tailnet-join handoff).\nset -eu\n");
    s.push_str(ROOT);
    s.push('\n');
    s.push_str(&format!(
        "k={STAGED_STATE_FILE}\nf={STATE_FILE}\ntrap 'rm -f \"$k\" \"$f.cmux-new\" 2>/dev/null || true' EXIT INT TERM\n"
    ));
    s.push_str("if [ -L \"$k\" ] || [ ! -s \"$k\" ]; then echo 'cmux-tailnet: the node state file is missing or a symlink' >&2; exit 3; fi\n");
    s.push_str(
        "if ! command -v tailscale >/dev/null 2>&1 || ! command -v tailscaled >/dev/null 2>&1; then\n  curl -fsSL https://tailscale.com/install.sh | sh >&2\nfi\n",
    );
    // A fresh install starts tailscaled with a new, logged-out state: stop it before the swap.
    s.push_str(&format!("{STOP}\n"));
    s.push_str("mkdir -p \"$(dirname \"$f\")\"\nchmod 700 \"$(dirname \"$f\")\"\n");
    s.push_str(
        "if [ -L \"$f\" ]; then echo 'cmux-tailnet: the state path is a symlink' >&2; exit 3; fi\n",
    );
    s.push_str("umask 077\nbase64 -d \"$k\" >\"$f.cmux-new\" || { echo 'cmux-tailnet: the node state is not base64' >&2; exit 3; }\n");
    s.push_str(
        "[ -s \"$f.cmux-new\" ] || { echo 'cmux-tailnet: the node state is empty' >&2; exit 3; }\n",
    );
    s.push_str("chmod 600 \"$f.cmux-new\"\nmv -f \"$f.cmux-new\" \"$f\"\n");
    s.push_str(&format!("{START}\n"));
    // Running is the node signed in and connected to its control server: from here the user's
    // devices reach it at its old name and addresses.
    s.push_str(&format!(
        "i=0; until tailscale status --json --peers=false 2>/dev/null | tr -d '\\n' | grep -q '\"BackendState\": *\"Running\"'; do i=$((i+1)); [ $i -gt {} ] && {{ echo 'cmux-tailnet: the node did not come online on this machine' >&2; tailscale status >&2 || true; exit 3; }}; sleep 0.1; done\n",
        JOIN_TIMEOUT_SECS * 10
    ));
    s.push_str("printf 'cmux-tailnet-online-at %s\\n' \"$(date +%s%3N)\"\n");
    s.push_str(PEER_KICK);
    s.push('\n');
    s.push_str("printf 'cmux-tailnet-joined '; tailscale status --json --peers=false | tr -d '\\n'; echo\n");
    s
}

/// The new holder's clock when its node was `Running` (ms since the epoch), from the adopt run's
/// stdout (`read_command`'s answer).
pub fn online_at_ms(stdout: &str) -> Option<u64> {
    stdout
        .lines()
        .find_map(|l| l.strip_prefix("cmux-tailnet-online-at "))
        .and_then(|ms| ms.trim().parse().ok())
}

/// One exec on the old holder after the new one is online: delete its copy of the state, so a
/// resume or a copy of this machine can never come up as the node.
pub fn forget_command() -> String {
    format!("{ROOT}; root rm -f {STATE_FILE} {RUN_DIR}/node.state && echo cmux-tailnet-forgot")
}

/// One exec on the old holder when the move failed: start `tailscaled` again on the state it
/// kept, so the node is back where it was.
pub fn restore_command() -> String {
    format!("{ROOT}; {START}; echo cmux-tailnet-restored")
}

#[cfg(test)]
#[path = "handoff_tests.rs"]
mod tests;
