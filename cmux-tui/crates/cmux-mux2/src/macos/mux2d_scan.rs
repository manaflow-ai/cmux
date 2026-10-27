//! Query detection for the unwatched batch path.

/// True when `data` holds a sequence the program waits on for a reply.
/// Conservative: a false positive only costs an early parse.
pub(super) fn needs_immediate_parse(data: &[u8]) -> bool {
    let mut i = 0;
    while let Some(&b) = data.get(i) {
        match b {
            0x05 => return true, // ENQ answerback
            0x1b => {
                // The parser executes C0 controls (other than CAN, SUB and
                // ESC) and ignores DEL in the escape state: look past them.
                let mut k = i + 1;
                while data.get(k).is_some_and(|&b| executes_inside(b)) {
                    k += 1;
                }
                let Some(&next) = data.get(k) else { return true };
                match next {
                    // OSC, DCS, APC, PM, SOS: color/title queries, XTGETTCAP,
                    // DECRQSS, kitty graphics queries. DECID (ESC Z) is DA1.
                    b']' | b'P' | b'_' | b'^' | b'X' | b'Z' => return true,
                    b'[' => {
                        let mut j = k + 1;
                        // Parameters and intermediates; C0 controls other
                        // than ESC, CAN and SUB execute inside a CSI and DEL
                        // is ignored there, without ending it.
                        while data
                            .get(j)
                            .is_some_and(|&b| (0x20..0x40).contains(&b) || executes_inside(b))
                        {
                            j += 1;
                        }
                        let Some(&fin) = data.get(j) else { return true };
                        // DA (c), DSR/CPR (n), DECRQM ($p), XTVERSION/kitty
                        // keyboard (q, u), window reports (t), DECREQTPARM (x).
                        if matches!(fin, b'c' | b'n' | b'p' | b'q' | b't' | b'u' | b'x') {
                            return true;
                        }
                        if fin == 0x1b {
                            // ESC cut the CSI and starts a new sequence:
                            // examine it, do not step over it.
                            i = j;
                            continue;
                        }
                        i = j;
                    }
                    _ => {}
                }
            }
            // C1 forms of CSI/OSC/DCS/APC/PM/SOS. UTF-8 continuation bytes
            // share this range, so non-ASCII text parses early; that is safe.
            0x90 | 0x98 | 0x9a | 0x9b | 0x9d..=0x9f => return true,
            _ => {}
        }
        i += 1;
    }
    false
}

/// Where an unfinished `ESC [ ...` or a lone ESC at the end of `data`
/// starts, or `data.len()`. Only the last 64 bytes are looked at; a longer
/// unfinished CSI is left in place and parsed at once instead.
pub(super) fn incomplete_tail_start(data: &[u8]) -> usize {
    let Some((head, tail)) = data.split_at_checked(data.len().saturating_sub(64)) else {
        return data.len();
    };
    let Some(at) = tail.iter().rposition(|&b| b == 0x1b) else {
        return data.len();
    };
    match tail.get(at + 1..) {
        Some([]) => head.len() + at,
        Some([b'[', params @ ..]) if params.iter().all(|b| (0x20..0x40).contains(b)) => {
            head.len() + at
        }
        _ => data.len(),
    }
}

/// C0 controls the parser executes inside an escape or CSI without leaving
/// it (all but CAN, SUB and ESC), and DEL, which it ignores there.
fn executes_inside(b: u8) -> bool {
    (b < 0x20 && !matches!(b, 0x1b | 0x18 | 0x1a)) || b == 0x7f
}
