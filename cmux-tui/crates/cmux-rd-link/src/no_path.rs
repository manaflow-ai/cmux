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
mod tests {
    use super::*;

    #[test]
    fn host_candidates_only_and_nothing_heard_says_there_is_no_path_and_no_relay() {
        // The viewer's side of the measured failure: 4 host candidates each, nothing heard.
        let why = handshake_timeout([4, 0, 0], [4, 0, 0], 0);
        assert!(why.starts_with("no network path between the two machines"), "{why}");
        assert!(why.contains("public address (STUN)"), "{why}");
        assert!(why.contains("relay (TURN) server"), "{why}");
        assert!(why.ends_with(
            "(the secure handshake timed out; local host 4 srflx 0 relay 0; \
             peer host 4 srflx 0 relay 0; heard 0)"
        ));
    }

    #[test]
    fn heard_but_not_answered_says_one_way() {
        // The host's side: it heard the viewer 39 times, the viewer heard nothing.
        let why = handshake_timeout([4, 0, 0], [4, 0, 0], 39);
        assert!(why.contains("one way only"), "{why}");
        assert!(why.contains("heard 39)"), "{why}");
    }

    #[test]
    fn names_the_missing_relay_or_the_failed_one() {
        assert!(
            handshake_timeout([4, 1, 0], [4, 1, 0], 0)
                .contains("no relay (TURN) server was offered")
        );
        assert!(
            handshake_timeout([4, 1, 1], [4, 1, 0], 0)
                .contains("relay (TURN) path did not connect")
        );
    }
}
