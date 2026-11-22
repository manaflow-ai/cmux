//! The C ABI: the same answers as the Rust API, the buffer protocol, and no
//! panic or write past the buffer on bad input.

use crate::ffi::*;

fn resolve(input: &str, flags: u32, cap: usize) -> (i32, usize, Vec<u8>) {
    let home = "/Users/me/";
    let mut out = vec![0u8; cap];
    let mut len = usize::MAX;
    // SAFETY: valid pointers and lengths for every argument.
    let code = unsafe {
        cmux_url_input_resolve_typed(
            input.as_ptr(),
            input.len(),
            home.as_ptr(),
            home.len(),
            flags,
            out.as_mut_ptr(),
            out.len(),
            &mut len,
        )
    };
    (code, len, out)
}

#[test]
fn resolve_writes_the_url_or_says_search() {
    let (code, len, out) = resolve("devbox:8080", 0, 64);
    assert_eq!((code, &out[..len]), (FOUND, &b"http://devbox:8080"[..]));
    let (code, len, _) = resolve("swift testing", 0, 64);
    assert_eq!((code, len), (NONE, 0));
}

#[test]
fn a_short_buffer_reports_the_length_and_writes_nothing() {
    let (code, len, out) = resolve("https://example.com/a", 0, 4);
    assert_eq!((code, len), (ERR_SHORT, "https://example.com/a".len()));
    assert!(out.iter().all(|byte| *byte == 0));
    let (code, len, out) = resolve("https://example.com/a", 0, len);
    assert_eq!((code, &out[..len]), (FOUND, &b"https://example.com/a"[..]));
}

#[test]
fn the_chromium_flag_allows_webui_pages() {
    assert_eq!(resolve("chrome://extensions", 0, 64).0, NONE);
    let (code, len, out) = resolve("chrome://extensions", FLAG_ALLOWS_CHROMIUM, 64);
    assert_eq!((code, &out[..len]), (FOUND, &b"chrome://extensions/"[..]));
}

#[test]
fn bad_input_is_an_error_not_a_crash() {
    let bad = [0xffu8, 0xfe];
    let mut len = 0usize;
    let mut out = [0u8; 8];
    // SAFETY: valid pointers and lengths; the bytes are not UTF-8 on purpose.
    let code = unsafe {
        cmux_url_input_resolve_typed(
            bad.as_ptr(),
            2,
            std::ptr::null(),
            0,
            0,
            out.as_mut_ptr(),
            8,
            &mut len,
        )
    };
    assert_eq!(code, ERR_UTF8);
    // SAFETY: a null text with a non-zero length, and a null `out_len`.
    unsafe {
        assert_eq!(
            cmux_url_input_resolve_typed(
                std::ptr::null(),
                3,
                std::ptr::null(),
                0,
                0,
                out.as_mut_ptr(),
                8,
                &mut len
            ),
            ERR_NULL
        );
        assert_eq!(
            cmux_url_input_resolve_typed(
                b"x.com".as_ptr(),
                5,
                std::ptr::null(),
                0,
                0,
                out.as_mut_ptr(),
                8,
                std::ptr::null_mut()
            ),
            ERR_NULL
        );
        assert_eq!(
            cmux_url_input_resolve_typed(
                b"x.com".as_ptr(),
                5,
                std::ptr::null(),
                0,
                0,
                std::ptr::null_mut(),
                0,
                &mut len
            ),
            ERR_SHORT
        );
    }
    assert_eq!(len, "https://x.com".len());
}

#[test]
fn predicates() {
    let pairing = "see cmux-vnc://pair?room=r";
    // SAFETY: valid pointers and lengths.
    unsafe {
        assert_eq!(cmux_url_input_contains_pairing_link(pairing.as_ptr(), pairing.len()), FOUND);
        assert_eq!(cmux_url_input_contains_pairing_link(b"https://a.b".as_ptr(), 11), NONE);
        assert_eq!(cmux_url_input_is_loopback_host(b"127.0.0.9".as_ptr(), 9), FOUND);
        assert_eq!(cmux_url_input_is_loopback_host(b"app.localhost".as_ptr(), 13), FOUND);
        assert_eq!(cmux_url_input_is_loopback_host(b"example.com".as_ptr(), 11), NONE);
        assert_eq!(cmux_url_input_is_loopback_host(std::ptr::null(), 0), NONE);
    }
    assert_eq!(cmux_url_input_abi_version(), ABI_VERSION);
}

fn with_out(call: impl FnOnce(*mut u8, usize, *mut usize) -> i32) -> (i32, String) {
    let mut out = [0u8; 128];
    let mut len = 0usize;
    let code = call(out.as_mut_ptr(), out.len(), &mut len);
    (code, String::from_utf8(out[..len].to_vec()).unwrap())
}

#[test]
fn chromium_pages_and_routes() {
    let page = |text: &'static str| {
        // SAFETY: valid pointers and lengths.
        with_out(|out, cap, len| unsafe {
            cmux_url_input_chromium_internal_url(text.as_ptr(), text.len(), out, cap, len)
        })
    };
    let route = |text: &'static str| {
        // SAFETY: valid pointers and lengths.
        with_out(|out, cap, len| unsafe {
            cmux_url_input_chromium_page_route(text.as_ptr(), text.len(), out, cap, len)
        })
    };
    assert_eq!(page("CHROME://Extensions"), (FOUND, "chrome://extensions/".to_string()));
    assert_eq!(page("about:blank"), (NONE, String::new()));
    assert_eq!(route("about:history"), (ROUTE_CMUX_PAGE, "cmux://history".to_string()));
    assert_eq!(route("chrome://settings"), (ROUTE_BROWSER_SETTINGS, String::new()));
    assert_eq!(route("chrome://password-manager"), (ROUTE_PASSWORDS_PAGE, String::new()));
    assert_eq!(route("chrome://flags"), (ROUTE_CHROMIUM, "chrome://flags/".to_string()));
    assert_eq!(route("https://example.com"), (ROUTE_NONE, String::new()));
}
