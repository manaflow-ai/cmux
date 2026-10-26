//! Sizing identity per app (`terminalSizingPerApp`, p05-ipc-075): one
//! connection's views of one terminal are leases of one participant; kicking
//! that participant on one terminal ends only that terminal's views; a
//! whole-client detach ends every stream.

use super::*;
use crate::mux::ParticipantScheme;

fn projected_view(mux: &Arc<Mux>, source: &Arc<crate::Surface>) -> Arc<crate::Surface> {
    let terminal_id =
        source.terminal_public_id().cloned().expect("test terminal has a public content identity");
    let pane = mux.with_state(|state| state.pane_of(source.id).unwrap());
    mux.resource_project_terminal_selected(
        crate::ResourceSelectors {
            terminal: Some(terminal_id.to_string()),
            ..Mux::ordinary_resource_selectors()
        },
        mux.ordinary_pane_selectors(pane).unwrap(),
        usize::MAX,
        None,
        None,
        &WorkspaceMutation::daemon_local("test-terminal-projection"),
    )
    .unwrap();
    mux.with_state(|state| {
        state
            .placements_of_content(&ContentPublicId::Terminal(terminal_id))
            .iter()
            .copied()
            .find(|placement| *placement != source.id)
            .and_then(|placement| state.surfaces.get(&placement))
            .cloned()
            .expect("projected terminal view is materialized")
    })
}

fn sizing_mux(scheme: ParticipantScheme) -> Arc<Mux> {
    let mux = test_mux();
    mux.set_participant_scheme_for_test(scheme);
    mux
}

/// One connection that names its views by lease, as the app does.
struct App {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
}

impl App {
    fn connect(mux: &Arc<Mux>, device_name: &str) -> Self {
        Self::connect_with(mux, device_name, &[])
    }

    fn connect_with(mux: &Arc<Mux>, device_name: &str, extra: &[&str]) -> Self {
        let mut capabilities = vec![SHARED_SIZING_CAPABILITY, VIEW_ATTACHMENT_LEASE_CAPABILITY];
        capabilities.extend_from_slice(extra);
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let app = Self { client, writer, outbound };
        app.run(
            mux,
            json!({
                "cmd": "set-client-info",
                "kind": "frontend",
                "device_kind": "mac",
                "device_name": device_name,
                "capabilities": capabilities,
            }),
        )
        .unwrap();
        app
    }

    fn run(&self, mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
        handle_command(mux, self.client, json_command(request), &self.writer)
    }

    /// Attaches one view of `surface` and reports its viewport.
    fn view(
        &self,
        mux: &Arc<Mux>,
        surface: SurfaceId,
        size: (u16, u16),
    ) -> (OutboundStream, String) {
        let stream = self.writer.start_stream(&attach_overflow_json(surface)).unwrap();
        let lease = mux
            .control_clients
            .attach_surface(self.client, surface, stream.clone())
            .unwrap()
            .expect("a lease client's attach mints a lease");
        commit_client_attach(mux, self.client, surface, stream.id, None, None).unwrap();
        let resized = self
            .run(
                mux,
                json!({
                    "cmd": "resize-attached-view",
                    "surface": surface,
                    "lease": lease,
                    "cols": size.0,
                    "rows": size.1,
                }),
            )
            .unwrap();
        assert_ne!(resized["outcome"], "superseded");
        (stream, lease)
    }

    fn participant(&self) -> String {
        format!("c{}", self.client)
    }

    fn popped(&self) -> Vec<Value> {
        std::iter::from_fn(|| self.outbound.try_pop())
            .map(|line| serde_json::from_str(&line).unwrap())
            .collect()
    }
}

fn participant_ids(mux: &Mux, surface: SurfaceId) -> Vec<String> {
    let state = mux.terminal_size_state(surface).unwrap();
    let mut ids =
        state.participants.iter().map(|seat| seat.participant.id.clone()).collect::<Vec<_>>();
    ids.sort();
    ids
}

#[test]
fn client_sizing_two_views_of_one_terminal_on_one_connection_are_one_participant() {
    let mux = sizing_mux(ParticipantScheme::PerApp);
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(source.id);
    let projected = projected_view(&mux, &source);
    let app = App::connect(&mux, "Studio");

    app.view(&mux, source.id, (100, 30));
    app.view(&mux, projected.id, (90, 28));
    // A second lease of the same placement is still the same participant.
    app.view(&mux, source.id, (70, 20));

    assert_eq!(participant_ids(&mux, source.id), [app.participant()]);
    assert_eq!(participant_ids(&mux, projected.id), [app.participant()]);
    let state = mux.terminal_size_state(source.id).unwrap();
    assert_eq!(state.owners, [app.participant()]);
    // The latest attached view of the terminal is the participant's
    // geometry view; the passive lease of that placement keeps its size.
    assert_eq!(source.size(), (90, 28));
    assert!(mux.client_size_participates(projected.id, app.client));
    assert!(!mux.client_size_participates(source.id, app.client));

    // Activity on another view makes it the participant's geometry view.
    assert_eq!(mux.claim_terminal_geometry(source.id, app.client), Some(true));
    assert_eq!(source.size(), (100, 30));
    assert!(mux.client_size_participates(source.id, app.client));
    assert!(!mux.client_size_participates(projected.id, app.client));
    assert_eq!(participant_ids(&mux, source.id), [app.participant()]);
}

#[test]
fn client_sizing_per_placement_scheme_keeps_one_participant_per_placement() {
    let mux = sizing_mux(ParticipantScheme::PerPlacement);
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    let projected = projected_view(&mux, &source);
    let app = App::connect(&mux, "Studio");

    app.view(&mux, source.id, (100, 30));
    app.view(&mux, projected.id, (90, 28));

    let mut expected = vec![app.participant(), format!("c{}@{}", app.client, projected.id)];
    expected.sort();
    assert_eq!(participant_ids(&mux, source.id), expected);
}

#[test]
fn client_sizing_leaving_one_view_keeps_the_participant_on_the_next_view() {
    let mux = sizing_mux(ParticipantScheme::PerApp);
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(source.id);
    let projected = projected_view(&mux, &source);
    let app = App::connect(&mux, "Studio");
    let (first, _) = app.view(&mux, source.id, (100, 30));
    let (second, second_lease) = app.view(&mux, projected.id, (90, 28));

    let detached = app
        .run(
            &mux,
            json!({"cmd": "detach-attached-view", "surface": projected.id, "lease": second_lease}),
        )
        .unwrap();

    assert_eq!(detached["outcome"], "applied");
    assert!(!second.is_open());
    assert!(first.is_open(), "the other view of the terminal stays");
    assert_eq!(participant_ids(&mux, source.id), [app.participant()]);
    assert_eq!(source.size(), (100, 30), "the remaining view's viewport sets the grid");
    assert!(mux.client_size_participates(source.id, app.client));
}

#[test]
fn client_sizing_releasing_the_geometry_view_hands_the_size_to_the_next_view() {
    let mux = sizing_mux(ParticipantScheme::PerApp);
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(source.id);
    let projected = projected_view(&mux, &source);
    let app = App::connect(&mux, "Studio");
    app.view(&mux, source.id, (100, 30));
    let (_, projected_lease) = app.view(&mux, projected.id, (90, 28));
    assert_eq!(source.size(), (90, 28));

    let released = app
        .run(
            &mux,
            json!({
                "cmd": "release-attached-view-size",
                "surface": projected.id,
                "lease": projected_lease,
            }),
        )
        .unwrap();

    assert_eq!(released["outcome"], "applied");
    assert_eq!(participant_ids(&mux, source.id), [app.participant()]);
    assert_eq!(source.size(), (100, 30), "the view that still reports sets the size");
    assert!(mux.client_size_participates(source.id, app.client));
}

#[test]
fn client_sizing_kicking_one_terminal_view_detaches_only_it() {
    let mux = sizing_mux(ParticipantScheme::PerApp);
    let shared = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(shared.id);
    let projected = projected_view(&mux, &shared);
    let other = mux.new_workspace(None, Some((80, 24))).unwrap();
    let app = App::connect(&mux, "Studio");
    let peer = App::connect(&mux, "Laptop");
    let (shared_stream, _) = app.view(&mux, shared.id, (100, 30));
    let (projected_stream, _) = app.view(&mux, projected.id, (90, 28));
    let (other_stream, _) = app.view(&mux, other.id, (120, 40));
    let (peer_stream, _) = peer.view(&mux, shared.id, (110, 35));
    app.popped();

    let answer = peer
        .run(
            &mux,
            json!({"cmd": "detach-client", "client": app.participant(), "surface": shared.id}),
        )
        .unwrap();

    assert_eq!(answer["scope"], "terminal");
    assert!(!shared_stream.is_open());
    assert!(!projected_stream.is_open());
    assert!(other_stream.is_open(), "the app's other terminal keeps its view");
    assert!(peer_stream.is_open());
    assert!(mux.control_clients.contains(app.client), "the app's connection stays");
    let detached = app
        .popped()
        .into_iter()
        .filter(|event| event["event"] == "detached")
        .map(|event| {
            assert_eq!(event["reason"], "disconnected-by");
            event["surface"].as_u64().unwrap()
        })
        .collect::<HashSet<_>>();
    assert_eq!(detached, HashSet::from([shared.id, projected.id]));
    assert_eq!(participant_ids(&mux, shared.id), [peer.participant()]);
    assert_eq!(participant_ids(&mux, other.id), [app.participant()]);
    assert_eq!(shared.size(), (110, 35), "the remaining participant sets the grid");
}

#[test]
fn client_sizing_whole_client_detach_ends_every_stream() {
    let mux = sizing_mux(ParticipantScheme::PerApp);
    let shared = mux.new_workspace(None, Some((80, 24))).unwrap();
    let other = mux.new_workspace(None, Some((80, 24))).unwrap();
    let app = App::connect(&mux, "Studio");
    let peer = App::connect(&mux, "Laptop");
    let (shared_stream, _) = app.view(&mux, shared.id, (100, 30));
    let (other_stream, _) = app.view(&mux, other.id, (120, 40));
    peer.view(&mux, shared.id, (110, 35));
    app.popped();

    peer.run(&mux, json!({"cmd": "detach-client", "client": app.client})).unwrap();

    assert!(!shared_stream.is_open());
    assert!(!other_stream.is_open());
    assert!(!mux.control_clients.contains(app.client));
    let detached = app
        .popped()
        .into_iter()
        .filter(|event| event["event"] == "detached")
        .map(|event| event["surface"].as_u64().unwrap())
        .collect::<HashSet<_>>();
    assert_eq!(detached, HashSet::from([shared.id, other.id]));
    assert_eq!(participant_ids(&mux, shared.id), [peer.participant()]);
}

#[test]
fn client_sizing_view_detach_removes_every_view_of_the_participant_and_reattach_restores_them() {
    let mux = sizing_mux(ParticipantScheme::PerApp);
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(source.id);
    let projected = projected_view(&mux, &source);
    let app = App::connect_with(&mux, "Studio", &[SIZING_VIEW_DETACH_CAPABILITY]);
    let peer = App::connect(&mux, "Laptop");
    let (source_stream, _) = app.view(&mux, source.id, (100, 30));
    let (projected_stream, _) = app.view(&mux, projected.id, (90, 28));
    peer.view(&mux, source.id, (110, 35));
    app.popped();

    let answer = peer
        .run(
            &mux,
            json!({"cmd": "detach-client", "client": app.participant(), "surface": source.id}),
        )
        .unwrap();

    assert_eq!(answer["scope"], "view");
    assert!(source_stream.is_open() && projected_stream.is_open(), "the streams stay");
    let scoped = app
        .popped()
        .into_iter()
        .filter(|event| event["event"] == "detached")
        .map(|event| {
            assert_eq!(event["scope"], "view");
            event["surface"].as_u64().unwrap()
        })
        .collect::<HashSet<_>>();
    assert_eq!(scoped, HashSet::from([source.id, projected.id]));
    assert_eq!(participant_ids(&mux, source.id), [peer.participant()]);
    assert_eq!(source.size(), (110, 35));

    let reattached =
        app.run(&mux, json!({"cmd": "reattach-view", "surface": projected.id})).unwrap();

    assert_eq!(reattached["participant"], app.participant());
    let mut expected = vec![app.participant(), peer.participant()];
    expected.sort();
    assert_eq!(participant_ids(&mux, source.id), expected);
    assert!(mux.client_size_participates(projected.id, app.client));
}
