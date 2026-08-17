pub fn zig_target_arg(target: &str, host: &str) -> Option<String> {
    // Keep Zig's native target selection for existing native builds. A GNU
    // Windows host is different: Zig otherwise selects the MSVC ABI and then
    // requires a Windows SDK that a MinGW-only environment does not have.
    if target == host && !target.ends_with("-windows-gnu") {
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
        // (npm/PyPI `cmux` binaries). Zig cross-compiles these cleanly and
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
    fn windows_launch_native_gnu_host_keeps_the_explicit_gnu_abi() {
        assert_eq!(
            zig_target_arg("x86_64-pc-windows-gnu", "x86_64-pc-windows-gnu").as_deref(),
            Some("-Dtarget=x86_64-windows-gnu")
        );
    }

    #[test]
    fn windows_launch_native_unix_hosts_keep_zigs_native_target() {
        for host in ["aarch64-apple-darwin", "x86_64-unknown-linux-gnu"] {
            assert_eq!(zig_target_arg(host, host), None, "{host}");
        }
    }

    #[test]
    fn windows_launch_cross_targets_keep_their_explicit_zig_abi() {
        let cases = [
            ("x86_64-pc-windows-gnu", "aarch64-unknown-linux-gnu", "-Dtarget=x86_64-windows-gnu"),
            ("x86_64-pc-windows-msvc", "aarch64-unknown-linux-gnu", "-Dtarget=x86_64-windows-msvc"),
            (
                "aarch64-pc-windows-msvc",
                "x86_64-unknown-linux-gnu",
                "-Dtarget=aarch64-windows-msvc",
            ),
            ("x86_64-apple-darwin", "aarch64-unknown-linux-gnu", "-Dtarget=x86_64-macos"),
            ("aarch64-apple-darwin", "x86_64-unknown-linux-gnu", "-Dtarget=aarch64-macos"),
            ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu", "-Dtarget=x86_64-linux-gnu"),
            ("aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu", "-Dtarget=aarch64-linux-gnu"),
            (
                "x86_64-unknown-linux-musl",
                "aarch64-unknown-linux-gnu",
                "-Dtarget=x86_64-linux-musl",
            ),
            (
                "aarch64-unknown-linux-musl",
                "x86_64-unknown-linux-gnu",
                "-Dtarget=aarch64-linux-musl",
            ),
        ];

        for (target, host, expected) in cases {
            assert_eq!(zig_target_arg(target, host).as_deref(), Some(expected), "{target}");
        }
    }

    #[test]
    fn unknown_cross_targets_fail_closed() {
        assert!(zig_target_arg("riscv64-unknown-linux-gnu", "x86_64-unknown-linux-gnu").is_err());
    }
}
