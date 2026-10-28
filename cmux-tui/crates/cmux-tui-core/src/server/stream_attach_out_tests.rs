//! The render, browser and byte views of attach streams as drains:
//! what each sends, in which order, and how each ends.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use crate::server::attach_lifecycle::attach_pump::tests::{
    WAIT, connect, connect_with, eventually, next_any, request,
};
use crate::server::attach_streams::ClientStreamId;
use crate::server::{
    BoundedOutbound, GUARDED_BROWSER_POINTER_CAPABILITY, MessageWriter,
    OUTBOUND_CONNECTION_CAPACITY, disconnect_client,
};
use crate::{BrowserFrame, Mux, SurfaceOptions};

/// The next item of `stream`, skipping other streams' items.
fn next_of(outbound: &BoundedOutbound, stream: u16) -> Value {
    loop {
        let item = next_any(outbound, WAIT).expect("an item");
        if item["stream"] == stream {
            return item;
        }
    }
}

/// The items of `stream` until its `stream-end`, which is the last.
fn until_end(outbound: &BoundedOutbound, stream: u16) -> Vec<Value> {
    let mut items = Vec::new();
    loop {
        let item = next_of(outbound, stream);
        let end = item["event"] == "stream-end";
        items.push(item);
        if end {
            return items;
        }
    }
}

fn events(items: &[Value]) -> Vec<&str> {
    items.iter().filter_map(|item| item["event"].as_str()).collect()
}

/// Writes 60 lines into the terminal and scrolls 3 rows up: its render
/// views get a scroll change and a frame.
fn scroll_into_history(surface: &crate::Surface) {
    let lines: String = (0..60).map(|line| format!("line {line}\r\n")).collect();
    surface.inject_output_for_test(lines.as_bytes());
    surface.scroll_delta(-3).expect("scroll");
}

/// A render view sends its frames and scroll changes on its stream; when
/// its terminal closes it says `detached`, then `stream-end{detached}`.
#[test]
fn a_render_stream_view_sends_frames_and_scrolls_and_ends_detached() {
    let mux = Mux::new_for_test("stream-render", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    request(
        &mux,
        client,
        &writer,
        json!({"cmd": "attach-surface", "surface": surface.id, "stream": 4, "mode": "render"}),
    );
    let initial = next_of(&outbound, 4);
    assert_ne!(initial["event"], "stream-end", "{initial}");

    // A scroll into the history is a scroll change, then a frame.
    scroll_into_history(&surface);
    let scrolled = next_of(&outbound, 4);
    assert_eq!(scrolled["event"], "scroll-changed", "{scrolled}");
    assert_eq!(
        (scrolled["surface"].as_u64(), scrolled["at_bottom"].as_bool()),
        (Some(surface.id), Some(false))
    );
    let delta = next_of(&outbound, 4);
    assert_eq!(delta["event"], "render-delta", "{delta}");

    surface.end_attachments_for_test();
    let items = until_end(&outbound, 4);
    let events = events(&items);
    let tail = &events[events.len().saturating_sub(2)..];
    assert_eq!(tail, ["detached", "stream-end"], "{items:?}");
    assert_eq!(items.last().unwrap()["reason"], "detached");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// Queues one item on each of new streams until the connection holds its
/// budget of stream items.
fn fill_connection(writer: &MessageWriter, outbound: &BoundedOutbound) {
    while outbound.queued_stream_items() < OUTBOUND_CONNECTION_CAPACITY {
        let filler = writer.start_stream(&json!({"event": "overflow"})).expect("filler");
        writer.send_stream(&json!({"event": "fill"}), &filler).expect("room");
    }
}

/// A render view whose stream the connection drops for being its largest
/// ends with `stream-end{overflow}` alone: no `detached` and no second end.
#[test]
fn an_overflowed_render_stream_view_ends_once_without_detached() {
    let mux = Mux::new_for_test("stream-render-overflow", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    request(
        &mux,
        client,
        &writer,
        json!({"cmd": "attach-surface", "surface": surface.id, "stream": 6, "mode": "render"}),
    );
    let stream = writer.client_stream(ClientStreamId(6)).expect("the view's stream");
    scroll_into_history(&surface);
    // The view holds its initial state and the scroll change: its cap, the
    // largest stream of the connection once every other holds one item.
    eventually("the view holds its cap", || !outbound.has_backpressure_room(&stream));
    fill_connection(&writer, &outbound);
    let last = writer.start_stream(&json!({"event": "overflow"})).expect("filler");
    writer.send_stream(&json!({"event": "fill"}), &last).expect("the view's stream is dropped");
    eventually("the view is detached", || {
        mux.control_clients.stream_surface(client, stream.id).is_none()
    });
    let mut items = Vec::new();
    while let Some(item) = next_any(&outbound, Duration::from_millis(200)) {
        if item["stream"] == 6 {
            items.push(item);
        }
    }
    assert_eq!(events(&items), ["stream-end"], "{items:?}");
    assert_eq!(items[0]["reason"], "overflow");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

fn frame(seq: u64) -> BrowserFrame {
    BrowserFrame {
        session_id: "session-test".to_string(),
        data_b64: "AAAA".to_string(),
        css_width: 80,
        css_height: 48,
        image_width: 80,
        image_height: 48,
        seq,
    }
}

/// A browser view sends a frame before the state that came with it (the
/// frame carries the authority the state can expose), and ends with
/// `detached`, then `stream-end{detached}`.
#[test]
fn a_browser_stream_view_sends_its_frame_before_its_state_and_ends_detached() {
    let mux = Mux::new_for_test("stream-browser", SurfaceOptions::default());
    let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect_with(&mux, &[GUARDED_BROWSER_POINTER_CAPABILITY]);
    request(
        &mux,
        client,
        &writer,
        json!({"cmd": "attach-surface", "surface": surface.id, "stream": 7}),
    );
    // The initial state and one item of the test hold the stream at its
    // cap, so the drain takes the frame and the state in one update.
    let stream = writer.client_stream(ClientStreamId(7)).expect("the view's stream");
    writer.send_stream(&json!({"event": "pad"}), &stream).expect("pad");
    let browser = surface.as_browser().expect("a browser");
    browser.store_state_and_frame_for_test(frame(1));
    let mut sent = Vec::new();
    while sent.len() < 4 {
        sent.push(next_of(&outbound, 7));
    }
    assert_eq!(events(&sent), ["browser-state", "pad", "frame", "browser-state"], "{sent:?}");

    mux.close_surface(surface.id).expect("close");
    let items = until_end(&outbound, 7);
    let events = events(&items);
    let tail = &events[events.len().saturating_sub(2)..];
    assert_eq!(tail, ["detached", "stream-end"], "{items:?}");
    assert_eq!(items.last().unwrap()["reason"], "detached");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// A byte view forwards its surface's notifications on its stream (the
/// legacy `mux-attach-notifications` thread's work).
#[test]
fn a_byte_stream_view_forwards_its_surface_notifications() {
    let mux: Arc<Mux> = Mux::new_for_test("stream-notify", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound, client) = connect(&mux);
    request(
        &mux,
        client,
        &writer,
        json!({"cmd": "attach-surface", "surface": surface.id, "stream": 8}),
    );
    request(
        &mux,
        client,
        &writer,
        json!({"cmd": "notify", "title": "build done", "body": "ok", "surface": surface.id}),
    );
    let notification = loop {
        let item = next_of(&outbound, 8);
        if item["event"] == "notification" {
            break item;
        }
    };
    assert_eq!(notification["title"], "build done", "{notification}");
    assert_eq!(notification["surface"], json!(surface.id), "{notification}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}
