//! Workspace name provenance flags (hq#1957): `workspace rename` takes the
//! tab rename flags exactly, and `--release-to-auto` hands a pinned name back.

use super::*;

const WORKSPACE: &str = "ws_00000000000000000000000000000007";

#[test]
fn workspace_rename_takes_the_tab_name_source_flags() {
    for source in ["user", "auto"] {
        for revision in ["0", "18446744073709551615"] {
            let plan = protocol(&[
                "workspace",
                WORKSPACE,
                "rename",
                "--name",
                "logs",
                "--source",
                source,
                "--expected-generation",
                "daemon",
                "--expected-name-revision",
                revision,
            ]);
            assert_eq!(operation(&plan), "workspace.rename");
            assert_eq!(plan.params["source"], source);
            assert_eq!(plan.params["expected_generation"], "daemon");
            assert_eq!(plan.params["expected_name_revision"], revision);
        }
    }
    for invalid in ["", "01", "-1", "+1", "18446744073709551616"] {
        let args = [
            "workspace",
            WORKSPACE,
            "rename",
            "--name",
            "logs",
            "--expected-name-revision",
            invalid,
        ];
        assert!(
            parse(&strings(&args), super::super::super::Surface::CmuxTui).is_err(),
            "accepted invalid revision {invalid:?}"
        );
    }
    for invalid in ["", "process", "USER"] {
        let args = ["workspace", WORKSPACE, "rename", "--name", "logs", "--source", invalid];
        assert!(
            parse(&strings(&args), super::super::super::Surface::CmuxTui).is_err(),
            "accepted invalid source {invalid:?}"
        );
    }
}

/// `workspace rename --release-to-auto` hands a pinned name back to the
/// automatic namer: no name and no expected revision.
#[test]
fn workspace_rename_release_to_auto_needs_no_name() {
    let plan = protocol(&["workspace", WORKSPACE, "rename", "--release-to-auto"]);
    assert_eq!(operation(&plan), "workspace.rename");
    assert_eq!(plan.params["source"], "auto");
    assert_eq!(plan.params["release"], true);
    assert!(plan.params.get("name").is_none(), "{:?}", plan.params);

    let current = protocol(&["workspace", "rename", "--release-to-auto"]);
    assert_eq!(current.params["release"], true);

    for invalid in [
        vec!["workspace", WORKSPACE, "rename", "--release-to-auto", "--source", "user"],
        vec!["workspace", WORKSPACE, "rename", "--release-to-auto", "--name", "Billing"],
        vec!["tab", "tab_00000000000000000000000000000007", "rename", "--release-to-auto"],
        vec!["workspace", WORKSPACE, "rename"],
    ] {
        assert!(
            parse(&strings(&invalid), super::super::super::Surface::CmuxTui).is_err(),
            "accepted {invalid:?}"
        );
    }
}
