//! Real attach-stream transitions must distinguish viewer defaults from PTY OSC.
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use cmux_tui_core::platform::transport;
use cmux_tui_core::{Mux, Surface, SurfaceOptions};
use serde_json::{Value, json};

struct ColorFixture {
    mux: Arc<Mux>,
    surface: Arc<Surface>,
    socket: PathBuf,
}

impl ColorFixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let session = format!(
            "color-ownership-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let options = SurfaceOptions {
            command: Some(vec!["/bin/sh".into(), "-c".into(), "cat".into()]),
            ..Default::default()
        };
        let mux = Mux::new(session, options);
        let surface = mux.new_workspace(None, Some((40, 8))).unwrap();
        let socket = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
        Self { mux, surface, socket }
    }

    fn attach(&self) -> BufReader<Box<dyn transport::Stream>> {
        self.attach_surface(self.surface.id)
    }

    fn attach_surface(&self, surface: u64) -> BufReader<Box<dyn transport::Stream>> {
        self.attach_with_capability(surface, true)
    }

    fn attach_with_capability(
        &self,
        surface: u64,
        authored_colors: bool,
    ) -> BufReader<Box<dyn transport::Stream>> {
        let stream = transport::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut reader = BufReader::new(stream);
        if authored_colors {
            writeln!(
                reader.get_mut(),
                "{}",
                json!({
                    "id": 0, "cmd": "set-client-info", "name": "color-fixture", "kind": "terminal",
                    "capabilities": ["terminal-color-overrides-v1"]
                })
            )
            .unwrap();
            assert_eq!(Self::line(&mut reader)["ok"], true);
        }
        writeln!(
            reader.get_mut(),
            "{}",
            json!({"id": 1, "cmd": "attach-surface", "surface": surface})
        )
        .unwrap();
        reader
    }

    fn defaults(&self, light: bool) {
        // A separate protocol client follows the same defaults update path as
        // CloudMachineLinkManager, without touching any real shared daemon.
        let mut stream = transport::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let (fg, bg) = if light { ("#202020", "#ffffff") } else { ("#d0d0d0", "#202020") };
        writeln!(
            stream,
            "{}",
            json!({"id": 2, "cmd": "set-default-colors", "fg": fg, "bg": bg, "cursor": "#112233"})
        )
        .unwrap();
        let response = Self::line(&mut BufReader::new(stream));
        assert_eq!(response["ok"], true, "{response}");
    }

    fn line(reader: &mut impl BufRead) -> Value {
        let mut line = String::new();
        assert_ne!(reader.read_line(&mut line).unwrap(), 0, "stream ended");
        serde_json::from_str(&line).unwrap()
    }

    fn event(reader: &mut impl BufRead, event: &str) -> Value {
        loop {
            let value = Self::line(reader);
            if value["event"] == event {
                return value;
            }
        }
    }
}

impl Drop for ColorFixture {
    fn drop(&mut self) {
        let _ = self.mux.close_surface(self.surface.id);
        cmux_tui_core::server::cleanup(&self.socket);
    }
}

#[test]
fn color_ownership_shared_defaults_are_separate_on_live_resize_and_reattach() {
    let fixture = ColorFixture::new();
    let mut legacy = fixture.attach_with_capability(fixture.surface.id, false);
    let legacy_before = ColorFixture::event(&mut legacy, "vt-state");
    let mut viewer = fixture.attach();
    let before = ColorFixture::event(&mut viewer, "vt-state");
    fixture.defaults(true);
    let after = ColorFixture::event(&mut viewer, "colors-changed");
    let legacy_after = ColorFixture::event(&mut legacy, "colors-changed");
    assert!(legacy_before["colors"].get("overrides").is_none());
    assert!(legacy_after.get("overrides").is_none());
    assert_eq!(legacy_after["fg"], "#202020");
    assert_eq!(legacy_after["bg"], "#ffffff");
    // The legacy effective-color contract stays intact for clients that use it.
    assert!(before["colors"]["bg"].is_null());
    assert_eq!(after["fg"], "#202020");
    assert_eq!(after["bg"], "#ffffff");
    let empty = json!({"fg": null, "bg": null, "cursor": null});
    assert_eq!(after["overrides"], empty, "shared defaults became viewer OSC: {after}");
    assert_eq!(after["palette"], json!({}));

    fixture.surface.resize(50, 10).unwrap();
    let resized = ColorFixture::event(&mut viewer, "resized");
    let legacy_resized = ColorFixture::event(&mut legacy, "resized");
    assert!(legacy_resized["colors"].get("overrides").is_none());
    let restored = ColorFixture::event(&mut fixture.attach(), "vt-state");
    let legacy_restored = ColorFixture::event(
        &mut fixture.attach_with_capability(fixture.surface.id, false),
        "vt-state",
    );
    assert!(legacy_restored["colors"].get("overrides").is_none());
    for event in [&before, &resized, &restored] {
        assert_eq!(event["colors"]["overrides"], empty, "{event}");
        assert_eq!(event["colors"]["palette"], json!({}));
    }
}

#[test]
fn color_ownership_same_valued_osc_survives_defaults_and_resets_per_terminal() {
    let fixture = ColorFixture::new();
    fixture.defaults(false);
    fixture
        .surface
        .try_with_terminal(|term| {
            term.vt_write(
                b"\x1b]10;#d0d0d0\x07\x1b]11;#202020\x07\x1b]12;#112233\x07\x1b]4;4;#445566\x07",
            );
        })
        .unwrap();
    let authored = json!({"fg": "#d0d0d0", "bg": "#202020", "cursor": "#112233"});
    let mut viewer = fixture.attach();
    let attached = ColorFixture::event(&mut viewer, "vt-state");
    assert_eq!(attached["colors"]["overrides"], authored);
    fixture.defaults(true);
    let changed = ColorFixture::event(&mut viewer, "colors-changed");
    assert_eq!(changed["overrides"], authored);
    assert_eq!(changed["palette"], json!({"4": "#445566"}));

    fixture.surface.resize(50, 10).unwrap();
    let resized = ColorFixture::event(&mut viewer, "resized");
    assert_eq!(resized["colors"]["overrides"], authored);
    assert_eq!(resized["colors"]["palette"], json!({"4": "#445566"}));
    let reattached = ColorFixture::event(&mut fixture.attach(), "vt-state");
    assert_eq!(reattached["colors"]["overrides"], authored);
    assert_eq!(reattached["colors"]["palette"], json!({"4": "#445566"}));

    let peer = fixture.mux.new_workspace(None, Some((40, 8))).unwrap();
    let peer_state = ColorFixture::event(&mut fixture.attach_surface(peer.id), "vt-state");
    fixture.mux.close_surface(peer.id).unwrap();
    assert_eq!(peer_state["colors"]["overrides"], json!({"fg": null, "bg": null, "cursor": null}));
    assert_eq!(peer_state["colors"]["palette"], json!({}));

    // A foreground reset must not clear another dynamic color or ANSI entry.
    fixture.surface.try_with_terminal(|term| term.vt_write(b"\x1b]110\x07")).unwrap();
    fixture.defaults(false);
    let partial = ColorFixture::event(&mut viewer, "colors-changed");
    assert_eq!(partial["overrides"], json!({"fg": null, "bg": "#202020", "cursor": "#112233"}));
    assert_eq!(partial["palette"], json!({"4": "#445566"}));

    fixture
        .surface
        .try_with_terminal(|term| {
            term.vt_write(b"\x1b]111\x07\x1b]112\x07\x1b]104;4\x07");
        })
        .unwrap();
    fixture.defaults(true);
    let reset = ColorFixture::event(&mut viewer, "colors-changed");
    assert_eq!(reset["overrides"], json!({"fg": null, "bg": null, "cursor": null}));
    assert_eq!(reset["palette"], json!({}));

    // Recreating a receiving parser must not turn the new host defaults into
    // application overrides; this also exercises the terminal-host replay seam.
    let restored = ColorFixture::event(&mut fixture.attach(), "vt-state");
    assert_eq!(restored["colors"]["overrides"], reset["overrides"]);

    for reset in [b"\x1b]104\x07".as_slice(), b"\x1bc".as_slice()] {
        fixture
            .surface
            .try_with_terminal(|term| {
                term.vt_write(b"\x1b]4;1;#112233\x07\x1b]4;4;#445566\x07");
                term.vt_write(reset);
            })
            .unwrap();
        let replay = ColorFixture::event(&mut fixture.attach(), "vt-state");
        assert_eq!(replay["colors"]["palette"], json!({}));
        assert_eq!(replay["colors"]["overrides"], json!({"fg": null, "bg": null, "cursor": null}));
    }
}
