//! Regression tests for p10-stability-138 (panic deny in chatmux-relay): each
//! input that reached an index, slice, unwrap or expect now yields the same
//! result as before, or a refusal, never a panic.

use std::collections::HashMap;

use serde_json::json;

use crate::relay_wire as wire;

#[test]
fn group_code_never_splits_inside_a_character() {
    assert_eq!(crate::pairing::group_code("abcdef"), "abc def");
    assert_eq!(crate::pairing::group_code("abcde"), "abcde");
    // Byte 3 is inside the second `é`: the old `&code[..3]` panicked.
    assert_eq!(crate::pairing::group_code("ééé"), "ééé");
}

#[test]
fn shorten_cwd_keeps_the_last_two_parts() {
    use crate::pty::shorten_cwd;
    assert_eq!(shorten_cwd("", "/home/me"), "");
    assert_eq!(shorten_cwd("/home/me/src/app", "/home/me"), "~/src/app");
    assert_eq!(shorten_cwd("/srv/a/b/c", "/home/me"), "…/b/c");
    assert_eq!(shorten_cwd("/srv/a", "/home/me"), "/srv/a");
    assert_eq!(shorten_cwd("/srv/a/b", ""), "…/a/b");
}

#[test]
fn allowed_roots_refuse_non_strings_and_empty_roots() {
    for parse in [crate::pty::parse_allowed_roots, crate::actions::frame_roots] {
        assert_eq!(parse(&json!({})), Ok(None));
        assert_eq!(parse(&json!({"allowedRoots": null})), Ok(None));
        assert_eq!(parse(&json!({"allowedRoots": ["/tmp"]})), Ok(Some(vec!["/tmp".to_owned()])));
        assert!(parse(&json!({"allowedRoots": ["/tmp", 7]})).is_err());
        assert!(parse(&json!({"allowedRoots": [""]})).is_err());
        assert!(parse(&json!({"allowedRoots": "/tmp"})).is_err());
    }
}

#[test]
fn cap_lines_truncates_only_past_the_cap() {
    use crate::actions::cap_lines;
    let limit = json!(2);
    assert_eq!(cap_lines("a\nb", false, Some(&limit)), ("a\nb".to_owned(), false));
    assert_eq!(
        cap_lines("a\nb\nc", false, Some(&limit)),
        ("a\nb\n…[1 more lines]".to_owned(), true)
    );
    assert_eq!(cap_lines("a\nb\nc", true, None), ("a\nb\nc".to_owned(), true));
}

#[test]
fn unicode_escape_writes_the_code_point() {
    assert_eq!(crate::display::unicode_escape('\u{7}'), "\\u{7}");
    assert_eq!(crate::display::unicode_escape('\u{202e}'), "\\u{202E}");
}

#[test]
fn cookie_pairs_split_at_the_first_equals_sign() {
    let mut headers = hyper::HeaderMap::new();
    headers.insert(hyper::header::COOKIE, "a=b; flag ; c = d=e;=x".parse().unwrap());
    let pairs = crate::preview_access::cookie_pairs(&headers);
    let expected: Vec<(&[u8], &[u8])> =
        vec![(b"a", b"b"), (b"flag", b""), (b"c", b"d=e"), (b"", b"x")];
    assert_eq!(pairs, expected);
}

#[test]
fn inject_into_html_prefers_head_then_body_then_prepends() {
    use crate::preview_proxy::inject_into_html;
    let tag = "<script src=\"/__chatmux__/target.js?capability=k\"></script>";
    let injected = |html: &str| String::from_utf8(inject_into_html(html.as_bytes(), "k")).unwrap();
    assert_eq!(injected("<HEAD>x</HEAD>y"), format!("<HEAD>x{tag}</HEAD>y"));
    assert_eq!(injected("<body class=a>z"), format!("<body class=a>{tag}z"));
    // A `<body` with no closing `>` is not a tag: prepend.
    assert_eq!(injected("text <body"), format!("{tag}text <body"));
    assert_eq!(injected(""), tag);
}

#[test]
fn tunnel_decoder_waits_for_a_whole_header_and_payload() {
    use crate::tunnel_terminal::{
        FRAME_KIND_PTY, TunnelFrame, TunnelFrameDecoder, encode_tunnel_frame,
    };
    let frame = encode_tunnel_frame(FRAME_KIND_PTY, b"hi");
    let mut decoder = TunnelFrameDecoder::new(1024);
    for byte in frame.iter().take(frame.len() - 1) {
        assert_eq!(decoder.push(std::slice::from_ref(byte)), Ok(Vec::new()));
    }
    let last = frame.last().copied().into_iter().collect::<Vec<u8>>();
    assert_eq!(
        decoder.push(&last),
        Ok(vec![TunnelFrame { kind: FRAME_KIND_PTY, payload: b"hi".to_vec() }])
    );
}

#[test]
fn cute_code_reads_the_first_three_digest_bytes() {
    let code = crate::fingerprint::derive_cute_code("key");
    let [first, second, number] = code.split('-').collect::<Vec<_>>()[..] else {
        panic!("word-word-NN, got {code}");
    };
    assert!(crate::fingerprint::CUTE_WORDS.contains(&first));
    assert!(crate::fingerprint::CUTE_WORDS.contains(&second));
    assert_eq!(number.len(), 2);
}

#[test]
fn utf16_units_before_counts_surrogate_pairs() {
    use crate::workspace::utf16_units_before;
    let line = "a😀b";
    assert_eq!(utf16_units_before(line, 0), 0);
    assert_eq!(utf16_units_before(line, 1), 1);
    assert_eq!(utf16_units_before(line, line.find('b').unwrap()), 3);
}

#[test]
fn git_diff_prefix_keeps_the_first_bytes_across_chunks() {
    let mut prefix = crate::workspace::GitDiffPrefix::default();
    prefix.retain(b"diff ");
    prefix.retain(b"--git a/x b/x");
    assert_eq!(prefix.as_bytes(), b"diff --git");
    prefix.retain(b"more");
    assert_eq!(prefix.as_bytes(), b"diff --git");
}

#[tokio::test]
async fn bounded_git_diff_line_reads_across_small_buffers() {
    use crate::workspace::{BoundedGitDiffLine, read_bounded_git_diff_line};
    let input = b"+short\n-a much longer line\n+tail".as_slice();
    let mut reader = tokio::io::BufReader::with_capacity(4, input);
    let mut line = Vec::new();
    let mut read = Vec::new();
    while let Some(next) = read_bounded_git_diff_line(&mut reader, &mut line, 8).await.unwrap() {
        read.push(next);
    }
    let mut long = crate::workspace::GitDiffPrefix::default();
    long.retain(b"-a much longer line\n");
    assert_eq!(
        read,
        vec![
            BoundedGitDiffLine::Complete("+short".to_owned()),
            BoundedGitDiffLine::TooLong(long),
            BoundedGitDiffLine::Complete("+tail".to_owned()),
        ]
    );
}

#[cfg(unix)]
#[tokio::test]
async fn bounded_journal_line_reads_across_small_buffers() {
    use crate::journal_forwarder::read_bounded_line;
    let input = b"{\"a\":1}\nlast".as_slice();
    let mut reader = tokio::io::BufReader::with_capacity(3, input);
    assert_eq!(read_bounded_line(&mut reader, 64).await.unwrap().as_deref(), Some("{\"a\":1}\n"));
    assert_eq!(read_bounded_line(&mut reader, 64).await.unwrap().as_deref(), Some("last"));
    assert_eq!(read_bounded_line(&mut reader, 64).await.unwrap(), None);
    let mut reader = tokio::io::BufReader::with_capacity(3, b"0123456789\n".as_slice());
    assert!(read_bounded_line(&mut reader, 4).await.is_err());
}

#[test]
fn watch_record_merges_a_repeated_path() {
    let change =
        |path: &str, kind| wire::FsWatchChange { path: path.to_owned(), kind, old_path: None };
    let mut changes = Vec::new();
    let mut index = HashMap::new();
    crate::watch::record(&mut changes, &mut index, change("a", wire::FsWatchChangeKind::Created));
    crate::watch::record(&mut changes, &mut index, change("b", wire::FsWatchChangeKind::Created));
    crate::watch::record(&mut changes, &mut index, change("a", wire::FsWatchChangeKind::Modified));
    crate::watch::record(&mut changes, &mut index, change("b", wire::FsWatchChangeKind::Deleted));
    assert_eq!(
        changes,
        vec![
            change("a", wire::FsWatchChangeKind::Created),
            change("b", wire::FsWatchChangeKind::Deleted)
        ]
    );
}

#[test]
fn random_ids_have_their_full_length_and_alphabet() {
    let pair_id = crate::pairing::mint_pair_id().expect("pair id");
    let tail = pair_id.strip_prefix("pair_").expect("pair_ prefix");
    assert_eq!(tail.len(), 24);
    assert!(tail.bytes().all(|byte| byte.is_ascii_digit() || byte.is_ascii_lowercase()));

    let session = crate::tunnel_terminal::generate_session_name();
    let suffix = session.strip_prefix("web-").expect("web- prefix");
    assert_eq!(suffix.len(), 4);
    assert!(suffix.bytes().all(|byte| b"abcdefghjkmnpqrstuvwxyz23456789".contains(&byte)));
}

#[test]
fn alphabet_symbol_wraps_every_byte_into_the_alphabet() {
    use crate::panic_free::alphabet_symbol;
    assert_eq!(alphabet_symbol(b"abc", 0), 'a');
    assert_eq!(alphabet_symbol(b"abc", 4), 'b');
    assert_eq!(alphabet_symbol(b"abc", 255), 'a');
}
