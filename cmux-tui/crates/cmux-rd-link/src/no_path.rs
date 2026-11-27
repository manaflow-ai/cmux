//! Why a link found no path, in words the viewer's failed card can show
//! ("The connection to NAME failed: <this>"), with the counts after it for
//! whoever reads the log. Counts only, never an address.

/// Candidate counts by kind: host, server-reflexive (STUN), relay (TURN).
pub(super) type Counts = [u32; 3];

/// The reason for a secure handshake that timed out. `local` is what this side
/// gathered, `peer` what the peer sent, `heard` how many link packets reached
/// this side.
pub(super) fn handshake_timeout(local: Counts, peer: Counts, heard: u64) -> String {
    let [_, l_srflx, l_relay] = local;
    let [_, p_srflx, p_relay] = peer;
    let what = if heard == 0 {
        "no network path between the two machines: nothing from the other machine arrived here"
    } else {
        "the other machine's packets arrived here, but this side's answers never reached it \
         (its network lets traffic through one way only)"
    };
    let fallback = match (l_relay + p_relay > 0, l_srflx + p_srflx > 0) {
        (true, _) => "the relay (TURN) path did not connect either",
        (false, true) => "no relay (TURN) server was offered for this session to carry it instead",
        (false, false) => {
            "neither side found its public address (STUN) or had a relay (TURN) server \
             to carry it instead"
        }
    };
    format!("{what}; {fallback} (the secure handshake timed out; {})", counts(local, peer, heard))
}

/// `local host H srflx S relay R; peer host H srflx S relay R; heard N`.
pub(super) fn counts(local: Counts, peer: Counts, heard: u64) -> String {
    let [host, srflx, relay] = local;
    let [p_host, p_srflx, p_relay] = peer;
    format!(
        "local host {host} srflx {srflx} relay {relay}; \
         peer host {p_host} srflx {p_srflx} relay {p_relay}; heard {heard}"
    )
}

#[cfg(test)]
#[path = "no_path_tests.rs"]
mod tests;
