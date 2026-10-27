use std::io::Write;

use serde_json::json;

use super::*;

fn file_with(bytes: &[u8]) -> tempfile::NamedTempFile {
    let mut file = tempfile::NamedTempFile::new().unwrap();
    file.write_all(bytes).unwrap();
    file
}

#[test]
fn trim_padding_drops_only_leading_nuls() {
    assert_eq!(trim_padding(b"\0\0{}\0"), b"{}\0");
    assert_eq!(trim_padding(b"\0\0"), b"");
    assert_eq!(trim_padding(b""), b"");
}

#[test]
fn parse_lines_drops_partial_lines_at_the_cuts() {
    let bytes = b"{\"a\":1}\n{\"b\":2}\n{\"c\":3}";
    assert_eq!(parse_lines(bytes, false, false), [json!({"a":1}), json!({"b":2}), json!({"c":3})]);
    assert_eq!(parse_lines(bytes, true, false), [json!({"b":2}), json!({"c":3})]);
    assert_eq!(parse_lines(bytes, false, true), [json!({"a":1}), json!({"b":2})]);
    assert_eq!(parse_lines(bytes, true, true), [json!({"b":2})]);
    // No newline: a window cut on both sides holds no complete line.
    assert!(parse_lines(b"{\"a\":1}", true, false).is_empty());
    assert!(parse_lines(b"{\"a\":1}", false, true).is_empty());
    assert!(parse_lines(b"", true, true).is_empty());
}

#[test]
fn fold_lines_returns_the_offset_after_the_last_complete_line() {
    let file = file_with(b"one\n\0\0two\nthree");
    let mut seen = Vec::new();
    let offset = fold_lines(file.path(), 0, |line| seen.push(line.to_vec())).unwrap();
    assert_eq!(seen, [b"one".to_vec(), b"two".to_vec()]);
    assert_eq!(offset, 10);
    let mut rest = Vec::new();
    assert_eq!(fold_lines(file.path(), offset, |line| rest.push(line.to_vec())).unwrap(), 10);
    assert!(rest.is_empty());
}

#[test]
fn read_array_head_reads_items_until_the_limit_or_a_cut() {
    let file = file_with(b"\0 [ {\"a\":1} , 2,\n\"three\" , [4]]");
    assert_eq!(
        read_array_head(file.path(), 1024, 10).unwrap(),
        [json!({"a":1}), json!(2), json!("three"), json!([4])]
    );
    assert_eq!(read_array_head(file.path(), 1024, 2).unwrap(), [json!({"a":1}), json!(2)]);
    // A byte cap inside the third item keeps the complete ones.
    assert_eq!(read_array_head(file.path(), 18, 10).unwrap(), [json!({"a":1}), json!(2)]);
    for not_an_array in [&b""[..], b"   ", b"{}", b"[", b"[,]"] {
        let file = file_with(not_an_array);
        assert!(read_array_head(file.path(), 1024, 10).unwrap().is_empty());
    }
}
