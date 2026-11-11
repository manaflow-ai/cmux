//! `pane split --right --fit` sends `pane.split` with `fit: true` (a column that
//! shares the window); `--viewport-width` keeps sending exactly that width. The
//! fitting itself is tested in the daemon: cmux-tui-core
//! `resource_router/split_fit_tests.rs`.

use super::*;

const PANE: &str = "pane_00000000000000000000000000000006";

#[test]
fn pane_split_fit_sends_fit_and_viewport_width_keeps_its_width() {
    let catalog = operation_catalog();
    let fit = protocol(&["pane", PANE, "split", "--right", "--fit", "--focus"]);
    assert_eq!(operation(&fit), "pane.split");
    assert_eq!(fit.params["fit"], true);
    assert_eq!(fit.params["focus"], true, "--fit swallowed the next flag: {:?}", fit.params);
    assert_eq!(fit.params.get("viewport_width"), None);
    assert_plan_matches_catalog(&fit, "pane.split", &catalog);

    let wide = protocol(&["pane", PANE, "split", "--right", "--viewport-width", "0.5"]);
    assert_eq!(wide.params["viewport_width"], 0.5);
    assert_eq!(wide.params.get("fit"), None);
}

#[test]
fn pane_split_fit_refuses_a_width_a_ratio_or_another_direction() {
    for args in [
        ["pane", PANE, "split", "--right", "--fit", "--viewport-width", "0.5"].as_slice(),
        ["pane", PANE, "split", "--right", "--fit", "--ratio", "0.3"].as_slice(),
        ["pane", PANE, "split", "--down", "--fit"].as_slice(),
    ] {
        let parsed = parse(
            &args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>(),
            crate::cli::Surface::CmuxTui,
        );
        assert!(parsed.is_err(), "{args:?} was accepted");
    }
}
