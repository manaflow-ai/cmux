//! The JSON lines `cmux rd serve` and `cmux rd connect` print on stdout for
//! the app that runs them (plans/cmux-next/remote-desktop-mac-host.md
//! section 7). One definition: the host prints [`AppLine`]s and the app reads
//! them back through cmux-rd-ffi's line reader (`CmuxRdLineReader`), so the
//! two sides cannot drift. Golden vectors: tests/vectors/app_lines.json.
//!
//! One line says one or more of: this side's session key, a link candidate,
//! "every candidate is known", "the viewer socket listens", "the link is up",
//! the path in use, the displays (and the current one), and last why the
//! session ended. A line with none of them (a newer cmux's line this build
//! does not know) reads as an empty [`AppLine`].

use serde::{Deserialize, Serialize};

/// The link's path now: `{"path":{"kind":"direct_wan","rtt_ms":3.2}}`.
/// Both fields are printed, `null` when unknown.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct LinePath {
    /// The path kind's wire name (`direct_lan`, `direct_wan`, ...).
    pub kind: Option<String>,
    /// The round trip in milliseconds.
    pub rtt_ms: Option<f64>,
}

/// One stdout line of `cmux rd serve` or `cmux rd connect`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct AppLine {
    /// This side's session key (64 hex characters); the app signs it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// One link candidate in its wire text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidate: Option<String>,
    /// Every candidate this side will find is known.
    #[serde(default, skip_serializing_if = "is_false")]
    pub candidates_done: bool,
    /// The secure link is up.
    #[serde(default, skip_serializing_if = "is_false")]
    pub connected: bool,
    /// `connect` only: the pane's socket listens.
    #[serde(default, skip_serializing_if = "is_false")]
    pub listening: bool,
    /// Last line: why the session ended.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended: Option<String>,
    /// The path in use changed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<LinePath>,
    /// `serve` only, first: each display's size in pixels, `[width, height]`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub displays: Option<Vec<(u32, u32)>>,
    /// The index in `displays` of the display the session shows first.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current: Option<usize>,
    /// Why the displays could not be read (with an empty `displays`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

// serde's `skip_serializing_if` passes a reference.
fn is_false(value: &bool) -> bool {
    !*value
}

impl AppLine {
    /// The line's JSON text, without the newline.
    pub fn to_json(&self) -> String {
        // Strings, numbers and lists only: serializing cannot fail.
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_owned())
    }

    /// Reads one line (its bytes without the newline). `None` when it is not a
    /// JSON object of this shape (a field of another type, or not JSON); a
    /// line whose fields are all unknown reads as an empty line.
    pub fn decode(line: &[u8]) -> Option<Self> {
        serde_json::from_slice(line).ok()
    }
}

/// Splits stdout bytes into lines: bytes in, each complete line out (without
/// its `\n`). A line that has not ended stays until its newline arrives.
#[derive(Debug, Default)]
pub struct LineSplitter {
    pending: Vec<u8>,
}

impl LineSplitter {
    /// Adds `bytes` and returns every line they complete, in order.
    pub fn push(&mut self, bytes: &[u8]) -> Vec<Vec<u8>> {
        self.pending.extend_from_slice(bytes);
        let mut lines = Vec::new();
        let mut start = 0;
        while let Some(offset) =
            self.pending.get(start..).and_then(|rest| rest.iter().position(|b| *b == b'\n'))
        {
            let end = start + offset;
            lines.push(self.pending.get(start..end).map(<[u8]>::to_vec).unwrap_or_default());
            start = end + 1;
        }
        self.pending.drain(..start);
        lines
    }

    /// Bytes of a line that has not ended yet.
    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_split_across_two_chunks_comes_out_once_whole() {
        let mut splitter = LineSplitter::default();
        assert!(splitter.push(b"{\"key\":\"ab").is_empty());
        assert_eq!(splitter.pending_len(), 10);
        let lines = splitter.push(b"cd\"}\n{\"connected\":true}\n{\"lis");
        assert_eq!(lines, vec![b"{\"key\":\"abcd\"}".to_vec(), b"{\"connected\":true}".to_vec()]);
        assert_eq!(splitter.pending_len(), 5);
        assert_eq!(splitter.push(b"tening\":true}\n"), vec![b"{\"listening\":true}".to_vec()]);
        assert_eq!(splitter.pending_len(), 0);
    }

    #[test]
    fn an_empty_line_is_a_line() {
        let mut splitter = LineSplitter::default();
        assert_eq!(splitter.push(b"\n\n"), vec![Vec::<u8>::new(), Vec::new()]);
    }

    #[test]
    fn what_the_host_prints_reads_back_the_same() {
        let lines = [
            AppLine { key: Some("ab".repeat(32)), ..AppLine::default() },
            AppLine { candidate: Some("host 192.168.1.4:51000".into()), ..AppLine::default() },
            AppLine { candidates_done: true, ..AppLine::default() },
            AppLine { connected: true, ..AppLine::default() },
            AppLine { listening: true, ..AppLine::default() },
            AppLine {
                path: Some(LinePath { kind: Some("direct_wan".into()), rtt_ms: Some(3.2) }),
                ..AppLine::default()
            },
            AppLine { path: Some(LinePath::default()), ..AppLine::default() },
            AppLine {
                displays: Some(vec![(3024, 1964), (2560, 1440)]),
                current: Some(1),
                ..AppLine::default()
            },
            AppLine {
                displays: Some(Vec::new()),
                current: Some(0),
                error: Some("no screen".into()),
                ..AppLine::default()
            },
            AppLine { ended: Some("the viewer left".into()), ..AppLine::default() },
        ];
        for line in lines {
            assert_eq!(
                AppLine::decode(line.to_json().as_bytes()),
                Some(line.clone()),
                "{}",
                line.to_json()
            );
        }
    }

    #[test]
    fn a_path_prints_null_for_what_it_does_not_know() {
        let line = AppLine { path: Some(LinePath::default()), ..AppLine::default() };
        assert_eq!(line.to_json(), r#"{"path":{"kind":null,"rtt_ms":null}}"#);
    }

    #[test]
    fn unknown_fields_read_as_an_empty_line_and_other_text_reads_as_none() {
        assert_eq!(AppLine::decode(br#"{"newer":1}"#), Some(AppLine::default()));
        assert_eq!(AppLine::decode(b"not json"), None);
        assert_eq!(AppLine::decode(b"[1,2]"), None);
        assert_eq!(AppLine::decode(br#"{"connected":"yes"}"#), None);
    }
}
