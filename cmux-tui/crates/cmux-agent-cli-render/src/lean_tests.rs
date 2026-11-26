use super::*;
use crate::BOLD;

fn cells(text: &str, style: Style) -> Vec<Cell> {
    text.chars().map(|c| Cell { text: c.to_string(), style }).collect()
}

fn frame(frame: u64, base: Option<u64>, spans: Vec<Span>) -> Frame {
    Frame { frame, base, data: Delta { seq: 0, at_ms: 7, shift: 0, spans }.encode() }
}

/// The v1 frame a lean one carries (the delta's time is not sent).
fn v1(frame: &Frame) -> Frame {
    let mut delta = Delta::decode(&frame.data).unwrap();
    delta.at_ms = 0;
    Frame { data: delta.encode(), ..frame.clone() }
}

#[test]
fn frames_read_back_as_sent_and_later_ones_are_smaller() {
    let style = Style::fg(174).with(BOLD);
    let key = frame(
        1,
        None,
        vec![
            Span::Set {
                row: 0, col: 2, cells: cells("hello ────────── 界", style)
            },
            Span::Clear { row: 1, col: 0, len: 3 },
        ],
    );
    let next = frame(2, Some(1), vec![Span::Set { row: 0, col: 2, cells: cells("hallo", style) }]);
    let cursor = Cursor { x: 1, y: 3, visible: true };
    let mut encoder = LeanEncoder::new();
    let mut decoder = LeanDecoder::new();
    let a = encoder.encode("s1", 20, 4, &key, cursor).unwrap();
    let b = encoder.encode("s1", 20, 4, &next, cursor).unwrap();
    let da = decoder.decode(&a).unwrap();
    assert_eq!((da.stream.as_str(), da.cols, da.rows, da.cursor), ("s1", 20, 4, cursor));
    assert_eq!(da.frame, v1(&key));
    let db = decoder.decode(&b).unwrap();
    assert_eq!(db.frame, v1(&next));
    // No header, no number, no cursor, the style by index: flags, shift, count, row, col,
    // length, style, 5 cells.
    assert_eq!(b.len(), 1 + 1 + 1 + 1 + 1 + 1 + 1 + 5, "{b:?}");
    assert!(
        a.len() < key.data.len(),
        "the run of ─ is one cell: {} vs {}",
        a.len(),
        key.data.len()
    );
}

#[test]
fn a_resume_names_its_numbers_and_a_new_connection_starts_over() {
    let style = Style::fg(2);
    let resumed = frame(9, Some(5), vec![Span::Set { row: 1, col: 0, cells: cells("ok", style) }]);
    let mut encoder = LeanEncoder::new();
    let bytes = encoder.encode("s1", 20, 4, &resumed, Cursor::default()).unwrap();
    let mut decoder = LeanDecoder::new();
    let decoded = decoder.decode(&bytes).unwrap();
    assert_eq!((decoded.frame.frame, decoded.frame.base), (9, Some(5)));
    // A decoder that never saw a head cannot read a frame without one.
    let next = encoder.encode("s1", 20, 4, &frame(10, Some(9), vec![]), Cursor::default()).unwrap();
    assert!(LeanDecoder::new().decode(&next).is_none());
    assert_eq!(decoder.decode(&next).unwrap().frame.frame, 10);
    // Garbage leaves the decoder as it was.
    assert!(decoder.decode(&[0xff]).is_none());
    let after =
        encoder.encode("s1", 20, 4, &frame(11, Some(10), vec![]), Cursor::default()).unwrap();
    assert_eq!(decoder.decode(&after).unwrap().frame.frame, 11);
}

/// A varint past 64 bits reads as nothing, not as the smaller value its low bits make
/// (#44052 F2).
#[test]
fn a_varint_past_64_bits_reads_as_nothing() {
    let read = |bytes: &[u8]| Reader { bytes, pos: 0 }.varint();
    assert_eq!(read(&[[0xff; 9].as_slice(), &[0x01]].concat()), Some(u64::MAX));
    assert_eq!(read(&[[0x80; 9].as_slice(), &[0x02]].concat()), None, "bit 64");
    assert_eq!(read(&[[0x80; 10].as_slice(), &[0x00]].concat()), None, "an eleventh byte");
}
