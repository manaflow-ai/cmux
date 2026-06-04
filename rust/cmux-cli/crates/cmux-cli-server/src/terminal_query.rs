use crate::render::TerminalProbeKind;

#[derive(Debug, Default)]
pub(crate) struct TerminalQueryScanner {
    tail: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TerminalProbe {
    pub(crate) kind: TerminalProbeKind,
    pub(crate) current_end: usize,
}

impl TerminalQueryScanner {
    pub(crate) fn ingest(&mut self, data: &[u8]) -> Vec<TerminalProbe> {
        let previous_len = self.tail.len();
        let mut combined = Vec::with_capacity(previous_len + data.len());
        combined.extend_from_slice(&self.tail);
        combined.extend_from_slice(data);

        let responses = terminal_query_responses_after(&combined, previous_len);
        let tail_start = combined.len().saturating_sub(16);
        self.tail = combined[tail_start..].to_vec();
        responses
    }
}

pub(crate) fn terminal_query_responses_after(
    data: &[u8],
    previous_len: usize,
) -> Vec<TerminalProbe> {
    let mut probes = Vec::new();
    for current_end in osc_color_query_ends_after(data, 10, previous_len) {
        probes.push(TerminalProbe {
            kind: TerminalProbeKind::DefaultForegroundColor,
            current_end,
        });
    }
    for current_end in osc_color_query_ends_after(data, 11, previous_len) {
        probes.push(TerminalProbe {
            kind: TerminalProbeKind::DefaultBackgroundColor,
            current_end,
        });
    }
    probes.sort_by_key(|probe| probe.current_end);
    probes
}

fn osc_color_query_ends_after(data: &[u8], slot: u8, previous_len: usize) -> Vec<usize> {
    let Some((st_query, bel_query)) = osc_color_query_needles(slot) else {
        return Vec::new();
    };
    let mut ends = bytes_ending_after(data, st_query, previous_len);
    ends.extend(bytes_ending_after(data, bel_query, previous_len));
    ends.sort_unstable();
    ends
}

fn osc_color_query_needles(slot: u8) -> Option<(&'static [u8], &'static [u8])> {
    match slot {
        10 => Some((b"\x1b]10;?\x1b\\", b"\x1b]10;?\x07")),
        11 => Some((b"\x1b]11;?\x1b\\", b"\x1b]11;?\x07")),
        _ => None,
    }
}

fn bytes_ending_after(data: &[u8], needle: &[u8], previous_len: usize) -> Vec<usize> {
    if needle.is_empty() {
        return Vec::new();
    }
    data.windows(needle.len())
        .enumerate()
        .filter_map(|(index, window)| {
            let end = index + needle.len();
            (window == needle && end > previous_len).then_some(end.saturating_sub(previous_len))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn response_kinds(data: &[u8]) -> Vec<TerminalProbeKind> {
        terminal_query_responses_after(data, 0)
            .into_iter()
            .map(|probe| probe.kind)
            .collect()
    }

    #[test]
    fn terminal_query_scanner_leaves_csi_queries_to_libghostty_effects() {
        assert!(response_kinds(b"\x1b[6n").is_empty());
        assert!(response_kinds(b"\x1b[?u\x1b[c").is_empty());
    }

    #[test]
    fn terminal_query_responses_answer_default_colors() {
        assert_eq!(
            response_kinds(b"\x1b]10;?\x1b\\\x1b]11;?\x07"),
            vec![
                TerminalProbeKind::DefaultForegroundColor,
                TerminalProbeKind::DefaultBackgroundColor
            ]
        );
    }

    #[test]
    fn terminal_query_responses_ignore_normal_output() {
        assert!(terminal_query_responses_after(b"hello \x1b[38;5;135mworld", 0).is_empty());
    }

    #[test]
    fn terminal_query_scanner_handles_split_sequences() {
        let mut scanner = TerminalQueryScanner::default();
        assert!(scanner.ingest(b"\x1b]10;?").is_empty());
        assert_eq!(
            scanner.ingest(b"\x1b\\"),
            vec![TerminalProbe {
                kind: TerminalProbeKind::DefaultForegroundColor,
                current_end: 2,
            }]
        );
        assert!(scanner.ingest(b"plain output").is_empty());
    }

    #[test]
    fn terminal_query_scanner_reports_ordered_current_chunk_offsets() {
        let probes = terminal_query_responses_after(b"a\x1b]11;?\x07b\x1b]10;?\x1b\\c", 0);
        assert_eq!(
            probes,
            vec![
                TerminalProbe {
                    kind: TerminalProbeKind::DefaultBackgroundColor,
                    current_end: 8,
                },
                TerminalProbe {
                    kind: TerminalProbeKind::DefaultForegroundColor,
                    current_end: 17,
                },
            ]
        );
    }
}
