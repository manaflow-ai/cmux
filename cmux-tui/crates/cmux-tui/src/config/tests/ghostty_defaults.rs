//! Tests for Ghostty color, cursor and scrollback defaults parsing and resolution.

use super::*;

#[test]
fn scrollback_config_outcomes_preserve_precedence_and_timeout() {
    let dir = TestDirectory::new("scrollback-outcomes");
    let value_path = dir.path.join("value.conf");
    let empty_path = dir.path.join("empty.conf");
    let absent_path = dir.path.join("absent.conf");
    std::fs::write(&value_path, "scrollback-limit = 123_456\n").unwrap();
    std::fs::write(&empty_path, "scrollback-limit = \"\"\n").unwrap();
    std::fs::write(&absent_path, "foreground = #010203\n").unwrap();

    assert_eq!(
        parse_scrollback_limit_from_root(&value_path, Instant::now() + Duration::from_secs(1)),
        ScrollbackConfigOutcome::Parsed(Some(Some(123_456)))
    );
    assert_eq!(
        parse_scrollback_limit_from_root(&absent_path, Instant::now() + Duration::from_secs(1)),
        ScrollbackConfigOutcome::Parsed(None)
    );
    assert_eq!(
        parse_scrollback_limit_from_root(&empty_path, Instant::now() + Duration::from_secs(1)),
        ScrollbackConfigOutcome::Parsed(Some(None))
    );
    assert_eq!(
        parse_scrollback_limit_from_root(&value_path, Instant::now() - Duration::from_secs(1)),
        ScrollbackConfigOutcome::TimedOut
    );
}

#[cfg(unix)]
#[test]
fn ghostty_resolver_drains_output_while_the_child_is_running() {
    let root = std::env::temp_dir().join(format!(
        "cmux-tui-ghostty-large-output-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let binary = root.join("ghostty-config-helper");
    std::fs::create_dir_all(&root).unwrap();
    write_executable(
        &binary,
        "#!/bin/sh\n\
         i=0\n\
         while [ \"$i\" -lt 2048 ]; do\n\
           printf 'palette = 1=#010203\\n'\n\
           i=$((i + 1))\n\
         done\n\
         printf 'background = #272822\\nforeground = #fdfff1\\n'\n",
    );

    let mut command = Command::new(&binary);
    command.stdout(Stdio::piped()).stderr(Stdio::null());
    let defaults = match ghostty_defaults_from_helper_command(command, Duration::from_secs(2)) {
        GhosttyHelperDefaults::Resolved(defaults) => defaults.colors,
        GhosttyHelperDefaults::Unavailable => panic!("helper output was not parsed"),
        GhosttyHelperDefaults::TimedOut => panic!("helper output timed out"),
    };
    assert_eq!(defaults.bg, Some(Rgb { r: 0x27, g: 0x28, b: 0x22 }));
    assert_eq!(defaults.fg, Some(Rgb { r: 0xfd, g: 0xff, b: 0xf1 }));
    let _ = std::fs::remove_dir_all(root);
}
