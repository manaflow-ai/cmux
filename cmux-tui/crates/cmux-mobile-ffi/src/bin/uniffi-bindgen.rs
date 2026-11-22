//! uniffi binding generator for cmux-mobile-ffi.
//!
//! `cargo run -p cmux-mobile-ffi --features bindgen --bin uniffi-bindgen --
//! generate --library <built library> --language swift|kotlin --out-dir <dir>`

fn main() {
    uniffi::uniffi_bindgen_main();
}
