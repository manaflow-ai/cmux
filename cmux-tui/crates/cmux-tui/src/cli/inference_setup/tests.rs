use super::*;

fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

/// What the probe prints: its status, then the header file, the body and curl's error after their markers.
fn probe_out(mark: &str, headers: &str, body: &str) -> String {
    format!("403\n{mark}headers\n{headers}\n{mark}body\n{body}\n{mark}error\n")
}

#[test]
fn a_refused_probe_shows_its_answer_without_credentials() {
    let mark = probe_mark();
    let headers = "HTTP/1.1 403 Forbidden\r\nserver: edge-proxy\r\nset-cookie: sid=abc\r\nAuthorization: Bearer x\r\n\
                       x-api-key: k\r\ncontent-type: text/plain\r\n\r\n";
    let shown =
        shown_answer(&probe_out(&mark, headers, "host not allowed: coderouter\u{1b}[0m"), &mark);
    assert_eq!(
        shown,
        "HTTP/1.1 403 Forbidden\nserver: edge-proxy\ncontent-type: text/plain\n\n\nhost not allowed: coderouter[0m"
    );
    assert!(!shown.contains("sid=") && !shown.contains("Bearer") && !shown.contains("x-api-key"));
    // A body line that merely mentions a key word is kept: only header lines are matched.
    let shown = shown_answer(&probe_out(&mark, "", "the token you sent: none"), &mark);
    assert_eq!(shown, "the token you sent: none");
}

#[test]
fn a_folded_credential_header_is_dropped_with_its_continuations() {
    let mark = probe_mark();
    let headers = "HTTP/1.1 200 Connection established\r\nproxy-agent: p\r\n\r\n\
                       HTTP/1.1 403 Forbidden\r\nSet-Cookie:\r\n\tsid=abc\r\n  more=def\r\nx-trace: t1\r\n\
                       \tcontinued\r\nAuthorization:\r\n Bearer zzz\r\n\r\n";
    let shown = shown_answer(&probe_out(&mark, headers, "  indented body line"), &mark);
    assert_eq!(
        shown,
        "HTTP/1.1 200 Connection established\nproxy-agent: p\n\nHTTP/1.1 403 Forbidden\nx-trace: t1\ncontinued\n\n\n  indented body line"
    );
    assert!(!shown.contains("sid=") && !shown.contains("more=") && !shown.contains("zzz"));
}

#[test]
fn a_whitespace_only_continuation_keeps_the_header_it_folds() {
    // A continuation of only whitespace neither ends the headers nor the dropped header it goes on with.
    let mark = probe_mark();
    let headers = "HTTP/1.1 403 Forbidden\r\nSet-Cookie:\r\n \r\n sid=private-session\r\n\
                       Authorization: Bearer private-token\r\nserver: edge\r\n\t\r\n\r\n";
    let shown = shown_answer(&probe_out(&mark, headers, "refused"), &mark);
    assert!(!shown.contains("private-session") && !shown.contains("private-token"), "{shown}");
    assert_eq!(shown, "HTTP/1.1 403 Forbidden\nserver: edge\n\n\n\nrefused");
}

#[test]
fn trailers_after_the_body_are_filtered_as_headers() {
    // curl writes a chunked answer's trailers to the header file after an empty line (checked with curl 8.5).
    let mark = probe_mark();
    let headers = "HTTP/1.1 403 Forbidden\r\nTransfer-Encoding: chunked\r\nserver: edge\r\n\r\n\
                       Set-Cookie: sid=trailer-secret\r\n continued-secret\r\nX-Api-Key: trailer-key\r\nx-hop: gw\r\n";
    let shown = shown_answer(&probe_out(&mark, headers, "refused"), &mark);
    for secret in ["trailer-secret", "continued-secret", "trailer-key"] {
        assert!(!shown.contains(secret), "{shown}");
    }
    assert!(
        shown.contains("server: edge") && shown.contains("x-hop: gw") && shown.ends_with("refused")
    );
}

#[test]
fn a_long_dropped_cookie_leaves_room_for_the_headers_after_it() {
    // The excerpt holds the headers kept, not the raw ones: a cookie past the whole budget is dropped and the next
    // hop's status and server still show; headers past the budget are cut with a line that says so.
    let mark = probe_mark();
    let cookie = "x".repeat(PROBE_EXCERPT * 2);
    let headers = format!(
        "HTTP/1.1 200 Connection established\r\nSet-Cookie: sid={cookie}\r\n\r\n\
             HTTP/1.1 403 Forbidden\r\nserver: the-refusing-hop\r\n\r\n"
    );
    let shown = shown_answer(&probe_out(&mark, &headers, "refused"), &mark);
    assert!(
        shown.contains("HTTP/1.1 403 Forbidden\nserver: the-refusing-hop")
            && !shown.contains("sid="),
        "{shown}"
    );
    assert!(!shown.contains("not shown"), "{shown}");
    let many = "x-hop: value\r\n".repeat(200);
    let shown = shown_answer(
        &probe_out(&mark, &format!("HTTP/1.1 403 Forbidden\r\n{many}"), "refused"),
        &mark,
    );
    let header_part = shown.split("[more header lines not shown]").next().unwrap_or("");
    assert!(
        header_part.len() <= PROBE_EXCERPT && shown.contains("[more header lines not shown]"),
        "{shown}"
    );
    assert!(shown.ends_with("refused"), "{shown}");
}

#[test]
fn a_body_cannot_pass_for_the_header_part() {
    // The marker's nonce is new each probe, so a body that writes a marker line of its own stays body, and nothing
    // in the body is read as headers; an answer written before the first marker is never shown.
    let mark = probe_mark();
    assert_ne!(mark, probe_mark());
    let body = "@@probe-0000000000000000-headers\nSet-Cookie: kept-as-body";
    let shown = shown_answer(
        &format!("403\nstray-before-marker\n{}", &probe_out(&mark, "", body)[4..]),
        &mark,
    );
    assert!(
        shown.contains("Set-Cookie: kept-as-body") && !shown.contains("stray-before-marker"),
        "{shown}"
    );
}

#[cfg(unix)]
#[test]
fn the_raw_headers_stay_private_and_are_removed() {
    // A stand-in curl, first on PATH: it writes a credential header and records, while the request runs, who may
    // read the probe's directory and its header file. After the probe, the directory is gone.
    use std::os::unix::fs::PermissionsExt;
    let bin = std::env::temp_dir().join(format!("probe-test-{}", std::process::id()));
    std::fs::create_dir_all(&bin).unwrap();
    let log = bin.join("log");
    let curl = bin.join("curl");
    std::fs::write(
            &curl,
            "#!/bin/sh\nwhile [ $# -gt 0 ]; do case \"$1\" in -D) h=$2; shift;; -o) b=$2; shift;; esac; shift; done\n\
             printf 'HTTP/1.1 403 Forbidden\\r\\nSet-Cookie: sid=raw-secret\\r\\nserver: edge\\r\\n\\r\\n' > \"$h\"\n\
             printf 'refused' > \"$b\"\n\
             { dirname \"$h\"; ls -ld \"$(dirname \"$h\")\" \"$h\"; } > \"$PROBE_LOG\"\nprintf 403\n",
        )
        .unwrap();
    std::fs::set_permissions(&curl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mark = probe_mark();
    let out = cmux_process::Command::new("sh")
        .arg("-c")
        .arg(probe_command(&mark))
        .env("PATH", format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default()))
        .env("PROBE_LOG", &log)
        .output()
        .unwrap();
    let out = String::from_utf8_lossy(&out.stdout).into_owned();
    let seen = std::fs::read_to_string(&log).unwrap();
    std::fs::remove_dir_all(&bin).unwrap();
    let mut lines = seen.lines();
    let dir = lines.next().unwrap();
    let modes: Vec<&str> = lines.map(|l| l.split_whitespace().next().unwrap_or("")).collect();
    assert_eq!(modes, ["drwx------", "-rw-------"], "{seen}");
    assert!(!std::path::Path::new(dir).exists(), "{dir} was left behind");
    assert!(out.starts_with("403\n"), "{out}");
    let shown = shown_answer(&out, &mark);
    assert!(
        !shown.contains("raw-secret")
            && shown.contains("server: edge")
            && shown.contains("refused"),
        "{shown}"
    );
}

#[test]
fn parses_the_machine_and_path() {
    let none = |_: &str| None;
    let o = parse(
        &args(&[
            "--machine",
            "vm_abcdefghij0123456789",
            "--api",
            "https://api.cmux.dev",
            "--path",
            "device",
        ]),
        &none,
    )
    .unwrap();
    assert_eq!((o.path, o.machine.as_str()), (PathChoice::Device, "vm_abcdefghij0123456789"));
    assert_eq!(o.token, TokenSource::App);
    assert_eq!(o.gateway, None);
    let o = parse(
        &args(&[
            "--machine",
            "vm_abcdefghij0123456789",
            "--api",
            "https://api.cmux.dev",
            "--gateway-machine",
            "vm_gateway0000000000000",
            "--upstream",
            "http://127.0.0.1:8317",
        ]),
        &none,
    )
    .unwrap();
    assert_eq!(o.gateway.map(|g| g.upstream), Some("http://127.0.0.1:8317".to_owned()));
    let quoted = [
        "--machine",
        "vm_abcdefghij0123456789",
        "--api",
        "https://a.dev",
        "--gateway-machine",
        "vm_gateway0000000000000",
        "--upstream",
        "http://x/'y",
    ];
    assert!(parse(&args(&quoted), &none).is_err());
    let userinfo = quoted.map(|a| if a == "http://x/'y" { "https://u:secret@x" } else { a });
    assert!(parse(&args(&userinfo), &none).is_err());
    assert!(
        parse(
            &args(&[
                "--machine",
                "vm_abcdefghij0123456789",
                "--api",
                "https://a.dev",
                "--upstream",
                "http://x"
            ]),
            &none
        )
        .is_err()
    );
    assert!(parse(&args(&["--api", "https://a.dev"]), &none).is_err());
    // Through the dispatch, --machine stays setup's own: the global scan once took it (gateway-e2e run 42363310378).
    let rest = setup_args(&args(&[
        "inference",
        "setup",
        "--machine",
        "vm_0123456789abcdefghij",
        "--api",
        "https://a.dev",
    ]))
    .expect("inference setup");
    assert_eq!(rest, args(&["--machine", "vm_0123456789abcdefghij", "--api", "https://a.dev"]));
    assert!(parse(&rest, &none).is_ok());
    assert!(
        setup_args(&args(&["inference", "gateway", "--machine", "vm_0123456789abcdefghij"]))
            .is_none()
    );
    assert!(parse(&args(&["--machine", "vm_x", "--api", "https://a.dev"]), &none).is_err());
    assert!(
        parse(
            &args(&[
                "--machine",
                "vm_abcdefghij0123456789",
                "--api",
                "https://a.dev",
                "--path",
                "x"
            ]),
            &none
        )
        .is_err()
    );
}

#[test]
fn finds_codex_device_link_and_code() {
    let log = "Welcome to Codex\n\nFollow these steps to sign in with ChatGPT using device code authorization:\n\n\
                   1. Open this link in your browser and sign in to your account\n   \u{1b}[94mhttps://auth.openai.com/codex/device\u{1b}[0m\n\n\
                   2. Enter this one-time code \u{1b}[90m(expires in 15 minutes)\u{1b}[0m\n   \u{1b}[94mABCD-EF12\u{1b}[0m\n";
    assert_eq!(
        device_prompt(log),
        Some(("https://auth.openai.com/codex/device".to_owned(), "ABCD-EF12".to_owned()))
    );
    assert_eq!(device_prompt("starting...\n"), None);
    assert_eq!(device_prompt("https://auth.openai.com/codex/device\n"), None);
}
