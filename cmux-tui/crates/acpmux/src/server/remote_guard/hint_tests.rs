use super::*;

fn start() -> Start {
    Start::of(&json!({
        "cwd": "/home/cmux/hb-acpmux/x",
        "_meta": {"acpmux": {"harness": "codex", "model": "gpt-6", "name": "lane", "policy": "approve-all", "mode": "auto"}}
    }))
}

#[test]
fn a_start_is_spelled_as_the_flags_that_make_it() {
    assert_eq!(
        start().command(Some("gcp-1")),
        "acpmux new --machine gcp-1 -m codex/gpt-6 -n lane --cwd /home/cmux/hb-acpmux/x --policy approve-all --mode auto -d"
    );
    let odd = Start { cwd: Some("/tmp/a b/it's".into()), ..Start::default() };
    assert_eq!(odd.command(None), r"acpmux new --cwd '/tmp/a b/it'\''s' -d");
}

/// A refusal reads `refused by HOST: REASON` on its first line and again on its last, so a
/// caller piping through `tail -1` sees it failed, not only the end of a multi-line command.
#[test]
fn a_refusal_says_refused_by_its_host_first_and_last() {
    let command = "printf %s 'line one\nline two' | (ssh -- vm 'acpmux new -d')";
    let message = refused_by("vm", "a permission policy other than ask", command);
    let lines: Vec<&str> = message.lines().collect();
    assert_eq!(
        lines.first().copied(),
        Some("refused by vm: a permission policy other than ask; nothing was started. Instead:")
    );
    assert_eq!(lines[1..lines.len() - 1].join("\n"), command);
    assert_eq!(
        lines.last().copied(),
        Some("refused by vm: nothing was started; the command above runs it")
    );
}

fn peer(try_cwd: Option<&str>) -> Found<'_> {
    Found { served: Some("peer"), try_cwd, cause: None }
}

#[test]
fn each_refusal_suggests_a_start_the_peer_takes() {
    let s = start();
    // From a peer that serves us as a peer: the folder it checked, or none; never a mode.
    let Hint::Here(next) = suggest(&s, CWD_OUTSIDE_ROOTS, peer(Some("/home/cmux/Projects/x")))
    else {
        panic!()
    };
    assert_eq!(next.cwd.as_deref(), Some("/home/cmux/Projects/x"));
    assert_eq!(next.mode, None);
    let Hint::Here(next) = suggest(&s, CWD_OUTSIDE_ROOTS, peer(None)) else { panic!() };
    assert_eq!(next.cwd, None);
    let Hint::Here(next) = suggest(&s, MODE_REFUSED, peer(None)) else { panic!() };
    assert_eq!((next.mode, next.policy.as_deref()), (None, Some("approve-all")));
    // A policy it refused, or anything from a peer that serves us as Web: on the host,
    // its folder made first, with no mode.
    assert!(matches!(suggest(&s, POLICY_REFUSED, peer(None)), Hint::OnHost(_)));
    let web = |cause| Found { served: Some("remote"), cause, ..Found::default() };
    let Hint::OnHost(next) = suggest(&s, CWD_MISSING, web(Some("missing"))) else { panic!() };
    assert_eq!(
        next.on_host_command(),
        "mkdir -p /home/cmux/hb-acpmux/x && acpmux new -m codex/gpt-6 -n lane --cwd /home/cmux/hb-acpmux/x --policy approve-all -d"
    );
    // A path no `mkdir -p` makes (a file, a link) is left out.
    for cause in [Some("unusable"), None] {
        let Hint::OnHost(next) = suggest(&s, CWD_MISSING, web(cause)) else { panic!() };
        assert_eq!(next.cwd, None, "{cause:?}");
    }
    // An older peer checked the mode before the folder: on the host, in the shell's folder.
    for reason in [MODE_REFUSED, POLICY_REFUSED, CWD_OUTSIDE_ROOTS] {
        let Hint::OnHost(next) = suggest(&s, reason, Found::default()) else { panic!() };
        assert_eq!((next.cwd, next.mode), (None, None), "{reason}");
    }
}

#[test]
fn a_start_on_the_host_goes_through_ssh_only_for_an_ssh_peer() {
    let inner = "mkdir -p /x && acpmux new -d";
    assert_eq!(
        on_host(Some("leo@huge-blue"), inner),
        "ssh -- leo@huge-blue 'mkdir -p /x && acpmux new -d'"
    );
    assert_eq!(on_host(None, inner), inner);
}

#[test]
fn original_argv_keeps_prompts_launcher_flags_and_quotes_shell_input() {
    let params = json!({
        "_meta": {"acpmux": {
            "argv": ["new", "--host", "b", "-m", "codex", "--prompt-file", "brief.md",
                     "--tag", "a=$()", "a prompt with 'quotes' and\nnewlines"],
            "promptFileText": "line 1; $(touch nope)\nline 'two'"
        }},
        "cwd": "/remote/project"
    });
    let start = Start { cwd: Some("/remote/project".into()), ..Start::default() };
    let got = command(&params, &start, Some("b"), false).render(None);
    assert_eq!(
        got,
        r#"printf %s 'line 1; $(touch nope)
line '\''two'\''' | (acpmux new --machine=b -m codex --prompt-file=/dev/stdin --tag 'a=$()' 'a prompt with '\''quotes'\'' and
newlines')"#
    );
}

#[test]
fn option_rewrites_do_not_touch_values_or_prompt_words() {
    let mut words: Vec<String> = [
        "new",
        "--name",
        "--host=x",
        "-m--cwd",
        "--host",
        "auto",
        "--mode=yolo",
        "--cwd=/bad",
        "--",
        "--host",
        "prompt",
        "--mode=yolo",
        "--cwd=/bad",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    assert!(change_option(&mut words, "--host", Some("b")));
    assert!(change_option(&mut words, "--mode", None));
    assert!(change_option(&mut words, "--cwd", None));
    assert_eq!(
        words,
        [
            "new",
            "--name",
            "--host=x",
            "-m--cwd",
            "--host=b",
            "--",
            "--host",
            "prompt",
            "--mode=yolo",
            "--cwd=/bad"
        ]
    );
}

/// `--machine` and its old spelling `--host` are one option: either is replaced, value and all.
#[test]
fn option_rewrites_take_machine_and_its_host_alias_as_one() {
    for given in [["--machine", "auto"], ["--host", "auto"]] {
        let mut words: Vec<String> = ["new", given[0], given[1], "-m", "codex", "hi"]
            .into_iter()
            .map(str::to_owned)
            .collect();
        assert!(change_option(&mut words, "--host", Some("b")), "{given:?}");
        assert_eq!(words, ["new", "--host=b", "-m", "codex", "hi"], "{given:?}");
    }
    let mut words: Vec<String> =
        ["new", "--machine=x", "hi"].into_iter().map(str::to_owned).collect();
    assert!(change_option(&mut words, "--host", None));
    assert_eq!(words, ["new", "hi"]);
}

/// A full-access refusal's way out names `--policy` after the subcommand, also when a global
/// switch comes first (`acpmux --json new ...`).
#[test]
fn try_asking_puts_the_policy_after_the_subcommand() {
    let refused =
        || RpcError::invalid_params("refused").with_data(json!({"fullAccessRefusedBy": "b"}));
    for (argv, want) in [
        (
            json!(["--json", "new", "--machine", "b", "-d", "hi"]),
            "acpmux --json new --policy=ask --machine=b -d hi",
        ),
        (json!(["new", "--machine=b", "hi"]), "acpmux new --policy=ask --machine=b hi"),
        (
            json!(["new", "--policy", "approve-all", "--machine=b", "hi"]),
            "acpmux new --policy=ask --machine=b hi",
        ),
    ] {
        let params = json!({"_meta": {"acpmux": {"argv": argv}}});
        let e = try_asking("b", &params, refused());
        assert_eq!(e.data.as_ref().unwrap()["try"], want, "{argv}");
    }
    // Any other refusal is left as it was.
    let other = RpcError::invalid_params("other");
    assert!(try_asking("b", &json!({}), other).data.is_none());
}

#[test]
#[cfg(unix)]
fn pasted_ssh_command_preserves_every_argument_and_prompt_file_byte() {
    let dir = std::env::temp_dir().join(format!("acpmux-hint-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir(&dir).unwrap();
    for (name, script) in [
        ("ssh", "#!/bin/sh\n[ \"$1\" = -- ] || exit 9\nshift 2\nexec /bin/sh -c \"$1\"\n"),
        ("acpmux", "#!/bin/sh\nprintf '%s\\0' \"$@\"\ncat\n"),
    ] {
        crate::test_exec::write_executable(dir.join(name), script);
    }
    let prompt = "'quoted' \"double\" $HOME $(exit 99) `exit 98`\nsecond line";
    let file =
        format!("{}file's text $HOME $(exit 97)\ntrailing newline\n", "a".repeat((1 << 20) - 100));
    let file = file.as_str();
    let argv = json!([
        "--json",
        "new",
        "--host=b",
        "-n",
        "demo",
        "-m",
        "codex",
        "-e",
        "xhigh",
        "--policy",
        "approve-all",
        "--prompt-file=brief with spaces.md",
        "--tag",
        "a=b",
        "--worktree",
        "repo@main",
        "--report-to",
        "boss",
        "-d",
        "--",
        prompt,
        "--host",
        "--mode"
    ]);
    let params = json!({"_meta":{"acpmux":{"argv":argv,"promptFileText":file}}});
    let start =
        Start { cwd: Some(dir.join("project").to_string_lossy().into_owned()), ..Start::default() };
    let inner = command(&params, &start, None, true);
    for ssh in [Some("example-host"), None] {
        let tried = inner.render(ssh);
        let path = format!("{}:{}", dir.display(), std::env::var("PATH").unwrap());
        use std::io::Write;
        use std::process::Stdio;
        let mut shell = std::process::Command::new("sh")
            .env("PATH", path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        shell.stdin.take().unwrap().write_all(format!("{tried}\n").as_bytes()).unwrap();
        let output = shell.wait_with_output().unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let output = String::from_utf8(output.stdout).unwrap();
        let actual: Vec<_> = output.split('\0').collect();
        assert_eq!(
            actual,
            [
                "--json",
                "new",
                "-n",
                "demo",
                "-m",
                "codex",
                "-e",
                "xhigh",
                "--policy",
                "approve-all",
                "--prompt-file=/dev/stdin",
                "--tag",
                "a=b",
                "--worktree",
                "repo@main",
                "--report-to",
                "boss",
                "-d",
                "--",
                prompt,
                "--host",
                "--mode",
                file
            ]
        );
    }
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn an_older_peers_refusal_is_known_by_its_message() {
    let e = |m: &str| RpcError::invalid_params(m);
    assert_eq!(
        reason_of(&e(
            "a mode at session start is accepted only from the local app or the unix socket, never from a remote WebSocket connection"
        )),
        Some(MODE_REFUSED.to_owned())
    );
    assert_eq!(
        reason_of(&e(
            "cwd is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder"
        )),
        Some(CWD_OUTSIDE_ROOTS.to_owned())
    );
    assert_eq!(reason_of(&e("no peer \"x\"")), None);
    let other = e("x").with_data(json!({"reason": "trust.remote"}));
    assert_eq!(reason_of(&other), None);
}

/// `acpmux new --host H -m claude hi` with no --cwd, refused by a peer from before the
/// peer scratch folder: the way out is `acpmux host update H --if-idle`, then the same command.
#[test]
fn an_older_peer_refusing_a_start_with_no_folder_names_the_update() {
    let refused = || {
        RpcError::invalid_params(
            "cwd is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder",
        )
    };
    let argv = json!(["new", "--host", "gcp-codex-lane-1", "-m", "claude", "hi"]);
    let params = json!({"_meta": {"acpmux": {"harness": "claude", "argv": argv}}});
    let old = Some("972843ddd 2026-10-22");
    let e =
        update_first(&refused(), "gcp-codex-lane-1", old, true, &params).expect("an update hint");
    let data = e.data.clone().unwrap();
    assert_eq!(data["reason"], "peer_version_skew");
    assert_eq!(data["refused"], CWD_OUTSIDE_ROOTS);
    assert_eq!(data["try"], "acpmux machine update gcp-codex-lane-1 --if-idle");
    assert_eq!(data["then"], "acpmux new --machine=gcp-codex-lane-1 -m claude hi");
    assert!(e.message.contains("972843ddd"), "{}", e.message);
    let update = "`acpmux machine update gcp-codex-lane-1 --if-idle`";
    assert!(e.message.contains(update), "{}", e.message);
    // A folder named, a peer that says how it served us, or one of this build: as before.
    let named = json!({"cwd": "/tmp/x", "_meta": {"acpmux": {"argv": argv}}});
    assert!(update_first(&refused(), "gcp-codex-lane-1", old, true, &named).is_none());
    let told = refused().with_data(json!({"reason": CWD_OUTSIDE_ROOTS, "servedAs": "remote"}));
    assert!(update_first(&told, "gcp-codex-lane-1", old, true, &params).is_none());
    let same = Some(crate::hub::build());
    assert!(update_first(&refused(), "gcp-codex-lane-1", same, true, &params).is_none());
    // A peer that serves this daemon as Web refuses no folder on any build: no update hint.
    assert!(update_first(&refused(), "gcp-codex-lane-1", old, false, &params).is_none());
}

/// A start this daemon forwards for a Web client keeps Web rules on the peer after any
/// update, so `new_on` passes it as not served as a peer: no update hint for it.
#[test]
fn a_start_forwarded_for_web_gets_no_update_hint() {
    let web = json!({"_meta": {"acpmux": {"harness": "claude", "via": "web"}}});
    assert!(via_web(&web));
    for p in [json!({"_meta": {"acpmux": {"via": "app"}}}), json!({"_meta": {"acpmux": {}}})] {
        assert!(!via_web(&p), "{p}");
    }
}
