//! Sizing participants of a daemon with the default scheme: each of one
//! connection's own views of a terminal is its own participant
//! (`c<client>` for the view on the terminal's runtime placement,
//! `c<client>@<placement>` for every other placement), and detaching one view
//! leaves the connection's other views of the terminal in the engine
//! (docs/shared-terminal-sizing.md).

use super::*;

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

/// One connection that names its views by lease, as the app does.
struct App {
    client: u64,
    writer: MessageWriter,
}

impl App {
    fn connect(mux: &Arc<Mux>, device_name: &str) -> Self {
        let capabilities = [SHARED_SIZING_CAPABILITY, VIEW_ATTACHMENT_LEASE_CAPABILITY];
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound, control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let app = Self { client, writer };
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

    /// Attaches one view of `surface` that has not reported a viewport yet.
    fn attach(&self, mux: &Arc<Mux>, surface: SurfaceId) -> (OutboundStream, String) {
        let stream = self.writer.start_stream(&attach_overflow_json(surface)).unwrap();
        let lease = mux
            .control_clients
            .attach_surface(self.client, surface, stream.clone())
            .unwrap()
            .expect("a lease client's attach mints a lease");
        commit_client_attach(mux, self.client, surface, stream.id, None, None).unwrap();
        (stream, lease)
    }

    /// Reports the viewport of the view `lease` of `surface`.
    fn report(&self, mux: &Arc<Mux>, surface: SurfaceId, lease: &str, size: (u16, u16)) {
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
    }

    /// Attaches one view of `surface` and reports its viewport.
    fn view(
        &self,
        mux: &Arc<Mux>,
        surface: SurfaceId,
        size: (u16, u16),
    ) -> (OutboundStream, String) {
        let (stream, lease) = self.attach(mux, surface);
        self.report(mux, surface, &lease, size);
        (stream, lease)
    }

    fn participant(&self) -> String {
        format!("c{}", self.client)
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
fn sizing_participants_two_views_of_one_terminal_on_one_connection_are_two_participants() {
    let mux = test_mux();
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    let projected = projected_view(&mux, &source);
    let app = App::connect(&mux, "Studio");

    app.view(&mux, source.id, (100, 30));
    app.view(&mux, projected.id, (90, 28));

    let projected_participant = format!("c{}@{}", app.client, projected.id);
    let mut expected = vec![app.participant(), projected_participant.clone()];
    expected.sort();
    assert_eq!(participant_ids(&mux, source.id), expected);
    assert_eq!(participant_ids(&mux, projected.id), expected);
    assert_eq!(
        mux.terminal_view_participant_id(projected.id, app.client),
        Some(projected_participant.clone())
    );

    // Detaching the projected view leaves the source view's participant.
    assert!(mux.detach_terminal_own_view(projected.id, app.client).is_some());
    assert_eq!(participant_ids(&mux, source.id), [app.participant()]);
    assert_eq!(
        mux.reattach_terminal_own_view(projected.id, app.client, None).unwrap(),
        projected_participant
    );
    assert_eq!(participant_ids(&mux, source.id), expected);
}
