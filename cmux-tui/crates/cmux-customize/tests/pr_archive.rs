//! Install the shipped setup. Only a confirmed settings change may turn archiving on.
use cmux_customize::{Customize, Roots, setup};
use std::path::Path;

#[test]
fn pr_archive_installs_confirmation_actions_for_both_rules() {
    let home = tempfile::tempdir().unwrap();
    let roots = Roots::under(home.path());
    let settings = roots.settings_file.clone();
    let customize = Customize::open(roots);
    let folder = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../examples/looks/claude-code/pr-archive");
    let setup = setup::read_dir(&folder).unwrap();
    let plan = customize.plan_setup(&setup, "manaflow-ai", "0.0.0").unwrap();
    assert!(plan.settings.is_empty());
    assert_eq!(plan.actions.len(), 2);
    customize.install_setup(&setup, "PR archive", "cli", 1).unwrap();
    let live = cmux_config::jsonc::parse(&std::fs::read_to_string(settings).unwrap()).unwrap();
    for (action, key) in [("pr-archive-on-merge", "onMerge"), ("pr-archive-on-close", "onClose")] {
        assert_eq!(
            live["actions"][action]["command"],
            format!("cmux settings set agents.autoSettle.{key} true --confirm")
        );
        assert!(live["agents"]["autoSettle"][key].is_null());
    }
}
