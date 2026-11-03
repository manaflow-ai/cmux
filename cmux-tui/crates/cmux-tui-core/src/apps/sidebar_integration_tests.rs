//! App placement through a real supervisor, document commit and reopened registry.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use cmux_layout_reducer::sidebar_doc::{Region, Section, SectionKind};
use serde_json::{Value, json};

use super::catalog::Sources;
use super::egress::HttpFetcher;
use super::mirror::{Origin, SetOp};
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
        Supervisor::new(
            Config {
                state_dir: Some(self.0.join("apps-state")),
                host_binary: None,
                host_args: Vec::new(),
                server_dir: None,
                sources: Sources {
                    first_party: None,
                    bundled: Vec::new(),
                    extra: Vec::new(),
                    local: Some(self.0.join("local")),
                    customize: Some(self.0.join("customize")),
                    defaults: Some(Vec::new()),
                },
                idle_stop: Duration::from_secs(60),
                provider_deadline: Duration::from_secs(1),
                provider_user_deadline: Duration::from_secs(1),
            },
            Box::new(MuxRouter::new(mux)),
            Box::new(HttpFetcher),
        )
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
    let manifest = json!({
        "manifestVersion": 2, "id": id, "name": "PRs", "version": version,
        "description": "Recent pull requests", "engines": {"cmux": "^2.0"},
        "runtime": {"main": "main.js"}, "files": ["main.js"],
        "implements": {"cmux.section/1": {
            "export": "render", "title": "Recent PRs",
            "options": {"defaultRegion": "bottom", "maxRows": 8}
        }}
    });
    std::fs::write(dir.join("cmux-app.v2.json"), manifest.to_string()).unwrap();
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
