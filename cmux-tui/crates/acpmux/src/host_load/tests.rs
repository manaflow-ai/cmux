use super::*;
use serde_json::json;

fn need(kind: Kind, vcpu: u32, mem_gib: u32) -> Option<Heavy> {
    Some(Heavy { kind, need: Need { vcpu, mem_gib } })
}

#[test]
fn builds_and_tests_are_known_from_comm_and_argv() {
    assert_eq!(classify("cargo", &["cargo", "build", "-p", "x"]), need(Kind::Build, 8, 15));
    assert_eq!(classify("cargo", &["/usr/bin/cargo", "test"]), need(Kind::Test, 8, 15));
    assert_eq!(classify("cargo", &["cargo", "fmt"]), None, "not a build");
    assert_eq!(classify("rustc", &["rustc", "--crate-name", "a"]), need(Kind::Build, 8, 15));
    assert_eq!(classify("swift-frontend", &[]), need(Kind::Build, 4, 13));
    assert_eq!(classify("swift", &["swift", "test"]), need(Kind::Test, 6, 11));
    assert_eq!(classify("go", &["go", "test", "./..."]), need(Kind::Test, 8, 8));
    assert_eq!(classify("go", &["go", "run", "."]), None);
    assert_eq!(classify("cc1plus", &[]), need(Kind::Build, 8, 8));
    assert_eq!(classify("bun", &["bun", "test", "a.test.ts"]), need(Kind::Test, 6, 2));
    assert_eq!(classify("bun", &["bun", "run", "dev"]), None);
    assert_eq!(classify("bun", &["bun", "x", "tsc", "-b"]), need(Kind::Build, 6, 2));
    assert_eq!(classify("npx", &["npx", "vitest", "run"]), need(Kind::Test, 6, 2));
    assert_eq!(classify("npx", &["npx", "vite", "build"]), need(Kind::Build, 6, 2));
    // A node script is its tool.
    let vitest = ["node", "/w/node_modules/.bin/vitest.mjs", "run"];
    assert_eq!(classify("node", &vitest), need(Kind::Test, 6, 2));
    assert_eq!(
        classify("node", &["node", "/w/node_modules/typescript/bin/tsc"]),
        need(Kind::Build, 6, 2)
    );
    assert_eq!(
        classify("node", &["node", "/w/node_modules/.bin/vite", "build"]),
        need(Kind::Build, 6, 2)
    );
    assert_eq!(classify("node", &["node", "/w/node_modules/.bin/vite"]), None, "a dev server");
    assert_eq!(classify("bash", &["bash", "-c", "cargo build"]), None);
    assert_eq!(classify("claude", &["claude"]), None);
}

#[test]
fn the_heaviest_process_wins() {
    let ps = vec![
        ("node", vec!["node", "vitest.mjs"]),
        ("cargo", vec!["cargo", "test"]),
        ("make", vec!["make", "-j8"]),
        ("zsh", vec!["-zsh"]),
    ];
    assert_eq!(heaviest(ps), need(Kind::Test, 8, 15));
    assert_eq!(heaviest(vec![("zsh", vec!["zsh"])]), None);
}

#[test]
fn the_sample_is_camel_case_and_omits_what_it_could_not_read() {
    let bare = Load { at: 7, ..Load::default() };
    assert_eq!(serde_json::to_value(&bare).unwrap(), json!({"at": 7}));
    let full = Load {
        at: 1,
        cpu_busy: Some(0.5),
        mem_some_avg60: Some(1.0),
        swap_used_fraction: Some(0.1),
        busy: Some(true),
        local_turns: Some(2),
        heavy: need(Kind::Build, 8, 15),
        ..Load::default()
    };
    assert_eq!(
        serde_json::to_value(&full).unwrap(),
        json!({"at": 1, "cpuBusy": 0.5, "memSomeAvg60": 1.0, "swapUsedFraction": 0.1,
                   "busy": true, "localTurns": 2,
                   "heavy": {"kind": "build", "need": {"vcpu": 8, "memGiB": 15}}})
    );
}

#[test]
fn turns_come_from_daemon_status() {
    assert_eq!(turns_of(&json!({"host_pressure": {"local_turns": 3}})), Some(3));
    assert_eq!(turns_of(&json!({"host_pressure": {"ok": null}})), None);
}

#[test]
fn a_shell_command_is_known_from_its_simple_commands() {
    assert_eq!(classify_command("cargo build -p acpmux"), need(Kind::Build, 8, 15));
    assert_eq!(classify_command("cd /w && cargo test --locked"), need(Kind::Test, 8, 15));
    assert_eq!(classify_command("RUST_LOG=1 nice -n 10 cargo clippy"), need(Kind::Build, 8, 15));
    assert_eq!(classify_command("bash -lc 'go test ./...'"), need(Kind::Test, 8, 8));
    assert_eq!(classify_command("bun test a.test.ts; make -j8"), need(Kind::Build, 8, 8));
    assert_eq!(classify_command("npx vitest run | tee log"), need(Kind::Test, 6, 2));
    assert_eq!(classify_command("git status && rg cargo"), None);
    assert_eq!(classify_command("echo cargo build"), None, "an argument, not the program");
    assert_eq!(classify_command(""), None);
}

#[test]
fn a_tool_call_runs_its_execute_command() {
    let bash = json!({"kind": "execute", "rawInput": {"command": "cargo test"}});
    assert_eq!(heavy_of_tool(&bash), need(Kind::Test, 8, 15));
    let argv = json!({"rawInput": {"command": ["bash", "-lc", "swift build"]}});
    assert_eq!(heavy_of_tool(&argv), need(Kind::Build, 4, 13));
    let mcp = json!({"kind": "other", "rawInput": {"command": "cargo build"}});
    assert_eq!(heavy_of_tool(&mcp), None, "only a shell command runs");
    assert_eq!(heavy_of_tool(&json!({"kind": "execute"})), None);
}

#[test]
fn heavy_comes_from_daemon_status() {
    let status =
        json!({"host_pressure": {"heavy": {"kind": "test", "need": {"vcpu": 6, "memGiB": 2}}}});
    assert_eq!(heavy_of(&status), need(Kind::Test, 6, 2));
    assert_eq!(heavy_of(&json!({"host_pressure": {"local_turns": 0}})), None);
}
