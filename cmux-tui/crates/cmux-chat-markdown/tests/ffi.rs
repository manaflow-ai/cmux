//! The C ABI: bytes out match `encode` of the Rust parse, the host callback decides links, the
//! image templates reach the text, and the tail form starts at its line.

use std::ffi::c_void;

use cmux_chat_markdown::ffi::{
    CMUX_CHAT_MARKDOWN_ABI_VERSION, CMUX_CHAT_MARKDOWN_WHOLE_TEXT, CmuxChatMarkdownPolicy,
    cmux_chat_markdown_abi_version, cmux_chat_markdown_free, cmux_chat_markdown_might_contain,
    cmux_chat_markdown_parse,
};
use cmux_chat_markdown::{DefaultPolicy, LinkPolicy, encode, parse, parse_tail};

fn call(text: &str, from: u32, policy: Option<&CmuxChatMarkdownPolicy>) -> Vec<u8> {
    let mut len = 0usize;
    let p = policy.map_or(std::ptr::null(), std::ptr::from_ref);
    // SAFETY: a live string, a live policy or null, a live out pointer.
    let ptr = unsafe { cmux_chat_markdown_parse(text.as_ptr(), text.len(), from, p, &raw mut len) };
    assert!(!ptr.is_null());
    // SAFETY: the parse's bytes and their length.
    let out = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
    // SAFETY: freed once with its length.
    unsafe { cmux_chat_markdown_free(ptr, len) };
    out
}

#[test]
fn version_and_precheck() {
    assert_eq!(cmux_chat_markdown_abi_version(), CMUX_CHAT_MARKDOWN_ABI_VERSION);
    let s = "plain words";
    // SAFETY: a live string.
    assert!(!unsafe { cmux_chat_markdown_might_contain(s.as_ptr(), s.len()) });
    let s = "**bold**";
    // SAFETY: a live string.
    assert!(unsafe { cmux_chat_markdown_might_contain(s.as_ptr(), s.len()) });
    // SAFETY: null with length 0.
    assert!(!unsafe { cmux_chat_markdown_might_contain(std::ptr::null(), 0) });
}

#[test]
fn whole_text_bytes_are_the_encoded_document() {
    let text = "# T\n\n- [x] a [l](https://a.com)\n\n| a |\n|---|\n| 1 |\n\n![i](x)";
    assert_eq!(
        call(text, CMUX_CHAT_MARKDOWN_WHOLE_TEXT, None),
        encode::document(&parse(text, &DefaultPolicy))
    );
}

#[test]
fn tail_bytes_are_the_encoded_blocks() {
    let text = "a\n\nb\n- c";
    assert_eq!(call(text, 2, None), encode::blocks(&parse_tail(text, 2, &DefaultPolicy)));
}

unsafe extern "C" fn only_b(ctx: *mut c_void, url: *const u8, len: usize) -> bool {
    // SAFETY: the parser's live buffer.
    let url = unsafe { std::slice::from_raw_parts(url, len) };
    // SAFETY: the test's counter.
    unsafe { *ctx.cast::<usize>() += 1 };
    url == b"https://b.com"
}

struct Expect;

impl LinkPolicy for Expect {
    fn allows(&self, url: &str) -> bool {
        url == "https://b.com"
    }

    fn image_placeholder(&self, alt: &str) -> String {
        if alt.is_empty() { "(img)".to_owned() } else { format!("(img {alt})") }
    }
}

#[test]
fn host_policy_crosses_the_boundary() {
    let mut calls = 0usize;
    let empty = "(img)";
    let template = "(img %@)";
    let policy = CmuxChatMarkdownPolicy {
        allows: Some(only_b),
        ctx: (&raw mut calls).cast::<c_void>(),
        image_empty: empty.as_ptr(),
        image_empty_len: empty.len(),
        image_template: template.as_ptr(),
        image_template_len: template.len(),
    };
    let text = "[a](https://a.com) [b](https://b.com) ![x](y) ![](z)";
    let out = call(text, CMUX_CHAT_MARKDOWN_WHOLE_TEXT, Some(&policy));
    assert_eq!(out, encode::document(&parse(text, &Expect)));
    assert!(calls >= 2);
}

#[test]
fn null_text_is_an_empty_document() {
    let mut len = 0usize;
    // SAFETY: null text with length 0, a live out pointer.
    let ptr = unsafe {
        cmux_chat_markdown_parse(
            std::ptr::null(),
            0,
            CMUX_CHAT_MARKDOWN_WHOLE_TEXT,
            std::ptr::null(),
            &raw mut len,
        )
    };
    // SAFETY: the parse's bytes.
    let out = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
    // SAFETY: freed once.
    unsafe { cmux_chat_markdown_free(ptr, len) };
    assert_eq!(out, vec![0, 0, 0, 0, 0]);
    // SAFETY: null is a no-op.
    unsafe { cmux_chat_markdown_free(std::ptr::null_mut(), 0) };
}
