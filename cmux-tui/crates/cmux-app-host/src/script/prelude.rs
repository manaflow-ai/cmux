//! The `main` of a script session: acorn, the REPL cell host and the script
//! prelude, in that order, after the app runtime the host always loads.

/// acorn 8.16.0, vendored by the browser host (MIT, THIRD_PARTY_LICENSES.md).
const ACORN: &str = include_str!("../../../cmux-browser-host/js/vendor/acorn.js");
/// The browser REPL's cell host: top-level await and bindings kept across
/// cells. Without a `__cmuxNative` global it installs nothing else.
const REPL_HOST: &str = include_str!("../../../cmux-browser-host/js/repl-host.js");
/// `eval` export, timers, `cmux.wait`, `cmux.sleep`, `cmux.args`.
const PRELUDE: &str = include_str!("../../js/script-prelude.js");

/// The app id a script session's runtime sees (`cmux.app.id`).
pub const APP_ID: &str = "cmux/script";

/// The classic script the host evaluates as the session's `main`.
pub fn main_source() -> String {
    let mut source = String::with_capacity(ACORN.len() + REPL_HOST.len() + PRELUDE.len() + 8);
    for part in [ACORN, REPL_HOST, PRELUDE] {
        source.push_str(part);
        source.push_str(";\n");
    }
    source
}
