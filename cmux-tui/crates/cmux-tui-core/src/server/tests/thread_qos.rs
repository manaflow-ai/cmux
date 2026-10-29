//! A terminal's threads follow the app's hide signal: a
//! view's `set-size-counts counts:false` by its lease
//! (`TerminalAttachment.sendHidden`) lowers the terminal to utility once no
//! other view shows it, clearing it raises it again, a released or closed
//! view shows nothing, and a `counts:false` sizing choice of a view someone
//! watches keeps the class. Only with `hiddenTerminalQos` on.

use cmux_threads::ThreadQos;

use crate::surface::Surface;

use super::*;

/// One app connection that names its views by lease, as the app does.
struct App {
    client: u64,
    writer: MessageWriter,
}

impl App {
    fn connect(mux: &Arc<Mux>) -> Self {
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let app = Self { client, writer };
        app.run(
            mux,
            json!({
                "cmd": "set-client-info",
                "kind": "frontend",
                "device_kind": "mac",
                "capabilities": [SHARED_SIZING_CAPABILITY, VIEW_ATTACHMENT_LEASE_CAPABILITY],
            }),
        )
        .unwrap();
        app
    }

    fn run(&self, mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
        handle_command(mux, self.client, json_command(request), &self.writer)
    }

    /// Attaches one view of `surface` and reports its viewport: its lease.
    fn view(&self, mux: &Arc<Mux>, surface: SurfaceId, size: (u16, u16)) -> String {
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
                json!({"cmd": "resize-attached-view", "surface": surface, "lease": lease,
                       "cols": size.0, "rows": size.1}),
            )
            .unwrap();
        assert_ne!(resized["outcome"], "superseded");
        lease
    }

    /// `TerminalAttachment.sendHidden`: the view `lease` hid or shows again.
    fn send_hidden(&self, mux: &Arc<Mux>, surface: SurfaceId, lease: &str, hidden: bool) {
        let counts = if hidden { json!(false) } else { Value::Null };
        let applied = self
            .run(
                mux,
                json!({"cmd": "set-size-counts", "surface": surface, "lease": lease,
                       "counts": counts}),
            )
            .unwrap();
        assert_eq!(applied["outcome"], "applied");
    }
}

/// A terminal that one app view shows at 80x24.
fn viewed_terminal(follow: bool) -> (Arc<Mux>, Arc<Surface>, App, String) {
    let mux = test_mux();
    mux.set_terminal_threads_follow_visibility_for_test(follow);
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    let app = App::connect(&mux);
    let lease = app.view(&mux, surface.id, (80, 24));
    (mux, surface, app, lease)
}

#[test]
fn hiding_the_only_view_lowers_the_terminal_and_showing_it_raises_it() {
    let (mux, surface, app, lease) = viewed_terminal(true);
    assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive), "a shown terminal");

    app.send_hidden(&mux, surface.id, &lease, true);
    assert_eq!(surface.thread_qos(), Some(ThreadQos::Utility), "its view hid");

    app.send_hidden(&mux, surface.id, &lease, false);
    assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive), "its view shows again");
}

#[test]
fn releasing_the_only_views_size_lowers_the_terminal() {
    // The hide of an app on a daemon without in-place hiding.
    let (mux, surface, app, lease) = viewed_terminal(true);
    app.run(
        &mux,
        json!({"cmd": "release-attached-view-size", "surface": surface.id, "lease": lease}),
    )
    .unwrap();
    assert_eq!(surface.thread_qos(), Some(ThreadQos::Utility));
}

#[test]
fn a_terminal_another_view_shows_stays_at_the_echo_class() {
    let (mux, surface, app, lease) = viewed_terminal(true);
    let other = App::connect(&mux);
    other.view(&mux, surface.id, (100, 30));

    app.send_hidden(&mux, surface.id, &lease, true);
    assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive));
}

/// The TUI's "counts toward size" unticked, or tmux `attach -f
/// ignore-size`: the person still watches the view and types into it.
#[test]
fn a_shown_view_that_does_not_count_toward_the_size_keeps_the_echo_class() {
    let (mux, surface, app, _lease) = viewed_terminal(true);
    let participant =
        mux.terminal_size_state(surface.id).unwrap().participants[0].participant.id.clone();
    for selector in [json!({"participant": participant}), json!({})] {
        let mut request = json!({"cmd": "set-size-counts", "surface": surface.id, "counts": false});
        request.as_object_mut().unwrap().extend(selector.as_object().unwrap().clone());
        app.run(&mux, request).unwrap();
        let state = mux.terminal_size_state(surface.id).unwrap();
        assert!(state.participants.iter().all(|seat| !seat.counts), "{state:?}");
        assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive), "{selector}");
    }
}

#[test]
fn with_the_feature_off_a_hidden_terminal_keeps_its_class() {
    let (mux, surface, app, lease) = viewed_terminal(false);
    app.send_hidden(&mux, surface.id, &lease, true);
    assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive));
}

/// Hides and shows from two connections race on their request threads; the
/// class always ends at what the views say last, never at an older
/// publication's.
#[test]
fn racing_hides_and_shows_end_at_the_last_state() {
    for last_hidden in [false, true] {
        let (mux, surface, app, lease) = viewed_terminal(true);
        let other = App::connect(&mux);
        let other_lease = other.view(&mux, surface.id, (100, 30));
        std::thread::scope(|scope| {
            for (app, lease) in [(&app, &lease), (&other, &other_lease)] {
                let mux = &mux;
                let surface = surface.id;
                scope.spawn(move || {
                    for round in 0..200 {
                        app.send_hidden(mux, surface, lease, round % 2 == 0);
                    }
                    app.send_hidden(mux, surface, lease, last_hidden);
                });
            }
        });
        let expected = if last_hidden { ThreadQos::Utility } else { ThreadQos::UserInteractive };
        assert_eq!(surface.thread_qos(), Some(expected), "both views hidden: {last_hidden}");
    }
}
