use super::*;

#[test]
fn color_replies_with_either_terminator_are_complete() {
    let st = b"\x1b]11;rgb:2727/2828/2222\x1b\\a";
    assert_eq!(scan_host_reply(st), HostReply::Complete(st.len() - 1));
    let bel = b"\x1b]10;rgb:fdfd/ffff/f1f1\x07";
    assert_eq!(scan_host_reply(bel), HostReply::Complete(bel.len()));
}

#[test]
fn a_reply_without_its_end_is_partial_and_keys_are_not_replies() {
    assert_eq!(scan_host_reply(b"\x1b]"), HostReply::Partial);
    assert_eq!(scan_host_reply(b"\x1b]11"), HostReply::Partial);
    assert_eq!(scan_host_reply(b"\x1b]11;rgb:27"), HostReply::Partial);
    assert_eq!(scan_host_reply(b"\x1b]11;rgb:27\x1b"), HostReply::Partial);
    assert_eq!(scan_host_reply(b"\x1b]1"), HostReply::Partial);
    assert_eq!(scan_host_reply(b"\x1b]12"), HostReply::NotAReply);
    assert_eq!(scan_host_reply(b"\x1b]52;c;x\x07"), HostReply::NotAReply);
    assert_eq!(scan_host_reply(b"\x1b]a"), HostReply::NotAReply);
    assert_eq!(scan_host_reply(b"\x1b];x\x07"), HostReply::NotAReply);
    assert_eq!(scan_host_reply(b"\x1b]11;x\rmore"), HostReply::NotAReply);
    assert_eq!(scan_host_reply(b"\x1b[A"), HostReply::NotAReply);
    assert_eq!(scan_host_reply(b"a"), HostReply::NotAReply);
}
