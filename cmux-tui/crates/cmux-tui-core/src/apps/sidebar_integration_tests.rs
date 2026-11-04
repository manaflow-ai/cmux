//! App placement through a real supervisor, document commit and reopened registry.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use cmux_layout_reducer::sidebar_doc::{Doc, Region, Section, SectionKind};
use serde_json::{Value, json};

use super::catalog::Sources;
use super::egress::HttpFetcher;
use super::mirror::{Origin, SetOp, Source};
use super::routing::MuxRouter;
use super::supervisor::{Config, Supervisor};
use crate::mux::ProviderWorkspaceState;
use crate::resource::WorkspacePublicId;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::WorkspaceRegistry;
use crate::{Mux, WorkspaceMutation};

struct Session(PathBuf);

impl Session {
    fn new() -> Self {
        Self(
            std::env::temp_dir()
                .join(format!("cmux-app-sidebar-{}", WorkspacePublicId::random().unwrap())),
        )
    }

    fn open(&self) -> Arc<Mux> {
        let registry = WorkspaceRegistry::open(&self.0, "app-sidebar").unwrap();
        Mux::from_workspace_registry(
            "app-sidebar".into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    }

    fn supervisor(&self, mux: &Arc<Mux>) -> Arc<Supervisor> {
        self.supervisor_with_sources(mux, self.sources())
    }

    fn sources(&self) -> Sources {
        Sources {
            first_party: None,
            bundled: Vec::new(),
            extra: Vec::new(),
            local: Some(self.0.join("local")),
            customize: Some(self.0.join("customize")),
            defaults: Some(Vec::new()),
        }
    }

    fn supervisor_with_sources(&self, mux: &Arc<Mux>, sources: Sources) -> Arc<Supervisor> {
        Supervisor::new(
            Config {
                state_dir: Some(self.0.join("apps-state")),
                host_binary: None,
                host_args: Vec::new(),
                server_dir: None,
                sources,
                idle_stop: Duration::from_secs(60),
                provider_deadline: Duration::from_secs(1),
                provider_user_deadline: Duration::from_secs(1),
            },
            Box::new(MuxRouter::new(mux)),
            Box::new(HttpFetcher),
        )
    }

    /// The pre-placement apps.json format deliberately has no eligibility set.
    fn write_legacy_install(&self, app: &str, source: Source, enabled: bool, hidden: bool) {
        let state = self.0.join("apps-state");
        std::fs::create_dir_all(&state).unwrap();
        let mut value = json!({
            "version": 1, "mirror": {"revision": 1, "apps": {}, "applied": []}
        });
        value["mirror"]["apps"][app] = json!({
            "installed": true, "source": source, "enabled": enabled, "hidden": hidden,
            "sandboxed": false, "grants": []
        });
        std::fs::write(state.join("apps.json"), value.to_string()).unwrap();
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn write_app(dir: &Path, id: &str, version: &str) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join("main.js"), "var __cmuxAppExports = {render() {}};").unwrap();
    let mut manifest = json!({
        "manifestVersion": 2, "id": id, "name": "PRs", "version": version,
        "description": "Recent pull requests", "engines": {"cmux": "^2.0"},
        "runtime": {"main": "main.js"}, "files": ["main.js"],
        "implements": {"cmux.section/1": {
            "export": "render", "title": "Recent PRs",
            "options": {"defaultRegion": "bottom", "maxRows": 8}
        }}
    });
    let (publisher, name) = id.split_once('/').unwrap();
    if publisher != "local" {
        let owner =
            if matches!(publisher, "cmux" | "manaflow-ai") { "manaflow-ai" } else { publisher };
        manifest["repository"] = json!(format!("https://github.com/{owner}/{name}"));
    }
    std::fs::write(dir.join("cmux-app.v2.json"), manifest.to_string()).unwrap();
}

fn sidebar_document(mux: &Mux) -> Doc {
    mux.read_registry_state(|connection| {
        crate::state::sidebar_doc_store::with_doc(connection, |doc| Ok(doc.clone()))
    })
    .unwrap()
}

fn has_placement_receipt(mux: &Mux, app: &str) -> bool {
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM meta WHERE key = ?1)",
            [format!("apps.sidebar.placed:{app}#cmux.section/1")],
            |row| row.get(0),
        )?)
    })
    .unwrap()
}

fn registry_write_counts(mux: &Mux) -> (i64, String) {
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(
            "SELECT (SELECT COUNT(*) FROM resource_mutations),
                    (SELECT value FROM meta WHERE key = 'resource_revision')",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?)
    })
    .unwrap()
}

/// A fresh document already has the recent-chats app section. Count only
/// this fixture app, while retaining every section so duplicates still fail.
fn app_sections_for(mux: &Mux, app: &str) -> Vec<Section> {
    mux.read_registry_state(|connection| {
        crate::state::sidebar_doc_store::with_doc(connection, |doc| {
            Ok(doc
                .sections()
                .iter()
                .filter(|section| {
                    matches!(&section.kind, SectionKind::App { contribution }
                        if contribution.split_once('#').is_some_and(|(id, _)| id == app))
                })
                .cloned()
                .collect())
        })
    })
    .unwrap()
}

fn change_section(mux: &Mux, operation: &str, fields: Value) {
    mux.state_sidebar_apply(
        &WorkspaceMutation::local("app-sidebar-test", crate::Actor::local_user()),
        operation,
        fields.as_object().unwrap(),
    )
    .unwrap();
}

#[test]
fn first_party_defaults_never_place_sections_on_fresh_or_existing_installs() {
    for already_installed in [false, true] {
        let session = Session::new();
        let app = "cmux/coderouter";
        write_app(&session.0.join("first-party/coderouter"), app, "1.0.0");
        if already_installed {
            session.write_legacy_install(app, Source::Default, true, false);
        }
        let mut sources = session.sources();
        sources.first_party = Some(session.0.join("first-party"));
        sources.defaults = None;
        let mux = session.open();
        let before = sidebar_document(&mux);
        let supervisor = session.supervisor_with_sources(&mux, sources.clone());
        {
            let inner = supervisor.inner.lock().unwrap();
            let record = &inner.mirror.apps[app];
            assert!(record.installed && record.enabled && !record.hidden);
            assert_eq!(record.source, Source::Default);
        }
        assert!(app_sections_for(&mux, app).is_empty(), "a default app appeared in the sidebar");
        assert_eq!(sidebar_document(&mux), before, "startup changed the person's layout");
        if already_installed {
            assert!(has_placement_receipt(&mux, app), "the legacy default was not receipted");
        }
        drop(supervisor);
        mux.shutdown();
        drop(mux);

        let reopened = session.open();
        let supervisor = session.supervisor_with_sources(&reopened, sources);
        assert!(app_sections_for(&reopened, app).is_empty(), "restart placed a default app");
        assert_eq!(sidebar_document(&reopened), before);
        drop(supervisor);
        reopened.shutdown();
    }
}

#[test]
fn existing_store_installs_receive_upgrade_receipts_without_layout_changes() {
    for (enabled, hidden) in [(true, false), (true, true), (false, false)] {
        let session = Session::new();
        let app = "octo/prs";
        write_app(&session.0.join("bundled/prs"), app, "1.0.0");
        session.write_legacy_install(app, Source::User, enabled, hidden);
        let mut sources = session.sources();
        sources.bundled.push(session.0.join("bundled"));
        let mux = session.open();
        let before = sidebar_document(&mux);
        let supervisor = session.supervisor_with_sources(&mux, sources.clone());
        assert!(has_placement_receipt(&mux, app), "upgrade skipped a hidden or disabled install");
        assert_eq!(sidebar_document(&mux), before, "upgrade changed the person's layout");

        // Showing/enabling an old install (or repeating installed=true) is
        // not a new user install and must not opt it into placement.
        supervisor
            .set(
                1,
                SetOp {
                    key: "show-existing-store-app".into(),
                    app: app.into(),
                    origin: Origin::User,
                    installed: Some(true),
                    enabled: Some(true),
                    hidden: Some(false),
                    ..SetOp::default()
                },
            )
            .unwrap();
        assert!(!supervisor.inner.lock().unwrap().mirror.sidebar_auto_place.contains(app));
        assert_eq!(sidebar_document(&mux), before, "showing an old install placed its section");
        drop(supervisor);
        mux.shutdown();
        drop(mux);

        let reopened = session.open();
        let supervisor = session.supervisor_with_sources(&reopened, sources);
        assert!(has_placement_receipt(&reopened, app));
        assert_eq!(sidebar_document(&reopened), before, "restart placed an old store app");
        drop(supervisor);
        reopened.shutdown();
    }
}

#[test]
fn a_new_user_store_install_is_placed_once_and_removal_survives_restart() {
    let session = Session::new();
    let app = "octo/prs";
    write_app(&session.0.join("bundled/prs"), app, "1.0.0");
    let mut sources = session.sources();
    sources.bundled.push(session.0.join("bundled"));
    let mux = session.open();
    let supervisor = session.supervisor_with_sources(&mux, sources.clone());
    assert!(app_sections_for(&mux, app).is_empty());
    assert!(!has_placement_receipt(&mux, app));
    let install = SetOp {
        key: "install-store-app".into(),
        app: app.into(),
        origin: Origin::User,
        installed: Some(true),
        ..SetOp::default()
    };
    supervisor.set(1, install.clone()).unwrap();
    let placed = app_sections_for(&mux, app);
    assert_eq!(placed.len(), 1, "a new user store install was not placed exactly once");
    assert_eq!(placed[0].region, Region::Bottom);
    assert!(has_placement_receipt(&mux, app));
    assert_eq!(supervisor.inner.lock().unwrap().mirror.apps[app].source, Source::User);
    supervisor.set(1, install).unwrap();
    assert_eq!(app_sections_for(&mux, app), placed, "an install replay duplicated the section");
    change_section(&mux, "sidebar.section.remove", json!({"id": placed[0].id}));
    drop(supervisor);
    mux.shutdown();
    drop(mux);

    let reopened = session.open();
    let supervisor = session.supervisor_with_sources(&reopened, sources);
    assert!(supervisor.inner.lock().unwrap().mirror.sidebar_auto_place.contains(app));
    assert!(has_placement_receipt(&reopened, app));
    assert!(
        app_sections_for(&reopened, app).is_empty(),
        "restart restored a removed store section"
    );
    drop(supervisor);
    reopened.shutdown();
}

#[test]
fn a_new_hidden_store_install_remains_eligible_across_restart_until_shown() {
    let session = Session::new();
    let app = "octo/prs";
    write_app(&session.0.join("bundled/prs"), app, "1.0.0");
    let mut sources = session.sources();
    sources.bundled.push(session.0.join("bundled"));
    let mux = session.open();
    let supervisor = session.supervisor_with_sources(&mux, sources.clone());
    supervisor
        .set(
            1,
            SetOp {
                key: "install-hidden-store-app".into(),
                app: app.into(),
                origin: Origin::User,
                installed: Some(true),
                hidden: Some(true),
                ..SetOp::default()
            },
        )
        .unwrap();
    assert!(app_sections_for(&mux, app).is_empty());
    assert!(!has_placement_receipt(&mux, app), "a hidden new install was prematurely receipted");
    drop(supervisor);
    mux.shutdown();
    drop(mux);

    let reopened = session.open();
    let supervisor = session.supervisor_with_sources(&reopened, sources);
    assert!(supervisor.inner.lock().unwrap().mirror.sidebar_auto_place.contains(app));
    assert!(app_sections_for(&reopened, app).is_empty());
    assert!(
        !has_placement_receipt(&reopened, app),
        "startup repeated the upgrade migration for a new install"
    );
    supervisor
        .set(
            1,
            SetOp {
                key: "show-new-store-app".into(),
                app: app.into(),
                origin: Origin::User,
                hidden: Some(false),
                ..SetOp::default()
            },
        )
        .unwrap();
    let shown = app_sections_for(&reopened, app);
    assert_eq!(shown.len(), 1, "a new install lost eligibility across restart");
    assert_eq!(shown[0].region, Region::Bottom);
    assert!(has_placement_receipt(&reopened, app));
    drop(supervisor);
    reopened.shutdown();
}

#[test]
fn receipted_customize_and_store_sections_reconcile_without_registry_writes() {
    let session = Session::new();
    let customize = "local/customize";
    let store = "octo/prs";
    write_app(&session.0.join("customize"), customize, "1.0.0");
    write_app(&session.0.join("bundled/prs"), store, "1.0.0");
    let mut sources = session.sources();
    sources.bundled.push(session.0.join("bundled"));
    let mux = session.open();
    let supervisor = session.supervisor_with_sources(&mux, sources);
    supervisor
        .set(
            1,
            SetOp {
                key: "install-store-app".into(),
                app: store.into(),
                origin: Origin::User,
                installed: Some(true),
                ..SetOp::default()
            },
        )
        .unwrap();
    for app in [customize, store] {
        assert_eq!(app_sections_for(&mux, app).len(), 1);
        assert!(has_placement_receipt(&mux, app));
    }
    let document = sidebar_document(&mux);
    let writes = registry_write_counts(&mux);
    for _ in 0..3 {
        supervisor.reconcile_sidebar();
        assert_eq!(sidebar_document(&mux), document);
        assert_eq!(
            registry_write_counts(&mux),
            writes,
            "a receipted reconciliation wrote a mutation or advanced the resource revision"
        );
    }
    drop(supervisor);
    mux.shutdown();
}

#[test]
fn migration_retry_preserves_pending_store_and_customize_placements() {
    let session = Session::new();
    let store = "octo/prs";
    let customize = "local/customize";
    write_app(&session.0.join("bundled/prs"), store, "1.0.0");
    let mut sources = session.sources();
    sources.bundled.push(session.0.join("bundled"));
    let mux = session.open();
    let supervisor = session.supervisor_with_sources(&mux, sources.clone());
    supervisor
        .set(
            1,
            SetOp {
                key: "install-pending-store-app".into(),
                app: store.into(),
                origin: Origin::User,
                installed: Some(true),
                hidden: Some(true),
                ..SetOp::default()
            },
        )
        .unwrap();
    // Model a migration that needs to retry. A newly seeded customize app
    // cannot place until initialization succeeds, but its eligibility is durable.
    let removed = mux
        .read_registry_state(|connection| {
            Ok(connection.execute("DELETE FROM meta WHERE key = 'apps.sidebar.initialized'", [])?)
        })
        .unwrap();
    assert_eq!(removed, 1);
    write_app(&session.0.join("customize"), customize, "1.0.0");
    supervisor.reload_local_apps(&HashMap::new());
    for app in [store, customize] {
        assert!(supervisor.inner.lock().unwrap().mirror.sidebar_auto_place.contains(app));
        assert!(app_sections_for(&mux, app).is_empty());
        assert!(!has_placement_receipt(&mux, app));
    }
    drop(supervisor);
    mux.shutdown();
    drop(mux);

    let reopened = session.open();
    let supervisor = session.supervisor_with_sources(&reopened, sources);
    let customize_sections = app_sections_for(&reopened, customize);
    assert_eq!(customize_sections.len(), 1, "migration receipted a pending customize section");
    assert_eq!(customize_sections[0].region, Region::Bottom);
    assert!(has_placement_receipt(&reopened, customize));
    assert!(app_sections_for(&reopened, store).is_empty());
    assert!(
        !has_placement_receipt(&reopened, store),
        "migration receipted a pending hidden user install"
    );
    supervisor
        .set(
            1,
            SetOp {
                key: "show-pending-store-app".into(),
                app: store.into(),
                origin: Origin::User,
                hidden: Some(false),
                ..SetOp::default()
            },
        )
        .unwrap();
    let shown = app_sections_for(&reopened, store);
    assert_eq!(shown.len(), 1, "migration retry lost a new store install's placement");
    assert_eq!(shown[0].region, Region::Bottom);
    assert!(has_placement_receipt(&reopened, store));
    drop(supervisor);
    reopened.shutdown();
}

#[test]
fn customize_present_at_first_startup_is_placed_in_the_bottom_band_once() {
    let session = Session::new();
    let app = "local/customize";
    write_app(&session.0.join("customize"), app, "1.0.0");
    let mux = session.open();
    let supervisor = session.supervisor(&mux);
    let placed = app_sections_for(&mux, app);
    assert_eq!(placed.len(), 1, "migration treated a fresh customize app as an old install");
    assert_eq!(placed[0].region, Region::Bottom);
    assert!(has_placement_receipt(&mux, app));
    drop(supervisor);
    mux.shutdown();
    drop(mux);

    let reopened = session.open();
    let supervisor = session.supervisor(&reopened);
    assert_eq!(app_sections_for(&reopened, app), placed, "restart duplicated customize's section");
    drop(supervisor);
    reopened.shutdown();
}

#[test]
fn an_existing_customize_install_receives_a_receipt_without_placement_on_upgrade() {
    let session = Session::new();
    let app = "local/customize";
    let customize = session.0.join("customize");
    write_app(&customize, app, "1.0.0");
    session.write_legacy_install(app, Source::Local, true, false);
    let mux = session.open();
    let before = sidebar_document(&mux);
    let supervisor = session.supervisor(&mux);
    assert!(has_placement_receipt(&mux, app));
    assert_eq!(sidebar_document(&mux), before, "upgrade placed the old customize section");
    write_app(&customize, app, "1.0.1");
    supervisor.reload_local_apps(&HashMap::new());
    assert_eq!(sidebar_document(&mux), before, "reload placed an old customize section");
    drop(supervisor);
    mux.shutdown();
    drop(mux);

    let reopened = session.open();
    let supervisor = session.supervisor(&reopened);
    assert!(has_placement_receipt(&reopened, app));
    assert_eq!(sidebar_document(&reopened), before, "restart placed the old customize section");
    drop(supervisor);
    reopened.shutdown();
}

#[test]
fn customize_section_appearing_after_startup_keeps_a_move_and_removal_across_restart() {
    let session = Session::new();
    let mux = session.open();
    let supervisor = session.supervisor(&mux);
    assert!(app_sections_for(&mux, "local/customize").is_empty());

    let customize = session.0.join("customize");
    write_app(&customize, "local/customize", "1.0.0");
    let prints = supervisor.reload_local_apps(&HashMap::new());
    let placed = app_sections_for(&mux, "local/customize");
    assert_eq!(placed.len(), 1, "first appearance did not place exactly one section");
    let section = &placed[0];
    assert_eq!(section.region, Region::Bottom);
    assert_eq!(section.max_rows, Some(8));
    assert!(matches!(&section.kind, SectionKind::App { contribution }
        if contribution == "local/customize#cmux.section/1"));
    let id = section.id.clone();

    change_section(&mux, "sidebar.section.move", json!({"id": id, "place": {"region": "top"}}));
    write_app(&customize, "local/customize", "1.0.1");
    let prints = supervisor.reload_local_apps(&prints);
    let moved = app_sections_for(&mux, "local/customize");
    assert_eq!(moved.len(), 1);
    assert_eq!(moved[0].id, id);
    assert_eq!(moved[0].region, Region::Top, "reload overwrote the person's move");

    change_section(&mux, "sidebar.section.remove", json!({"id": id}));
    write_app(&customize, "local/customize", "1.0.2");
    supervisor.reload_local_apps(&prints);
    assert!(
        app_sections_for(&mux, "local/customize").is_empty(),
        "reload restored a removed section"
    );
    drop(supervisor);
    mux.shutdown();
    drop(mux);

    let reopened = session.open();
    let supervisor = session.supervisor(&reopened);
    assert!(
        app_sections_for(&reopened, "local/customize").is_empty(),
        "restart restored a removed section"
    );

    supervisor.place_sidebar("local/customize#cmux.section/1", Some(Region::Middle)).unwrap();
    let restored = app_sections_for(&reopened, "local/customize");
    assert_eq!(restored.len(), 1, "explicit placement did not restore the section");
    assert_eq!(restored[0].region, Region::Middle);
    assert_eq!(restored[0].scroll, cmux_layout_reducer::sidebar_doc::Scroll::Flow);
    drop(supervisor);
    reopened.shutdown();
}

#[test]
fn an_uninstalled_or_hidden_local_app_is_placed_only_when_shown() {
    let session = Session::new();
    write_app(&session.0.join("local/panel"), "local/panel", "1.0.0");
    let mux = session.open();
    let supervisor = session.supervisor(&mux);
    assert!(
        app_sections_for(&mux, "local/panel").is_empty(),
        "an uninstalled app placed a section"
    );

    supervisor
        .set(
            1,
            SetOp {
                key: "install-hidden".into(),
                app: "local/panel".into(),
                origin: Origin::User,
                installed: Some(true),
                hidden: Some(true),
                ..SetOp::default()
            },
        )
        .unwrap();
    assert!(app_sections_for(&mux, "local/panel").is_empty(), "a hidden install placed a section");

    supervisor
        .set(
            1,
            SetOp {
                key: "show-panel".into(),
                app: "local/panel".into(),
                origin: Origin::User,
                hidden: Some(false),
                ..SetOp::default()
            },
        )
        .unwrap();
    let shown = app_sections_for(&mux, "local/panel");
    assert_eq!(shown.len(), 1);
    assert_eq!(shown[0].region, Region::Bottom);
    assert!(matches!(&shown[0].kind, SectionKind::App { contribution }
        if contribution == "local/panel#cmux.section/1"));
    drop(supervisor);
    mux.shutdown();
}

/// The customize app installs with the read scopes of its first save. A later
/// save that declares a new read scope (the person copies the
/// sidebar-section template over the starter) gets it too, the way a first
/// install would; other scopes still wait for the person (base red: the
/// record kept the first save's grants, so the new view showed "this app
/// cannot call workspace.list").
#[test]
fn a_customize_save_that_declares_a_new_read_scope_gets_it() {
    let session = Session::new();
    let mux = session.open();
    let supervisor = session.supervisor(&mux);
    let customize = session.0.join("customize");
    write_app(&customize, "local/customize", "1.0.0");
    let prints = supervisor.reload_local_apps(&HashMap::new());
    let grants = |supervisor: &Supervisor| {
        supervisor.inner.lock().unwrap().mirror.apps["local/customize"].grants.clone()
    };
    assert!(grants(&supervisor).is_empty());
    let path = customize.join("cmux-app.v2.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["version"] = json!("1.0.1");
    manifest["scopes"] = json!({"workspace:read": "r", "workspace:write": "w"});
    std::fs::write(&path, manifest.to_string()).unwrap();
    supervisor.reload_local_apps(&prints);
    assert_eq!(
        grants(&supervisor).into_iter().collect::<Vec<_>>(),
        vec!["workspace:read".to_string()]
    );
    drop(supervisor);
    mux.shutdown();
}

/// A read scope the person turned off stays off through a broken save and a
/// save that drops and re-adds it (base red: the scopes declared before came
/// from the last catalog, which a broken save empties, so the next good
/// save granted the read again).
#[test]
fn a_read_the_person_turned_off_stays_off_through_a_broken_save() {
    let session = Session::new();
    let mux = session.open();
    let supervisor = session.supervisor(&mux);
    let customize = session.0.join("customize");
    write_app(&customize, "local/customize", "1.0.0");
    let path = customize.join("cmux-app.v2.json");
    let good: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let save = |version: &str, scopes: Value| {
        let mut manifest = good.clone();
        manifest["version"] = json!(version);
        manifest["scopes"] = scopes;
        std::fs::write(&path, manifest.to_string()).unwrap();
    };
    save("1.0.1", json!({"workspace:read": "r"}));
    let mut prints = supervisor.reload_local_apps(&HashMap::new());
    let grants = |supervisor: &Supervisor| {
        supervisor.inner.lock().unwrap().mirror.apps["local/customize"].grants.clone()
    };
    assert!(grants(&supervisor).contains("workspace:read"));
    // The person turns it off in Settings > Apps > My views.
    supervisor.inner.lock().unwrap().mirror.apps.get_mut("local/customize").unwrap().grants.clear();
    std::fs::write(&path, "{ half a save").unwrap();
    prints = supervisor.reload_local_apps(&prints);
    save("1.0.2", json!({"workspace:read": "r"}));
    prints = supervisor.reload_local_apps(&prints);
    assert!(grants(&supervisor).is_empty(), "after a broken save");
    save("1.0.3", json!({}));
    prints = supervisor.reload_local_apps(&prints);
    save("1.0.4", json!({"workspace:read": "r"}));
    supervisor.reload_local_apps(&prints);
    assert!(grants(&supervisor).is_empty(), "after dropping and re-adding it");
    drop(supervisor);
    mux.shutdown();
}
