//! The app line reader's C ABI against cmux-rd-proto's golden vectors
//! (tests/vectors/app_lines.json): the bytes `cmux rd serve|connect` print
//! come out as the typed lines the host meant.

use super::*;

const VECTORS: &str = include_str!("../../cmux-rd-proto/tests/vectors/app_lines.json");

struct Reader(*mut CmuxRdLineReader);

impl Reader {
    fn new() -> Self {
        let reader = cmux_rd_line_reader_new();
        assert!(!reader.is_null());
        Self(reader)
    }

    fn push(&self, bytes: &[u8]) -> i32 {
        // SAFETY: live reader, readable bytes.
        unsafe { cmux_rd_line_reader_push(self.0, bytes.as_ptr(), bytes.len()) }
    }

    /// The next line as JSON in the vectors' `want` shape, or None.
    fn next(&self) -> Option<serde_json::Value> {
        let mut line = CmuxRdLine::default();
        // SAFETY: live reader, writable line.
        let rc = unsafe { cmux_rd_line_reader_next(self.0, &mut line) };
        assert!(rc == 0 || rc == 1, "rc {rc}");
        (rc == 1).then(|| json_of(&line))
    }
}

impl Drop for Reader {
    fn drop(&mut self) {
        // SAFETY: the reader came from cmux_rd_line_reader_new and is freed once.
        unsafe { cmux_rd_line_reader_free(self.0) };
    }
}

fn text(ptr: *const u8, len: usize) -> serde_json::Value {
    // SAFETY: the reader's bytes, valid until the next call on it.
    let bytes = unsafe { bytes_in(ptr, len) }.expect("text");
    serde_json::Value::String(String::from_utf8(bytes.to_vec()).expect("utf-8"))
}

/// A `CmuxRdLine` in the vectors' `want` JSON shape (what a C caller sees).
fn json_of(line: &CmuxRdLine) -> serde_json::Value {
    let has = |bit: u32| line.fields & bit != 0;
    let mut out = serde_json::Map::new();
    if has(CMUX_RD_LINE_KEY) {
        out.insert("key".into(), text(line.key, line.key_len));
    }
    if has(CMUX_RD_LINE_CANDIDATE) {
        out.insert("candidate".into(), text(line.candidate, line.candidate_len));
    }
    for (bit, name) in [
        (CMUX_RD_LINE_CANDIDATES_DONE, "candidates_done"),
        (CMUX_RD_LINE_CONNECTED, "connected"),
        (CMUX_RD_LINE_LISTENING, "listening"),
    ] {
        if has(bit) {
            out.insert(name.into(), true.into());
        }
    }
    if has(CMUX_RD_LINE_ENDED) {
        out.insert("ended".into(), text(line.ended, line.ended_len));
    }
    if has(CMUX_RD_LINE_PATH) {
        let kind = if has(CMUX_RD_LINE_PATH_KIND) {
            text(line.path_kind, line.path_kind_len)
        } else {
            serde_json::Value::Null
        };
        let rtt = if has(CMUX_RD_LINE_PATH_RTT) {
            serde_json::json!(line.path_rtt_ms)
        } else {
            serde_json::Value::Null
        };
        out.insert("path".into(), serde_json::json!({"kind": kind, "rtt_ms": rtt}));
    }
    if has(CMUX_RD_LINE_DISPLAYS) {
        // SAFETY: display_count pairs at `displays`, valid until the next call.
        let flat = if line.display_count == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(line.displays, line.display_count * 2) }
        };
        let pairs: Vec<serde_json::Value> =
            flat.chunks(2).map(|pair| serde_json::json!([pair[0], pair[1]])).collect();
        out.insert("displays".into(), pairs.into());
    }
    if has(CMUX_RD_LINE_CURRENT) {
        out.insert("current".into(), line.current.into());
    }
    if has(CMUX_RD_LINE_ERROR) {
        out.insert("error".into(), text(line.error, line.error_len));
    }
    out.into()
}

fn vectors() -> Vec<serde_json::Value> {
    serde_json::from_str(VECTORS).expect("vectors")
}

#[test]
fn every_vector_line_comes_out_as_its_want_or_not_at_all() {
    for v in vectors() {
        let name = v["name"].as_str().expect("name");
        let reader = Reader::new();
        let ready = reader.push(format!("{}\n", v["line"].as_str().expect("line")).as_bytes());
        let want = &v["want"];
        assert_eq!(ready, i32::from(!want.is_null()), "{name}");
        assert_eq!(reader.next().unwrap_or(serde_json::Value::Null), *want, "{name}");
        assert_eq!(reader.next(), None, "{name}");
    }
}

#[test]
fn all_vectors_pushed_byte_by_byte_come_out_in_order() {
    let reader = Reader::new();
    let mut all = Vec::new();
    for v in vectors() {
        all.extend_from_slice(v["line"].as_str().expect("line").as_bytes());
        all.push(b'\n');
    }
    for byte in &all {
        assert!(reader.push(std::slice::from_ref(byte)) >= 0);
    }
    for v in vectors().iter().filter(|v| !v["want"].is_null()) {
        assert_eq!(reader.next().as_ref(), Some(&v["want"]), "{}", v["name"]);
    }
    assert_eq!(reader.next(), None);
}

#[test]
fn a_line_without_its_newline_waits() {
    let reader = Reader::new();
    assert_eq!(reader.push(br#"{"connected":tr"#), 0);
    assert_eq!(reader.next(), None);
    assert_eq!(reader.push(b"ue}\n"), 1);
    assert_eq!(reader.next(), Some(serde_json::json!({"connected": true})));
}

#[test]
fn null_arguments_and_a_null_reader_are_refused() {
    let mut line = CmuxRdLine::default();
    // SAFETY: NULL reader with a valid out pointer.
    assert_eq!(
        unsafe { cmux_rd_line_reader_next(std::ptr::null_mut(), &mut line) },
        CMUX_RD_ERR_NULL
    );
    let reader = Reader::new();
    // SAFETY: live reader, NULL out.
    assert_eq!(
        unsafe { cmux_rd_line_reader_next(reader.0, std::ptr::null_mut()) },
        CMUX_RD_ERR_NULL
    );
    // SAFETY: live reader, NULL bytes with a length.
    assert_eq!(
        unsafe { cmux_rd_line_reader_push(reader.0, std::ptr::null(), 4) },
        CMUX_RD_ERR_NULL
    );
    // SAFETY: NULL is ignored.
    unsafe { cmux_rd_line_reader_free(std::ptr::null_mut()) };
}

#[test]
fn a_panic_poisons_only_that_reader() {
    let reader = Reader::new();
    let other = Reader::new();
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let rc = with_reader(reader.0, |_| panic!("boom"));
    std::panic::set_hook(hook);
    assert_eq!(rc, CMUX_RD_ERR_PANIC);
    assert_eq!(reader.push(b"{}\n"), CMUX_RD_ERR_PANIC);
    assert_eq!(other.push(b"{}\n"), 1);
}
