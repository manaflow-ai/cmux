/// Each raw line through one session's stream into its tail, as `Inbound::Stderr` does.
fn feed(lines: &[String]) -> Vec<String> {
    let mut stream = crate::hub::session::SessionStderr::default();
    let mut tail = std::collections::VecDeque::new();
    for line in lines {
        super::remember_stderr(
            &mut tail,
            &stream.clean_line((1, crate::agent::StderrPipe::Stderr), line),
        );
    }
    tail.into_iter().collect()
}

#[test]
fn a_long_payload_neither_grows_the_tail_nor_hides_later_lines() {
    let mut lines = vec!["\x1bPstart".to_owned()];
    lines.extend(std::iter::repeat_n("A".repeat(4096), 1000));
    lines.push(format!("{}\x1b\\", "B".repeat(5000)));
    lines.push("error: request timed out".to_owned());
    assert_eq!(feed(&lines), vec!["error: request timed out"]);
}

#[test]
fn a_long_line_keeps_the_control_it_ends_in() {
    // The opener sits past where the tail cuts a line: the lines after it are still payload.
    let lines = [
        format!("{} \x1b]8;;https://x", "w".repeat(4100)),
        "leaked payload".to_owned(),
        "end\x07error: request timed out".to_owned(),
    ];
    let tail = feed(&lines);
    assert!(tail.iter().all(|line| !line.contains("leaked")), "{tail:?}");
    assert_eq!(tail.last().map(String::as_str), Some("error: request timed out"));
    // A DCS closed and an OSC opened late in a long line: a BEL on the next line ends the OSC.
    let lines = [
        format!("\x1bP{}\x1b\\\x1b]title", "d".repeat(5000)),
        "\x07error: request timed out".to_owned(),
    ];
    assert_eq!(feed(&lines), vec!["error: request timed out"]);
}

#[test]
fn a_turn_boundary_keeps_the_open_control() {
    // The tail is cleared at each turn; the stream is not, so a payload that runs into the
    // next turn stays hidden.
    let mut stream = crate::hub::session::SessionStderr::default();
    let mut tail = std::collections::VecDeque::new();
    super::remember_stderr(
        &mut tail,
        &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "\x1bPsecret"),
    );
    tail.clear();
    super::remember_stderr(
        &mut tail,
        &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "leaked payload"),
    );
    super::remember_stderr(
        &mut tail,
        &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "\x1b\\error: request timed out"),
    );
    assert_eq!(tail.into_iter().collect::<Vec<_>>(), vec!["error: request timed out"]);
}

#[test]
fn an_old_agents_late_line_keeps_its_open_control_however_many_agents_followed() {
    let mut stream = crate::hub::session::SessionStderr::default();
    let mut tail = std::collections::VecDeque::new();
    super::remember_stderr(
        &mut tail,
        &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "\x1bPsecret"),
    );
    for generation in 2..10 {
        super::remember_stderr(
            &mut tail,
            &stream.clean_line((generation, crate::agent::StderrPipe::Stderr), "ok"),
        );
    }
    super::remember_stderr(
        &mut tail,
        &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "late payload"),
    );
    assert!(tail.iter().all(|line| !line.contains("payload")), "{tail:?}");
    // Its open control lasts until its own terminator, even after it exited.
    assert_eq!(stream.clean_line((1, crate::agent::StderrPipe::Stderr), "\x1b\\done"), "done");
}

#[test]
fn many_agents_left_inside_a_control_never_free_an_older_ones_state() {
    let mut stream = crate::hub::session::SessionStderr::default();
    let err = |generation| (generation, crate::agent::StderrPipe::Stderr);
    for generation in 1..200 {
        assert_eq!(stream.clean_line(err(generation), "\x1bPsecret"), "");
    }
    assert_eq!(stream.clean_line(err(1), "late payload"), "");
    assert_eq!(stream.clean_line(err(1), "\x1b\\shown"), "shown");
}

#[test]
fn an_agents_stdout_notes_are_their_own_stream() {
    let mut stream = crate::hub::session::SessionStderr::default();
    let out = (1, crate::agent::StderrPipe::Stdout);
    let err = (1, crate::agent::StderrPipe::Stderr);
    assert_eq!(stream.clean_line(out, "[non-json stdout] \x1bPsecret"), "[non-json stdout]");
    assert_eq!(stream.clean_line(err, "error: on stderr"), "error: on stderr");
    assert_eq!(stream.clean_line(out, "[non-json stdout] more payload"), "");
    assert_eq!(stream.clean_line(out, "[non-json stdout] \x1b\\shown"), "shown");
}

#[test]
fn a_new_agent_starts_a_new_stream() {
    // The old agent left a control open; the agent that replaced it starts clean, and a late
    // line of the old one stays in the old one's stream.
    let mut stream = crate::hub::session::SessionStderr::default();
    let mut tail = std::collections::VecDeque::new();
    super::remember_stderr(
        &mut tail,
        &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "\x1bPsecret"),
    );
    super::remember_stderr(
        &mut tail,
        &stream.clean_line((2, crate::agent::StderrPipe::Stderr), "error: request timed out"),
    );
    super::remember_stderr(
        &mut tail,
        &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "late payload"),
    );
    assert_eq!(tail.into_iter().collect::<Vec<_>>(), vec!["error: request timed out"]);
}

#[test]
fn stderr_resets_do_not_evict_the_explanation() {
    let mut lines = vec!["\x1b[31mERROR failed to refresh models\x1b[0m".to_owned()];
    lines.extend(std::iter::repeat_n("\x1b[0m".to_owned(), 8));
    assert_eq!(feed(&lines), vec!["failed to refresh models"]);
}
