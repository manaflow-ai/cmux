pub fn zig_target_arg(target: &str, host: &str) -> Option<String> {
    if target == host {
        return None;
    }
    zig_target_for_rust_target(target).map(|zig_target| format!("-Dtarget={zig_target}"))
}

fn zig_target_for_rust_target(target: &str) -> Option<&'static str> {
    match target {
        "x86_64-pc-windows-gnu" => Some("x86_64-windows-gnu"),
        "x86_64-pc-windows-msvc" => Some("x86_64-windows-msvc"),
        "aarch64-pc-windows-msvc" => Some("aarch64-windows-msvc"),
        // Cross-compiling libghostty-vt for the release distribution targets
        // (npm/PyPI `cmux` binaries). zig cross-compiles these cleanly and
        // pairs with cargo-zigbuild for the Rust link step.
        "x86_64-apple-darwin" => Some("x86_64-macos"),
        "aarch64-apple-darwin" => Some("aarch64-macos"),
        "x86_64-unknown-linux-gnu" => Some("x86_64-linux-gnu"),
        "aarch64-unknown-linux-gnu" => Some("aarch64-linux-gnu"),
        "x86_64-unknown-linux-musl" => Some("x86_64-linux-musl"),
        "aarch64-unknown-linux-musl" => Some("aarch64-linux-musl"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_windows_gnu_keeps_the_explicit_gnu_abi() {
        assert_eq!(
            zig_target_arg("x86_64-pc-windows-gnu", "x86_64-pc-windows-gnu").as_deref(),
            Some("-Dtarget=x86_64-windows-gnu")
        );
    }
}
