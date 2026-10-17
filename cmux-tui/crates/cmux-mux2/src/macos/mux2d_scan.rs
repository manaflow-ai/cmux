//! Query detection for the unwatched batch path.

/// True when `data` holds a sequence the program waits on for a reply.
/// Conservative: a false positive only costs an early parse.
pub(super) fn needs_immediate_parse(data: &[u8]) -> bool {
    let mut i = 0;
    while i < data.len() {
        match data[i] {
            0x05 => return true, // ENQ answerback
            0x1b => {
                let Some(&next) = data.get(i + 1) else { return true };
                match next {
                    // OSC, DCS, APC, PM, SOS: color/title queries, XTGETTCAP,
                    // DECRQSS, kitty graphics queries. DECID (ESC Z) is DA1.
                    b']' | b'P' | b'_' | b'^' | b'X' | b'Z' => return true,
                    b'[' => {
                        let mut j = i + 2;
                        // Parameters and intermediates; C0 controls other
                        // than ESC, CAN and SUB execute inside a CSI without
                        // ending it.
                        while j < data.len()
                            && ((0x20..0x40).contains(&data[j])
                                || (data[j] < 0x20 && !matches!(data[j], 0x1b | 0x18 | 0x1a)))
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
