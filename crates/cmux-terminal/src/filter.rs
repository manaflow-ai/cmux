//! Terminal escape sequence response filter.
//!
//! This module provides filtering for terminal escape sequences that are responses
//! to queries. These responses should not be displayed to the user and can cause
//! feedback loops when terminal applications query capabilities.

/// Stateful filter for terminal escape sequence responses.
///
/// This filter removes various terminal query responses from output before
/// forwarding to clients. It handles sequences that may be split across
/// multiple chunks by buffering incomplete escape sequences.
///
/// Filtered sequences:
/// - DA1 query: ESC [ c or ESC [ 0 c
/// - DA2 query: ESC [ > c or ESC [ > 0 c
/// - DA1 response: ESC [ ? params c
/// - DA2 response: ESC [ > params c
/// - DSR response: ESC [ 0 n (status OK)
/// - CPR response: ESC [ row ; col R (cursor position report)
/// - OSC responses: ESC ] N ; ... ST (color queries, etc.)
/// - DCS responses: ESC P ... ST (DECRQSS, DECRQCRA, etc.)
/// - DECRQM response: ESC [ ? Ps ; Pm $ y or ESC [ Ps ; Pm $ y
/// - Window size response: ESC [ 8 ; h ; w t
#[derive(Default)]
pub struct EscapeFilter {
    /// Buffer for incomplete escape sequences
    buffer: Vec<u8>,
    /// Current parsing state
    state: FilterState,
}

#[derive(Default, Clone, Copy, PartialEq)]
enum FilterState {
    #[default]
    Normal,
    /// Saw ESC (0x1b)
    Escape,
    /// Saw ESC [
    Csi,
    /// Saw ESC [ ? (DA1 response, DECRQM DEC mode)
    CsiQuestion,
    /// Saw ESC [ > (DA2 query/response)
    CsiGreater,
    /// In CSI with digits/semicolons (general params)
    CsiParams,
    /// Saw $ after CSI params (DECRQM response)
    CsiParamsDollar,
    /// Saw ESC ] (OSC sequence)
    Osc,
    /// In OSC content, waiting for ST (ESC \) or BEL
    OscContent,
    /// Saw ESC inside OSC (potential ST terminator)
    OscEscape,
    /// Saw ESC P (DCS sequence)
    Dcs,
    /// In DCS content, waiting for ST (ESC \)
    DcsContent,
    /// Saw ESC inside DCS (potential ST terminator)
    DcsEscape,
}

/// Check if the buffered CSI sequence should be filtered.
/// Returns true if the sequence is a response that should be removed.
fn should_filter_csi(buffer: &[u8], final_byte: u8) -> bool {
    // Buffer contains ESC [ ... (without final byte)
    // We need to check the intermediate chars and params

    if buffer.len() < 2 {
        return false;
    }

    // Skip ESC [
    let content = &buffer[2..];

    match final_byte {
        // DA1 query (ESC [ c) or (ESC [ 0 c)
        // DA1 response (ESC [ ? params c)
        // DA2 response (ESC [ > params c)
        b'c' => {
            // ESC [ c - DA1 query
            if content.is_empty() {
                return true;
            }
            // ESC [ 0 c - DA1 query with param
            if content == b"0" {
                return true;
            }
            // ESC [ ? ... c - DA1 response
            if content.first() == Some(&b'?') {
                return true;
            }
            // ESC [ > ... c - DA2 query/response
            if content.first() == Some(&b'>') {
                return true;
            }
            false
        }
        // DSR response: ESC [ 0 n
        b'n' => {
            // ESC [ 0 n - Device status OK response
            content == b"0"
        }
        // CPR response: ESC [ row ; col R
        b'R' => {
            // Any ESC [ digits ; digits R is a cursor position report
            let mut has_semicolon = false;
            let mut all_valid = true;
            for &b in content {
                if b == b';' {
                    has_semicolon = true;
                } else if !b.is_ascii_digit() {
                    all_valid = false;
                    break;
                }
            }
            all_valid && has_semicolon
        }
        // DECRQM response: ESC [ ? Ps ; Pm $ y or ESC [ Ps ; Pm $ y
        b'y' => {
            // Check if we have $ before y
            if content.ends_with(b"$") || content.contains(&b'$') {
                return true;
            }
            false
        }
        // Window size response: ESC [ 8 ; h ; w t
        b't' => {
            // ESC [ 8 ; ... t is a window size report
            content.first() == Some(&b'8') && content.get(1) == Some(&b';')
        }
        _ => false,
    }
}

impl EscapeFilter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Process a chunk of data, returning filtered output.
    /// Call this for each chunk of PTY output.
    pub fn filter(&mut self, data: &[u8]) -> Vec<u8> {
        let mut result = Vec::with_capacity(data.len());

        for &byte in data {
            match self.state {
                FilterState::Normal => {
                    if byte == 0x1b {
                        // Start of potential escape sequence
                        self.buffer.clear();
                        self.buffer.push(byte);
                        self.state = FilterState::Escape;
                    } else {
                        result.push(byte);
                    }
                }

                FilterState::Escape => {
                    self.buffer.push(byte);
                    match byte {
                        b'[' => self.state = FilterState::Csi,
                        b']' => self.state = FilterState::Osc,
                        b'P' => self.state = FilterState::Dcs,
                        _ => {
                            // Other escape sequence, pass through
                            result.extend(&self.buffer);
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                    }
                }

                FilterState::Csi => {
                    self.buffer.push(byte);
                    match byte {
                        b'?' => self.state = FilterState::CsiQuestion,
                        b'>' => self.state = FilterState::CsiGreater,
                        b'0'..=b'9' | b';' => self.state = FilterState::CsiParams,
                        b'c' => {
                            // DA1 query: ESC [ c - filter it out
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                        // Final byte - check if this is a known response
                        b'@'..=b'~' => {
                            // Unknown CSI sequence, pass through
                            result.extend(&self.buffer);
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                        _ => {
                            // Intermediate or unknown byte, pass through
                            result.extend(&self.buffer);
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                    }
                }

                FilterState::CsiQuestion => {
                    self.buffer.push(byte);
                    match byte {
                        b'0'..=b'9' | b';' => {
                            // Continue accumulating params
                        }
                        b'$' => {
                            // Potential DECRQM response
                            self.state = FilterState::CsiParamsDollar;
                        }
                        b'c' => {
                            // DA1 response: ESC [ ? params c - filter it out
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                        _ => {
                            // Not a filtered sequence (e.g., ESC[?25h for cursor)
                            result.extend(&self.buffer);
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                    }
                }

                FilterState::CsiGreater => {
                    self.buffer.push(byte);
                    match byte {
                        b'0'..=b'9' | b';' => {
                            // Continue accumulating params
                        }
                        b'c' => {
                            // DA2 query/response: ESC [ > c or ESC [ > params c - filter
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                        _ => {
                            // Not a DA2 sequence, pass through
                            result.extend(&self.buffer);
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                    }
                }

                FilterState::CsiParams => {
                    self.buffer.push(byte);
                    match byte {
                        b'0'..=b'9' | b';' => {
                            // Continue accumulating params
                        }
                        b'$' => {
                            // Potential DECRQM response
                            self.state = FilterState::CsiParamsDollar;
                        }
                        // Final bytes that might be filtered responses
                        b'c' | b'n' | b'R' | b't' => {
                            if should_filter_csi(&self.buffer[..self.buffer.len() - 1], byte) {
                                self.buffer.clear();
                            } else {
                                result.extend(&self.buffer);
                                self.buffer.clear();
                            }
                            self.state = FilterState::Normal;
                        }
                        // Other final bytes
                        b'@'..=b'~' => {
                            result.extend(&self.buffer);
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                        _ => {
                            // Intermediate byte (like >) or other
                            // Check for > which starts DA2
                            if byte == b'>' {
                                self.state = FilterState::CsiGreater;
                            } else if byte == b'?' {
                                self.state = FilterState::CsiQuestion;
                            } else {
                                result.extend(&self.buffer);
                                self.buffer.clear();
                                self.state = FilterState::Normal;
                            }
                        }
                    }
                }

                FilterState::CsiParamsDollar => {
                    self.buffer.push(byte);
                    match byte {
                        b'y' => {
                            // DECRQM response: ESC [ ... $ y - filter
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                        _ => {
                            // Not DECRQM, pass through
                            result.extend(&self.buffer);
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                    }
                }

                FilterState::Osc => {
                    self.buffer.push(byte);
                    // First byte after ESC ] determines OSC type
                    match byte {
                        // OSC 4, 5 (color palette), OSC 10, 11, 12 (fg/bg/cursor color)
                        // These are the ones that have query responses
                        b'0'..=b'9' => {
                            self.state = FilterState::OscContent;
                        }
                        0x07 => {
                            // BEL - empty OSC, pass through
                            result.extend(&self.buffer);
                            self.buffer.clear();
                            self.state = FilterState::Normal;
                        }
                        0x1b => {
                            // ESC - potential ST
                            self.state = FilterState::OscEscape;
                        }
                        _ => {
                            self.state = FilterState::OscContent;
                        }
                    }
                }

                FilterState::OscContent => {
                    self.buffer.push(byte);
                    match byte {
                        0x07 => {
                            // BEL terminates OSC - check if it's a response to filter
                            if self.is_osc_response() {
                                self.buffer.clear();
                            } else {
                                result.extend(&self.buffer);
                                self.buffer.clear();
                            }
                            self.state = FilterState::Normal;
                        }
                        0x1b => {
                            // ESC - potential ST (ESC \)
                            self.state = FilterState::OscEscape;
                        }
                        _ => {
                            // Continue accumulating OSC content
                        }
                    }
                }

                FilterState::OscEscape => {
                    self.buffer.push(byte);
                    if byte == b'\\' {
                        // ST (ESC \) terminates OSC - check if it's a response
                        if self.is_osc_response() {
                            self.buffer.clear();
                        } else {
                            result.extend(&self.buffer);
                            self.buffer.clear();
                        }
                        self.state = FilterState::Normal;
                    } else {
                        // Not ST, continue as OSC content
                        self.state = FilterState::OscContent;
                    }
                }

                FilterState::Dcs => {
                    self.buffer.push(byte);
                    // DCS content starts
                    self.state = FilterState::DcsContent;
                }

                FilterState::DcsContent => {
                    self.buffer.push(byte);
                    if byte == 0x1b {
                        // ESC - potential ST
                        self.state = FilterState::DcsEscape;
                    }
                    // Continue accumulating DCS content
                }

                FilterState::DcsEscape => {
                    self.buffer.push(byte);
                    if byte == b'\\' {
                        // ST (ESC \) terminates DCS - always filter DCS responses
                        // (DECRQSS, DECRQCRA responses)
                        self.buffer.clear();
                        self.state = FilterState::Normal;
                    } else {
                        // Not ST, continue as DCS content
                        self.state = FilterState::DcsContent;
                    }
                }
            }
        }

        result
    }

    /// Check if the current OSC sequence is a color query response that should be filtered.
    fn is_osc_response(&self) -> bool {
        // Buffer contains ESC ] content (BEL or ESC \)
        if self.buffer.len() < 3 {
            return false;
        }

        // Skip ESC ]
        let content = &self.buffer[2..];

        // OSC responses we want to filter are color query responses
        // They look like: OSC 4 ; N ; rgb:RRRR/GGGG/BBBB ST
        //            or: OSC 10 ; rgb:RRRR/GGGG/BBBB ST
        //            or: OSC 11 ; rgb:RRRR/GGGG/BBBB ST
        //            or: OSC 12 ; rgb:RRRR/GGGG/BBBB ST

        // Find the first ; to get the OSC number
        let semicolon_pos = content.iter().position(|&b| b == b';');
        if let Some(pos) = semicolon_pos {
            let osc_num = &content[..pos];
            let rest = &content[pos + 1..];

            // Check for color response pattern (contains "rgb:" or starts with color index + ";rgb:")
            let is_color_response = rest.windows(4).any(|w| w == b"rgb:");

            match osc_num {
                // OSC 4 - color palette query response
                b"4" if is_color_response => return true,
                // OSC 5 - special color query response
                b"5" if is_color_response => return true,
                // OSC 10 - foreground color query response
                b"10" if is_color_response => return true,
                // OSC 11 - background color query response
                b"11" if is_color_response => return true,
                // OSC 12 - cursor color query response
                b"12" if is_color_response => return true,
                _ => {}
            }
        }

        false
    }

    /// Flush any remaining buffered data.
    /// Call this when the stream ends to ensure no data is lost.
    pub fn flush(&mut self) -> Vec<u8> {
        let result = std::mem::take(&mut self.buffer);
        self.state = FilterState::Normal;
        result
    }
}

// Keep the old name as an alias for backwards compatibility
pub type DaFilter = EscapeFilter;

/// Stateless filter for escape sequences (for simple cases where sequences won't be split).
/// For streaming use cases, prefer `EscapeFilter` which handles split sequences.
pub fn filter_escape_responses(data: &[u8]) -> Vec<u8> {
    let mut filter = EscapeFilter::new();
    let mut result = filter.filter(data);
    result.extend(filter.flush());
    result
}

/// Backwards-compatible alias
pub fn filter_da_queries(data: &[u8]) -> Vec<u8> {
    filter_escape_responses(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    // DA1/DA2 tests (existing)

    #[test]
    fn test_filter_da1_query() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b[c");
        assert!(result.is_empty(), "DA1 query should be filtered");
    }

    #[test]
    fn test_filter_da1_query_with_param() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b[0c");
        assert!(
            result.is_empty(),
            "DA1 query with 0 param should be filtered"
        );
    }

    #[test]
    fn test_filter_da2_query() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b[>c");
        assert!(result.is_empty(), "DA2 query should be filtered");
    }

    #[test]
    fn test_filter_da1_response() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b[?64;1;2;6;9;15;18;21;22c");
        assert!(result.is_empty(), "DA1 response should be filtered");
    }

    #[test]
    fn test_filter_da2_response() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b[>1;123;0c");
        assert!(result.is_empty(), "DA2 response should be filtered");
    }

    #[test]
    fn test_preserve_cursor_visibility() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b[?25h");
        assert_eq!(
            result, b"\x1b[?25h",
            "Cursor visibility should be preserved"
        );
    }

    #[test]
    fn test_preserve_normal_text() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"Hello, World!");
        assert_eq!(result, b"Hello, World!", "Normal text should be preserved");
    }

    #[test]
    fn test_mixed_content() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"Before\x1b[cAfter");
        assert_eq!(
            result, b"BeforeAfter",
            "Content around DA query should be preserved"
        );
    }

    #[test]
    fn test_split_sequence() {
        let mut filter = EscapeFilter::new();

        // First chunk ends mid-sequence
        let r1 = filter.filter(b"Hello\x1b[");
        assert_eq!(r1, b"Hello");

        // Second chunk completes the DA query
        let r2 = filter.filter(b"c more text");
        assert_eq!(r2, b" more text");
    }

    #[test]
    fn test_flush_incomplete() {
        let mut filter = EscapeFilter::new();
        let _ = filter.filter(b"\x1b[");
        let flushed = filter.flush();
        assert_eq!(flushed, b"\x1b[", "Incomplete sequence should be flushed");
    }

    #[test]
    fn test_stateless_helper() {
        let result = filter_da_queries(b"Before\x1b[cAfter");
        assert_eq!(result, b"BeforeAfter");
    }

    // DSR tests

    #[test]
    fn test_filter_dsr_ok_response() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b[0n");
        assert!(result.is_empty(), "DSR OK response should be filtered");
    }

    #[test]
    fn test_filter_cursor_position_report() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b[24;80R");
        assert!(
            result.is_empty(),
            "Cursor position report should be filtered"
        );
    }

    #[test]
    fn test_filter_cursor_position_report_single_digit() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b[1;1R");
        assert!(
            result.is_empty(),
            "Cursor position report should be filtered"
        );
    }

    // OSC tests

    #[test]
    fn test_filter_osc_10_response_st() {
        let mut filter = EscapeFilter::new();
        // OSC 10 ; rgb:ffff/ffff/ffff ST
        let result = filter.filter(b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\");
        assert!(result.is_empty(), "OSC 10 response should be filtered");
    }

    #[test]
    fn test_filter_osc_10_response_bel() {
        let mut filter = EscapeFilter::new();
        // OSC 10 ; rgb:ffff/ffff/ffff BEL
        let result = filter.filter(b"\x1b]10;rgb:ffff/ffff/ffff\x07");
        assert!(
            result.is_empty(),
            "OSC 10 response with BEL should be filtered"
        );
    }

    #[test]
    fn test_filter_osc_11_response() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b]11;rgb:0000/0000/0000\x1b\\");
        assert!(result.is_empty(), "OSC 11 response should be filtered");
    }

    #[test]
    fn test_filter_osc_12_response() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b]12;rgb:ffff/ffff/ffff\x1b\\");
        assert!(result.is_empty(), "OSC 12 response should be filtered");
    }

    #[test]
    fn test_filter_osc_4_response() {
        let mut filter = EscapeFilter::new();
        // OSC 4 ; index ; rgb:... ST
        let result = filter.filter(b"\x1b]4;15;rgb:ffff/ffff/ffff\x1b\\");
        assert!(result.is_empty(), "OSC 4 response should be filtered");
    }

    #[test]
    fn test_preserve_osc_title() {
        let mut filter = EscapeFilter::new();
        // OSC 0 ; title ST - window title, should be preserved
        let result = filter.filter(b"\x1b]0;My Terminal\x1b\\");
        assert_eq!(
            result, b"\x1b]0;My Terminal\x1b\\",
            "OSC 0 title should be preserved"
        );
    }

    #[test]
    fn test_preserve_osc_2_title() {
        let mut filter = EscapeFilter::new();
        // OSC 2 ; title ST - window title
        let result = filter.filter(b"\x1b]2;Window Title\x07");
        assert_eq!(
            result, b"\x1b]2;Window Title\x07",
            "OSC 2 title should be preserved"
        );
    }

    // DCS tests

    #[test]
    fn test_filter_dcs_decrqss_response() {
        let mut filter = EscapeFilter::new();
        // DCS 1 $ r ... ST (DECRQSS response)
        let result = filter.filter(b"\x1bP1$r0m\x1b\\");
        assert!(result.is_empty(), "DECRQSS response should be filtered");
    }

    #[test]
    fn test_filter_dcs_decrqcra_response() {
        let mut filter = EscapeFilter::new();
        // DCS Pid ! ~ XXXX ST (DECRQCRA response)
        let result = filter.filter(b"\x1bP1!~A5B2\x1b\\");
        assert!(result.is_empty(), "DECRQCRA response should be filtered");
    }

    // DECRQM tests

    #[test]
    fn test_filter_decrqm_dec_mode_response() {
        let mut filter = EscapeFilter::new();
        // CSI ? 25 ; 1 $ y (cursor visible mode is set)
        let result = filter.filter(b"\x1b[?25;1$y");
        assert!(
            result.is_empty(),
            "DECRQM DEC mode response should be filtered"
        );
    }

    #[test]
    fn test_filter_decrqm_ansi_mode_response() {
        let mut filter = EscapeFilter::new();
        // CSI 4 ; 1 $ y (insert mode is set)
        let result = filter.filter(b"\x1b[4;1$y");
        assert!(
            result.is_empty(),
            "DECRQM ANSI mode response should be filtered"
        );
    }

    // Window size tests

    #[test]
    fn test_filter_window_size_response() {
        let mut filter = EscapeFilter::new();
        // CSI 8 ; rows ; cols t
        let result = filter.filter(b"\x1b[8;24;80t");
        assert!(result.is_empty(), "Window size response should be filtered");
    }

    #[test]
    fn test_preserve_other_window_ops() {
        let mut filter = EscapeFilter::new();
        // CSI 22 ; 0 t - push title (not a response)
        let result = filter.filter(b"\x1b[22;0t");
        assert_eq!(
            result, b"\x1b[22;0t",
            "Window title push should be preserved"
        );
    }

    // Split sequence tests

    #[test]
    fn test_split_osc_response() {
        let mut filter = EscapeFilter::new();

        let r1 = filter.filter(b"text\x1b]10;rgb:");
        assert_eq!(r1, b"text");

        let r2 = filter.filter(b"ffff/ffff/ffff\x1b\\more");
        assert_eq!(r2, b"more");
    }

    #[test]
    fn test_split_dcs_response() {
        let mut filter = EscapeFilter::new();

        let r1 = filter.filter(b"start\x1bP1$r");
        assert_eq!(r1, b"start");

        let r2 = filter.filter(b"0m\x1b\\end");
        assert_eq!(r2, b"end");
    }

    #[test]
    fn test_split_cpr_response() {
        let mut filter = EscapeFilter::new();

        let r1 = filter.filter(b"before\x1b[24;");
        assert_eq!(r1, b"before");

        let r2 = filter.filter(b"80Rafter");
        assert_eq!(r2, b"after");
    }

    // Edge cases

    #[test]
    fn test_preserve_sgr_sequences() {
        let mut filter = EscapeFilter::new();
        // SGR (colors/styles) should be preserved
        let result = filter.filter(b"\x1b[1;31mRed Bold\x1b[0m");
        assert_eq!(
            result, b"\x1b[1;31mRed Bold\x1b[0m",
            "SGR should be preserved"
        );
    }

    #[test]
    fn test_preserve_cursor_movement() {
        let mut filter = EscapeFilter::new();
        // Cursor movement should be preserved
        let result = filter.filter(b"\x1b[10;20H");
        assert_eq!(
            result, b"\x1b[10;20H",
            "Cursor movement should be preserved"
        );
    }

    #[test]
    fn test_preserve_erase_sequences() {
        let mut filter = EscapeFilter::new();
        let result = filter.filter(b"\x1b[2J\x1b[K");
        assert_eq!(
            result, b"\x1b[2J\x1b[K",
            "Erase sequences should be preserved"
        );
    }

    #[test]
    fn test_multiple_responses_in_sequence() {
        let mut filter = EscapeFilter::new();
        // Multiple responses mixed with normal output
        let result = filter.filter(b"start\x1b[c\x1b[?64;1c\x1b[>41;354;0cmiddle\x1b[0nend");
        assert_eq!(
            result, b"startmiddleend",
            "Multiple responses should be filtered"
        );
    }
}
