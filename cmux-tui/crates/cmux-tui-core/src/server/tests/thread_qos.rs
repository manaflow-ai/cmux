//! A terminal's threads follow the app's hide signal (p02-threads-236):
//! `set-size-counts counts:false` from a hidden view lowers the terminal to
//! utility, clearing it raises it again, only with `hiddenTerminalQos` on.

use cmux_threads::ThreadQos;

use crate::surface::Surface;

use super::*;

/// A terminal that `client` views at 80x24.
fn viewed_terminal(follow: bool) -> (Arc<Mux>, Arc<Surface>, u64, MessageWriter) {
    let mux = test_mux();
    mux.set_terminal_threads_follow_visibility_for_test(follow);
    let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
    mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
    handle_command(
        &mux,
        client,
        Command::ResizeSurface { surface: surface.id, cols: 80, rows: 24 },
        &writer,
    )
    .unwrap();
    (mux, surface, client, writer)
}

fn set_counts(
    mux: &Arc<Mux>,
    surface: &Surface,
    client: u64,
    writer: &MessageWriter,
    counts: Option<bool>,
) {
    handle_command(
        mux,
        client,
        Command::SetSizeCounts {
            surface: surface.id,
            client: None,
            lease: None,
            view: None,
            participant: None,
            counts,
        },
        writer,
    )
    .unwrap();
}

#[test]
fn hiding_the_only_view_lowers_the_terminal_and_showing_it_raises_it() {
    let (mux, surface, client, writer) = viewed_terminal(true);
    assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive), "a shown terminal");

    set_counts(&mux, &surface, client, &writer, Some(false));
    assert_eq!(surface.thread_qos(), Some(ThreadQos::Utility), "its view hid");

    set_counts(&mux, &surface, client, &writer, None);
    assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive), "its view shows again");
}

#[test]
fn releasing_the_only_views_size_lowers_the_terminal() {
    // The hide of an app without in-place hiding: release-surface-size.
    let (mux, surface, client, writer) = viewed_terminal(true);
    handle_command(&mux, client, Command::ReleaseSurfaceSize { surface: surface.id }, &writer)
        .unwrap();
    assert_eq!(surface.thread_qos(), Some(ThreadQos::Utility));
}

#[test]
fn a_terminal_another_view_shows_stays_at_the_echo_class() {
    let (mux, surface, client, writer) = viewed_terminal(true);
    let other_writer = test_writer();
    let other = mux.control_clients.register(ClientTransport::Unix, other_writer.clone());
    let stream = other_writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    mux.control_clients.attach_surface(other, surface.id, stream).unwrap();
    mux.control_clients.commit_surface(other, surface.id, stream_id, None).unwrap();
    handle_command(
        &mux,
        other,
        Command::ResizeSurface { surface: surface.id, cols: 100, rows: 30 },
        &other_writer,
    )
    .unwrap();

    set_counts(&mux, &surface, client, &writer, Some(false));
    assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive));
}

#[test]
fn with_the_feature_off_a_hidden_terminal_keeps_its_class() {
    let (mux, surface, client, writer) = viewed_terminal(false);
    set_counts(&mux, &surface, client, &writer, Some(false));
    assert_eq!(surface.thread_qos(), Some(ThreadQos::UserInteractive));
}
