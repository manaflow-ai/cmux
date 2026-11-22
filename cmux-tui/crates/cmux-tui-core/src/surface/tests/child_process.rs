//! Child process tests: exit status after final PTY bytes, TERM and COLORTERM
//! selection, and the integrated shell prompt across rapid resizes.

use super::*;

#[cfg(unix)]
#[test]
fn local_surface_retains_real_status_after_final_pty_bytes() {
    fn run(mux: &Arc<Mux>, id: SurfaceId, script: &str, final_text: &str) -> TerminalExit {
        let surface = Surface::spawn(
            id,
            SurfaceOptions {
                command: Some(vec!["/bin/sh".into(), "-c".into(), script.into()]),
                ..SurfaceOptions::default()
            },
            Arc::downgrade(mux),
        )
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        let exit = loop {
            if let Some(exit) = surface.terminal_exit()
                && surface.is_dead()
            {
                break exit;
            }
            assert!(Instant::now() < deadline, "local PTY did not publish its exit");
            std::thread::sleep(Duration::from_millis(5));
        };
        let text = surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
        assert!(text.contains(final_text), "exit became visible before final PTY bytes: {text:?}");
        exit
    }

    let mux = Mux::new_for_test("local-exit-status", SurfaceOptions::default());
    assert_eq!(
        run(&mux, 101, "printf final-exit; exit 17", "final-exit").outcome,
        crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 }
    );
    assert_eq!(
        run(&mux, 102, "printf final-signal; kill -TERM $$", "final-signal").outcome,
        crate::terminal_host_protocol::TerminalExitOutcome::Signal {
            signal: libc::SIGTERM,
            core_dumped: false,
        }
    );
}

/// The selection rule: pass xterm-ghostty through only when the outer
/// terminal already advertised it. Prompts that sniff the TERM name
/// then take the same branch inside cmux-tui as in the host terminal
/// (colors match), and children never get a less compatible TERM than
/// the host terminal gave the user.
#[test]
fn child_term_passes_ghostty_through_and_nothing_else() {
    assert_eq!(child_term_for(Some("xterm-ghostty")), "xterm-ghostty");
    assert_eq!(child_term_for(Some("xterm-256color")), "xterm-256color");
    assert_eq!(child_term_for(Some("screen")), "xterm-256color");
    assert_eq!(child_term_for(Some("alacritty")), "xterm-256color");
    assert_eq!(child_term_for(Some("")), "xterm-256color");
    assert_eq!(child_term_for(None), "xterm-256color");
}

/// default_child_term composes the rule with this process's real TERM
/// and must agree with it.
#[test]
fn default_child_term_matches_selection_rule() {
    let outer = std::env::var("TERM").ok();
    assert_eq!(default_child_term(), child_term_for(outer.as_deref()));
}

#[cfg(unix)]
fn spawn_and_read_colorterm(id: SurfaceId, extra_env: Vec<(String, String)>) -> String {
    let mux = Mux::new_for_test("colorterm-env", SurfaceOptions::default());
    let surface = Surface::spawn(
        id,
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".into(),
                "-c".into(),
                "printf 'CT=[%s]' \"$COLORTERM\"".into(),
            ]),
            extra_env,
            ..SurfaceOptions::default()
        },
        Arc::downgrade(&mux),
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let text = surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
        if let Some(start) = text.find("CT=[")
            && let Some(len) = text[start..].find(']')
        {
            return text[start..=start + len].to_string();
        }
        assert!(Instant::now() < deadline, "child never printed COLORTERM: {text:?}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// A shell program on PATH that shell integration supports, if any.
#[cfg(unix)]
fn find_integrated_shell(name: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .filter(|candidate| {
            // Apple's /bin/bash 3.2 cannot run the bash injection.
            !(cfg!(target_os = "macos") && candidate == std::path::Path::new("/bin/bash"))
        })
        .find(|candidate| candidate.is_file())
        .map(|candidate| candidate.to_string_lossy().into_owned())
}

#[cfg(unix)]
fn wait_for_viewport(
    surface: &Surface,
    what: &str,
    mut ready: impl FnMut(&str, bool) -> bool,
) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let (text, at_prompt) = surface
            .try_with_terminal(|terminal| {
                let text = terminal.viewport_text();
                (text, terminal.cursor_is_at_prompt())
            })
            .unwrap();
        let text = text.unwrap();
        if ready(&text, at_prompt) {
            return text;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}: {text:?}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// The default shell runs with Ghostty's shell integration, so its prompt
/// carries OSC 133 marks. Without them, a partial output line before the
/// prompt (zsh PROMPT_SP, or any output without a trailing newline) is
/// reflowed together with the prompt on every resize, and each SIGWINCH
/// redraw leaves fragments of the previous prompt behind. This is the
/// resize artifact seen in Cloud terminals.
#[cfg(unix)]
#[test]
#[cfg_attr(
    target_os = "macos",
    ignore = "zsh loses the partial line on macOS on feat-cmux-next too: #16644"
)]
fn default_shell_prompt_survives_rapid_resizes_after_a_partial_line() {
    let mut ran = 0;
    for (index, shell) in ["zsh", "bash"].into_iter().enumerate() {
        let Some(program) = find_integrated_shell(shell) else { continue };
        let home = std::env::temp_dir().join(format!(
            "cmux-tui-prompt-resize-{}-{shell}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(home.join(".zshenv"), "setopt NO_GLOBAL_RCS\n").unwrap();
        std::fs::write(home.join(".zshrc"), "PS1='prompt> '\nsetopt PROMPT_CR PROMPT_SP\n")
            .unwrap();
        std::fs::write(home.join(".bashrc"), "PS1='prompt> '\n").unwrap();
        let launch = crate::shell_integration::integrate_default_shell(
            vec![program],
            vec![
                ("HOME".into(), home.to_string_lossy().into_owned()),
                ("ZDOTDIR".into(), home.to_string_lossy().into_owned()),
                ("HISTFILE".into(), home.join("history").to_string_lossy().into_owned()),
            ],
        );
        let mux = Mux::new_for_test("prompt-resize", SurfaceOptions::default());
        let surface = Surface::spawn(
            160 + index as SurfaceId,
            SurfaceOptions {
                command: Some(launch.command),
                extra_env: launch.env,
                cols: 60,
                rows: 20,
                ..SurfaceOptions::default()
            },
            Arc::downgrade(&mux),
        )
        .unwrap();
        wait_for_viewport(&surface, "the first prompt", |text, _| text.contains("prompt>"));
        // Output without a trailing newline, then unsubmitted input.
        surface.write_bytes(b"printf ghtly\r").unwrap();
        wait_for_viewport(&surface, "the prompt after the partial line", |text, _| {
            text.matches("prompt>").count() >= 2
        });
        surface.write_bytes(b"nightly").unwrap();
        wait_for_viewport(&surface, "typed input", |text, _| text.contains("prompt> nightly"));
        for step in 0..40u16 {
            let cols = if step % 2 == 0 { 60 - step } else { 30 + step };
            surface.resize(cols, 20).unwrap();
            std::thread::sleep(Duration::from_millis(5));
        }
        surface.resize(60, 20).unwrap();
        // Wait for the shell's post-resize redraws to settle: the prompt
        // text already matched before the resizes started.
        let mut previous = String::new();
        let mut stable_reads = 0;
        let text = wait_for_viewport(&surface, "the settled prompt", |text, _| {
            if text == previous {
                stable_reads += 1;
            } else {
                previous = text.to_string();
                stable_reads = 0;
            }
            std::thread::sleep(Duration::from_millis(100));
            stable_reads >= 5 && text.contains("prompt> nightly")
        });
        let at_prompt =
            surface.try_with_terminal(|terminal| terminal.cursor_is_at_prompt()).unwrap();
        assert_eq!(
            text.matches("nightly").count(),
            1,
            "{shell}: resizing left prompt fragments behind: {text:?}"
        );
        assert_eq!(
            text.matches("prompt>").count(),
            2,
            "{shell}: resizing duplicated the prompt: {text:?}"
        );
        assert!(
            text.lines().any(|line| line.starts_with("ghtly")),
            "{shell}: resizing erased the partial output line: {text:?}"
        );
        assert!(at_prompt, "{shell}: the terminal never saw an OSC 133 prompt mark: {text:?}");
        drop(surface);
        let _ = std::fs::remove_dir_all(&home);
        ran += 1;
    }
    assert!(ran > 0, "neither zsh nor bash is installed");
}

/// The embedded ghostty-vt terminal always parses 24-bit SGR and the
/// frontends forward RGB cells losslessly, so children must be able to
/// rely on truecolor even when the session server itself was started from
/// an environment without COLORTERM (launchd, ssh, cron). Without the
/// guarantee, truecolor-capable programs quantize to the 256-color cube
/// and render visibly different colors than the same program run directly
/// in the host terminal.
#[cfg(unix)]
#[test]
fn child_env_advertises_truecolor_colorterm() {
    assert_eq!(spawn_and_read_colorterm(151, Vec::new()), "CT=[truecolor]");
}

/// extra_env stays authoritative: a caller that sets COLORTERM explicitly
/// wins over the built-in truecolor advertisement.
#[cfg(unix)]
#[test]
fn child_env_colorterm_yields_to_extra_env() {
    assert_eq!(
        spawn_and_read_colorterm(152, vec![("COLORTERM".into(), "24bit".into())]),
        "CT=[24bit]"
    );
}
