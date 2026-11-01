//! Attach replay of wide and invalid characters at a row's right edge (VT fuzz finding E2, cmux-ad P0 resize,
//! 2026-10-31). The shrink of E2 (fleet step fd3560f0) needs no resize and no scroll region: rows of text, then
//! invalid UTF-8 and wide characters at the end of a row. A fresh terminal of the same size fed `vt_replay_bytes()`
//! (the attach primitive) must show the same viewport text and cursor as the terminal.

use ghostty_vt::{Callbacks, Terminal};

const SCROLLBACK: usize = 1 << 20;

fn replay_difference(cols: u16, rows: u16, bytes: &[u8]) -> Option<String> {
    let mut term = Terminal::new(cols, rows, SCROLLBACK, Callbacks::default()).unwrap();
    term.vt_write(bytes);
    assert!(term.vt_stream_is_ground());
    let replay = term.vt_replay_bytes().unwrap();
    let mut view = Terminal::new(cols, rows, SCROLLBACK, Callbacks::default()).unwrap();
    view.vt_write(&replay);
    let (text, view_text) = (term.viewport_text().unwrap(), view.viewport_text().unwrap());
    (text != view_text || term.cursor_position() != view.cursor_position()).then(|| {
        format!(
            "terminal {text:?} cursor {:?}\n view     {view_text:?} cursor {:?}\n replay {:?}",
            term.cursor_position(),
            view.cursor_position(),
            String::from_utf8_lossy(&replay)
        )
    })
}

/// The 1130-byte shrink of E2 (from 20x5).
fn include_e2() -> Vec<u8> {
    b" 0a aa A0Aa0 0 a aaA  A  A0aAAAaaA00aA0aA0 aAa0AaaAa0 a0AAa    0A A0a aA0   AAAaaa00 a a aa0aaA0aaA a aAA 0aaA0a0A 0 A0AAa0aa0a0 0 A0a  AA aA 0aA A aaaaa0aaAa AAaa a0 0AaaAAA0 aA 0A0Aa A AaaaAAAA Aa a  aAAA0aaA0aAaa0   Aa 0 aa  aA0 aAa0Aa00 aa A 0a  a a0 aaAA00 0aaaa  AAAaA00  0aA A0a00Aa A00 a 0AaA 0Aa 0Aaaa  aAa  00A0  aAA0aAaAa0A00000AA 0 aAAa0  a  AaAaA aa 0a aaA0aaAA  AAaA a0    Aa 0 aAAAA 0 AA 00 00aa 0a aA0aaaAAa A0a  AAAA AA0A  a   000a0A0A  aa 0aA A0AAA0aaa Aa             J*l{fI]kWtr1[d#2F//$V[&Jv?|cei.%@|H&t=.=\x22'\x5c$=\x22I'`,<\x5cf~rL3Eb8K\x22..$oqE`D|hbJac$1{~~4&(?0</bmKwd3,`\x5c*{6(j!J`[V1/s&_GuD\x5cW\x5cd`{y>zf:_b+G&-~v<:A<?LDJN!'[}&bn\x226`g/IW$s=%`\x22hq_i&x!s?|<C$^B`R\x22ITW$%>?|C,Qzun{p/=D(58>&}ek&1$i{(?!o^*i$$%p:\x22suqT7%dR73J}8yaW%:_CQbbu--:vC\x22[Bt>ME$y/|N33{YTm\x5c%c&^hj{0`q/{rm]w$M<+=\x5c'\x5cZ%b~*:*gh*M4u.NyS{@*'lg2hS?\x22t\x5c+Z.C.I]=J~b\x5cE1viv-\x22='K4,&>?'*J'$o[gj:`b| =\x5c\x22F.%+&&JTYlg4SUy{e?q<o/J%E/R?{`=j6U1FFp/7B6'!'CH/o:>~xKZ}H-&1j<AJwS1*{^09w'~..ps6|Zx8U#h:+8=lqK-_?C@'Z%$..>*;8'Wy\x5c/8g:qE6/==~2S{h&%~.,\x22= c|$98:k+r{$hPsD`v\x22%t%4 qg:,iSD'\x227{G4Kg\x5c%N`1lT&yge<~$'`R@r~=*8Lz}\x220~mY>'\x5cf{*`OH?3,Qj=u*?`d>P'wIza'R%tcz  yij\xf0\x8bb\xb8\x8b\xf0\x9f\x98\x80\xb8\x92  d\xf0\x9f\x98\x8a\xb8\x87\xf0\x9f\x98\x9f\x98\x84\xe4\xb8\x8d".to_vec()
}

/// The 1130-byte shrink of E2, from 20x5.
#[test]
fn vt_replay_edge_e2_shrunk_stream() {
    let difference = replay_difference(20, 5, &include_e2());
    assert!(difference.is_none(), "E2 shrunk: {}", difference.unwrap_or_default());
}

#[test]
fn vt_replay_edge_a_wide_char_fills_the_last_two_columns() {
    let difference = replay_difference(20, 5, b"aaaaaaaaaaaaaaaaaa\xe6\xbc\xa2b");
    assert!(
        difference.is_none(),
        "a_wide_char_fills_the_last_two_columns: {}",
        difference.unwrap_or_default()
    );
}

#[test]
fn vt_replay_edge_an_emoji_that_does_not_fit_leaves_a_spacer_head() {
    let difference = replay_difference(20, 5, b"aaaaaaaaaaaaaaaaaaa\xf0\x9f\x98\x80x");
    assert!(
        difference.is_none(),
        "an_emoji_that_does_not_fit_leaves_a_spacer_head: {}",
        difference.unwrap_or_default()
    );
}

#[test]
fn vt_replay_edge_an_invalid_byte_in_the_last_column() {
    let difference = replay_difference(20, 5, b"aaaaaaaaaaaaaaaaaaa\xffx");
    assert!(
        difference.is_none(),
        "an_invalid_byte_in_the_last_column: {}",
        difference.unwrap_or_default()
    );
}

#[test]
fn vt_replay_edge_a_truncated_sequence_in_the_last_column() {
    let difference = replay_difference(20, 5, b"aaaaaaaaaaaaaaaaaaa\xf0\x8bx");
    assert!(
        difference.is_none(),
        "a_truncated_sequence_in_the_last_column: {}",
        difference.unwrap_or_default()
    );
}

#[test]
fn vt_replay_edge_a_stray_continuation_byte_in_the_last_column() {
    let difference = replay_difference(20, 5, b"aaaaaaaaaaaaaaaaaaa\xb8x");
    assert!(
        difference.is_none(),
        "a_stray_continuation_byte_in_the_last_column: {}",
        difference.unwrap_or_default()
    );
}

#[test]
fn vt_replay_edge_a_wide_char_after_a_pending_wrap() {
    let difference = replay_difference(20, 5, b"aaaaaaaaaaaaaaaaaaaa\xe6\xbc\xa2x");
    assert!(
        difference.is_none(),
        "a_wide_char_after_a_pending_wrap: {}",
        difference.unwrap_or_default()
    );
}

#[test]
fn vt_replay_edge_the_shrunk_tail_at_a_row_end() {
    let difference = replay_difference(20, 5, b"aaaaaaaaaaaaaayij\xf0\x8bb\xb8\x8b\xf0\x9f\x98\x80\xb8\x92  d\xf0\x9f\x98\x8a\xb8\x87\xf0\x9f\x98\x9f\x98\x84\xe4\xb8\x8d");
    assert!(
        difference.is_none(),
        "the_shrunk_tail_at_a_row_end: {}",
        difference.unwrap_or_default()
    );
}
