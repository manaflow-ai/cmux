//! Ported from the Swift `UpdateInstallCheckTests.aLaunchOnTheOldBuildIsAFailedInstall`.

mod updater_core_install_check {
    use cmux_updater_core::install_check::{InstallOutcome, MAX_AGE, outcome};

    const START: f64 = 1_800_000_000.0;

    #[test]
    fn a_launch_on_the_old_build_is_a_failed_install() {
        let soon = START + 30.0;
        assert_eq!(outcome("100", "200", START, "200", soon), Some(InstallOutcome::Installed));
        assert_eq!(outcome("100", "200", START, "100", soon), Some(InstallOutcome::Failed));
        assert_eq!(
            outcome("100", "200", START, "300", soon),
            None,
            "a third build was installed by hand"
        );
        assert_eq!(outcome("100", "200", START, "100", START + MAX_AGE + 1.0), None, "stale");
        assert_eq!(
            outcome("100", "200", START, "100", START - 3600.0),
            None,
            "written in the future"
        );
        assert_eq!(
            outcome("100", "100", START, "100", soon),
            None,
            "a reinstall of the running build judges nothing"
        );
    }

    #[test]
    fn the_edges_of_the_window() {
        assert_eq!(outcome("100", "200", START, "100", START - 60.0), Some(InstallOutcome::Failed));
        assert_eq!(outcome("100", "200", START, "100", START - 61.0), None);
        assert_eq!(
            outcome("100", "200", START, "100", START + MAX_AGE),
            Some(InstallOutcome::Failed)
        );
        assert_eq!(outcome("100", "200", f64::NAN, "100", START), None);
    }
}
