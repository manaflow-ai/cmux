//! Name provenance shared by tab and workspace renames (hq#1957).

use serde_json::{Map, Value, json};

use super::{NameSource, NameUpdate, WorkspaceNameUpdate};
use crate::resource::{
    ContentPublicId, PanePublicId, ResourceError, TabPublicId, TerminalPublicId, WorkspacePublicId,
};
use crate::workspace_registry::{RegistryTab, RegistryWorkspace};

const GENERATION: &str = "generation-a";

fn workspace(name: &str, source: NameSource, revision: u64) -> RegistryWorkspace {
    RegistryWorkspace {
        id: 1,
        public_id: WorkspacePublicId::parse(format!("ws_{:032x}", 1)).unwrap(),
        key: "00000000-0000-4000-8000-000000000001".into(),
        name: name.into(),
        name_source: source,
        name_revision: revision,
        group_key: "default".into(),
    }
}

fn fields(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

fn auto(revision: u64) -> WorkspaceNameUpdate {
    NameUpdate::parse(&fields(json!({
        "source":"auto",
        "expected_generation":GENERATION,
        "expected_name_revision":revision.to_string(),
    })))
    .unwrap()
}

fn resource_code(error: &anyhow::Error) -> Option<&str> {
    error.downcast_ref::<ResourceError>().map(|error| error.code.as_str())
}

#[test]
fn workspace_name_source_auto_requires_generation_and_revision() {
    for missing in [
        json!({"source":"auto"}),
        json!({"source":"auto","expected_generation":GENERATION}),
        json!({"source":"auto","expected_name_revision":"0"}),
    ] {
        let error = NameUpdate::parse(&fields(missing.clone())).err().unwrap();
        assert_eq!(resource_code(&error), Some("validation.invalid"), "{missing}");
    }
    assert!(NameUpdate::new(Some(NameSource::Auto), None, Some(0)).is_err());
    assert!(NameUpdate::parse(&fields(json!({"source":"process"}))).is_err());
    assert!(NameUpdate::parse(&fields(json!({"expected_name_revision":"x"}))).is_err());
    let plain = NameUpdate::parse(&fields(json!({}))).unwrap();
    assert_eq!(plain.source(), NameSource::User);
    assert!(plain.fingerprint().is_none(), "a legacy rename keeps its old fingerprint");
    assert!(auto(0).fingerprint().is_some());
}

#[test]
fn workspace_name_source_user_rename_pins_and_bumps_revision() {
    let mut target = workspace("workspace-1", NameSource::Auto, 4);
    NameUpdate::user().apply_workspace(&mut target, "Billing".into(), GENERATION).unwrap();
    assert_eq!(target.name, "Billing");
    assert_eq!(target.name_source, NameSource::User);
    assert_eq!(target.name_revision, 5);
    // Renaming to the same text still pins it and advances the revision.
    NameUpdate::user().apply_workspace(&mut target, "Billing".into(), GENERATION).unwrap();
    assert_eq!(target.name_revision, 6);
}

#[test]
fn workspace_name_source_auto_replaces_only_an_auto_name() {
    let mut automatic = workspace("workspace-1", NameSource::Auto, 2);
    auto(2).apply_workspace(&mut automatic, "Fix Login".into(), GENERATION).unwrap();
    assert_eq!(automatic.name, "Fix Login");
    assert_eq!(automatic.name_source, NameSource::Auto);
    assert_eq!(automatic.name_revision, 3);

    let mut pinned = workspace("Billing", NameSource::User, 7);
    let before = pinned.clone();
    assert!(auto(7).apply_workspace(&mut pinned, "Fix Login".into(), GENERATION).is_err());
    assert_eq!(pinned, before, "a refused rename changes nothing");

    // An emptied user name hands the workspace back to the automatic namer.
    let mut emptied = workspace("", NameSource::User, 1);
    auto(1).apply_workspace(&mut emptied, "Fix Login".into(), GENERATION).unwrap();
    assert_eq!(emptied.name_source, NameSource::Auto);
}

/// The app sends the default name it showed (`workspace-151`) with a create, and older daemons
/// recorded every requested name as the user's (#26680). Never renamed, that name is still
/// unnamed: the automatic namer may replace it. A person's later rename stays pinned.
#[test]
fn workspace_name_source_auto_replaces_a_created_default_name() {
    let mut created = workspace("workspace-151", NameSource::User, 0);
    auto(0).apply_workspace(&mut created, "Fix Login".into(), GENERATION).unwrap();
    assert_eq!(created.name, "Fix Login");
    assert_eq!(created.name_source, NameSource::Auto);
    assert_eq!(created.name_revision, 1);

    let mut renamed = workspace("workspace-151", NameSource::User, 1);
    assert!(auto(1).apply_workspace(&mut renamed, "Fix Login".into(), GENERATION).is_err());
    let mut home = workspace("~", NameSource::User, 0);
    assert!(auto(0).apply_workspace(&mut home, "Fix Login".into(), GENERATION).is_err());
    let mut lookalike = workspace("workspace-1a", NameSource::User, 0);
    assert!(auto(0).apply_workspace(&mut lookalike, "Fix Login".into(), GENERATION).is_err());
}

#[test]
fn workspace_name_source_requested_default_name_is_auto() {
    assert_eq!(NameSource::for_requested_workspace_name(None), NameSource::Auto);
    assert_eq!(NameSource::for_requested_workspace_name(Some("workspace-151")), NameSource::Auto);
    assert_eq!(NameSource::for_requested_workspace_name(Some("Billing")), NameSource::User);
    assert_eq!(NameSource::for_requested_workspace_name(Some("workspace-")), NameSource::User);
    assert_eq!(NameSource::for_requested_workspace_name(Some("~")), NameSource::User);
}

#[test]
fn workspace_name_source_stale_revision_and_generation_fail() {
    let mut target = workspace("workspace-1", NameSource::Auto, 3);
    let before = target.clone();
    let stale = auto(2).apply_workspace(&mut target, "Old Topic".into(), GENERATION).unwrap_err();
    assert_eq!(resource_code(&stale), Some("revision.conflict"));
    let retired = auto(3).apply_workspace(&mut target, "Old Topic".into(), "generation-b");
    assert_eq!(resource_code(&retired.unwrap_err()), Some("operation.failed"));
    assert_eq!(target, before);
}

#[test]
fn workspace_name_source_auto_cannot_empty_a_name() {
    let mut target = workspace("workspace-1", NameSource::Auto, 0);
    for empty in ["", "   "] {
        assert!(auto(0).apply_workspace(&mut target, empty.into(), GENERATION).is_err());
    }
    assert_eq!(target.name, "workspace-1");
    assert_eq!(target.name_revision, 0);
}

#[test]
fn workspace_name_source_stored_spelling_round_trips() {
    for source in [NameSource::User, NameSource::Auto] {
        assert_eq!(NameSource::from_stored(source.as_str()), source);
        assert_eq!(serde_json::to_value(source).unwrap(), json!(source.as_str()));
    }
    assert_eq!(NameSource::from_stored("unknown"), NameSource::User);
}

fn tab(name: Option<&str>, source: NameSource, revision: u64) -> RegistryTab {
    RegistryTab {
        public_id: TabPublicId::parse(format!("tab_{:032x}", 1)).unwrap(),
        pane_id: PanePublicId::parse(format!("pane_{:032x}", 1)).unwrap(),
        position: 0,
        content_id: ContentPublicId::Terminal(
            TerminalPublicId::parse(format!("term_{:032x}", 1)).unwrap(),
        ),
        name: name.map(str::to_string),
        name_source: source,
        name_revision: revision,
        browser_url: None,
        terminal_id: None,
    }
}

fn refusal_reason(error: anyhow::Error) -> (String, Value) {
    let error = error.downcast::<ResourceError>().expect("a typed resource error");
    (error.code, error.details["extra"]["reason_code"].clone())
}

#[test]
fn name_source_refusals_are_typed_operation_failures() {
    let pinned_workspace = auto(7)
        .apply_workspace(
            &mut workspace("Billing", NameSource::User, 7),
            "Fix Login".into(),
            GENERATION,
        )
        .unwrap_err();
    assert_eq!(refusal_reason(pinned_workspace), ("operation.failed".into(), json!("name_pinned")));
    let empty_workspace = auto(0)
        .apply_workspace(&mut workspace("workspace-1", NameSource::Auto, 0), " ".into(), GENERATION)
        .unwrap_err();
    assert_eq!(refusal_reason(empty_workspace), ("operation.failed".into(), json!("name_empty")));

    let pinned_tab = auto(2)
        .apply(&mut tab(Some("Logs"), NameSource::User, 2), Some("Build".into()), GENERATION, 2)
        .unwrap_err();
    assert_eq!(refusal_reason(pinned_tab), ("operation.failed".into(), json!("name_pinned")));
    let empty_tab =
        auto(2).apply(&mut tab(None, NameSource::Auto, 2), None, GENERATION, 2).unwrap_err();
    assert_eq!(refusal_reason(empty_tab), ("operation.failed".into(), json!("name_empty")));
}

/// A v1 `rename-workspace` carries `expected_generation` as the mutation's
/// registry guard. A user rename must not turn it into name authority, so its
/// fingerprint and errors stay as before name provenance.
#[test]
fn workspace_name_source_user_rename_ignores_the_mutation_generation() {
    for source in [None, Some(NameSource::User)] {
        let user = NameUpdate::from_request(source, Some(GENERATION.into()), None, false).unwrap();
        assert!(user.fingerprint().is_none(), "{source:?}");
        let mut target = workspace("workspace-1", NameSource::Auto, 0);
        user.apply_workspace(&mut target, "Billing".into(), "generation-b").unwrap();
        assert_eq!(target.name_source, NameSource::User);
    }
    let automatic =
        NameUpdate::from_request(Some(NameSource::Auto), Some(GENERATION.into()), Some(0), false)
            .unwrap();
    assert_eq!(automatic.fingerprint().unwrap()["expected_generation"], GENERATION);
    let retired = automatic
        .apply_workspace(
            &mut workspace("workspace-1", NameSource::Auto, 0),
            "Fix Login".into(),
            "generation-b",
        )
        .unwrap_err();
    assert_eq!(resource_code(&retired), Some("operation.failed"));
    assert!(NameUpdate::from_request(Some(NameSource::Auto), None, Some(0), false).is_err());
}

fn release() -> WorkspaceNameUpdate {
    NameUpdate::parse(&fields(json!({"source":"auto","release":true}))).unwrap()
}

#[test]
fn workspace_name_source_release_hands_a_user_name_back_to_auto() {
    let mut pinned = workspace("Billing", NameSource::User, 4);
    release().apply_workspace(&mut pinned, "Billing".into(), GENERATION).unwrap();
    assert_eq!(pinned.name, "Billing");
    assert_eq!(pinned.name_source, NameSource::Auto);
    assert_eq!(pinned.name_revision, 5);
    // The automatic namer takes it from the released revision.
    auto(5).apply_workspace(&mut pinned, "Fix Login".into(), GENERATION).unwrap();
    assert_eq!(pinned.name_source, NameSource::Auto);

    // A release keeps the current text.
    let mut target = workspace("Billing", NameSource::User, 4);
    let renamed = release().apply_workspace(&mut target, "Other".into(), GENERATION).unwrap_err();
    assert_eq!(resource_code(&renamed), Some("validation.invalid"));
    assert_eq!(target, workspace("Billing", NameSource::User, 4));

    // Only an automatic source can be released to.
    for user in [json!({"release":true}), json!({"source":"user","release":true})] {
        let error = NameUpdate::parse(&fields(user.clone())).err().unwrap();
        assert_eq!(resource_code(&error), Some("validation.invalid"), "{user}");
    }
    assert!(NameUpdate::from_request(Some(NameSource::User), None, None, true).is_err());
    let v1 = NameUpdate::from_request(Some(NameSource::Auto), Some(GENERATION.into()), None, true)
        .unwrap();
    assert_eq!(v1.fingerprint().unwrap()["release"], true);
    assert!(auto(0).fingerprint().unwrap().get("release").is_none());

    // Tab names have no release.
    let error = release()
        .apply(&mut tab(Some("Logs"), NameSource::User, 2), Some("Logs".into()), GENERATION, 2)
        .unwrap_err();
    assert_eq!(resource_code(&error), Some("validation.invalid"));
}
