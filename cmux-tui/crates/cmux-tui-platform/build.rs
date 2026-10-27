//! Sets `cmux_frame_pointers` when this build keeps frame pointers
//! (`-C force-frame-pointers=yes` in its rustflags), so `thread_backtrace`
//! walks them on Linux instead of keeping only the interrupted pc.

fn main() {
    println!("cargo::rustc-check-cfg=cfg(cmux_frame_pointers)");
    println!("cargo::rerun-if-env-changed=CARGO_ENCODED_RUSTFLAGS");
    let flags = std::env::var("CARGO_ENCODED_RUSTFLAGS").unwrap_or_default();
    if keeps_frame_pointers(&flags) {
        println!("cargo::rustc-cfg=cmux_frame_pointers");
    }
}

/// Whether the last `force-frame-pointers` codegen flag in `encoded`
/// (rustflags separated by 0x1f) turns them on.
fn keeps_frame_pointers(encoded: &str) -> bool {
    let mut keeps = false;
    let mut flags = encoded.split('\x1f');
    while let Some(flag) = flags.next() {
        let codegen = match flag {
            "-C" | "--codegen" => flags.next().unwrap_or_default(),
            other => other
                .strip_prefix("-C")
                .or_else(|| other.strip_prefix("--codegen="))
                .unwrap_or_default(),
        };
        if let Some(value) = codegen.strip_prefix("force-frame-pointers") {
            keeps = matches!(value, "" | "=yes" | "=y" | "=on" | "=true" | "=always");
        }
    }
    keeps
}
