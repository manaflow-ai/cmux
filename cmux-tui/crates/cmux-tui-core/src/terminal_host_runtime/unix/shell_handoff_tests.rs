//! The handoff between a prepared launch and a terminal's own launch.

use anyhow::Context as _;

use super::*;

fn launch(env: &[(&str, &str)]) -> HostLaunch {
    HostLaunch {
        endpoint: "/tmp/endpoint".into(),
        record_path: "/tmp/record.json".into(),
        term: "xterm-ghostty".into(),
        cols: 80,
        rows: 24,
        cell_pixels: (8, 16),
        scrollback: 1_000,
        cwd: Some("/tmp/work".into()),
        command: vec!["/bin/zsh".into()],
        extra_env: env.iter().map(|(key, value)| (key.to_string(), value.to_string())).collect(),
        default_colors: Default::default(),
        kitty_graphics_limits: Default::default(),
        seed: Vec::new(),
        workspace_key: "ws".into(),
    }
}

#[test]
fn a_launch_that_differs_only_in_its_own_ids_gets_them_at_handout() -> anyhow::Result<()> {
    let cold =
        launch(&[("PATH", "/bin"), ("CMUX_SURFACE_ID", "A"), ("CMUX_TUI_TERMINAL_ID", "t1")]);
    let prepared = prepare_template(&cold);
    assert!(prepared.extra_env.iter().all(|(key, _)| !is_handoff_key(key)));
    let next =
        launch(&[("PATH", "/bin"), ("CMUX_SURFACE_ID", "B"), ("CMUX_TUI_TERMINAL_ID", "t2")]);
    let handoff = Handoff::between(&prepared, &next).context("same launch but its ids")?;
    assert_eq!(
        handoff.set,
        vec![
            ("CMUX_SURFACE_ID".to_string(), "B".to_string()),
            ("CMUX_TUI_TERMINAL_ID".into(), "t2".into())
        ]
    );
    assert!(handoff.unset.is_empty());
    Ok(())
}

#[test]
fn any_other_difference_launches_cold() {
    let prepared = prepare_template(&launch(&[("PATH", "/bin")]));
    assert!(Handoff::between(&prepared, &launch(&[("PATH", "/usr/bin")])).is_none());
    let mut moved = launch(&[("PATH", "/bin")]);
    moved.cwd = Some("/tmp/elsewhere".into());
    assert!(Handoff::between(&prepared, &moved).is_none());
    let mut seeded = launch(&[("PATH", "/bin")]);
    seeded.seed = b"screen".to_vec();
    assert!(Handoff::between(&prepared, &seeded).is_none());
}

#[test]
fn the_handoff_line_round_trips_and_names_only_terminal_ids() -> anyhow::Result<()> {
    let handoff = Handoff {
        set: vec![("CMUX_SURFACE_ID".into(), "it's B\twith tab".into())],
        unset: vec!["CMUX_TAB_ID".into()],
        echo: true,
    };
    let line = handoff.encode_line();
    assert!(line.ends_with('\n') && !line.trim_end().contains('\n'));
    assert_eq!(Handoff::decode_line(line.trim_end())?, handoff);
    let forged = Handoff { set: vec![("PATH".into(), "/evil".into())], unset: vec![], echo: true };
    assert!(Handoff::decode_line(forged.encode_line().trim_end()).is_err());
    Ok(())
}
