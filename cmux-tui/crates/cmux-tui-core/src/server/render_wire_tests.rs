//! The typed render messages write the same bytes as the `serde_json::Value`
//! objects they replaced (kept here as the `*_reference` builders), for
//! render-state and render-delta, on the socket and through `to_value`.

use super::*;
use crate::panic_free::JsonFields;
use crate::server::RenderService;
use ghostty_vt::{Callbacks, RenderState, Terminal};

fn rgb_hex_reference(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

fn styled_run_json_reference(run: &StyledRun) -> Value {
    let underline = run.underline.map(|style| match style {
        UnderlineStyle::Single => "single",
        UnderlineStyle::Double => "double",
        UnderlineStyle::Curly => "curly",
        UnderlineStyle::Dotted => "dotted",
        UnderlineStyle::Dashed => "dashed",
    });
    let mut value = json!({
        "text": run.text,
        "fg": run.fg.map(rgb_hex_reference),
        "bg": run.bg.map(rgb_hex_reference),
        "attrs": run.attrs,
    });
    if let Some(underline) = underline {
        value.insert("underline", json!(underline));
    }
    if let Some(width_hint) = run.width_hint {
        value.insert("width_hint", json!(width_hint));
    }
    value
}

fn render_rows_json_reference(
    frame: &SurfaceRenderFrame,
    rows: impl IntoIterator<Item = u16>,
) -> Vec<Value> {
    rows.into_iter()
        .filter_map(|row| {
            frame.frame.row_runs(row).map(|runs| {
                json!({
                    "row": row,
                    "runs": runs.iter().map(styled_run_json_reference).collect::<Vec<_>>(),
                })
            })
        })
        .collect()
}

fn render_cursor_json_reference(frame: &SurfaceRenderFrame) -> Value {
    let (style, blink) = frame.frame.cursor_visual;
    let style = match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    };
    let (x, y, visible) =
        frame.frame.cursor.map(|cursor| (cursor.x, cursor.y, true)).unwrap_or((0, 0, false));
    json!({
        "x": x,
        "y": y,
        "style": style,
        "blink": blink,
        "visible": visible,
        "color": frame.frame.cursor_color.map(rgb_hex_reference),
    })
}

fn frame_of(term: &mut Terminal, state: &mut RenderState) -> SurfaceRenderFrame {
    state.update(term).unwrap();
    SurfaceRenderFrame {
        frame: state.build_frame().unwrap(),
        content_generation: 1,
        scrollback_rows: 0,
        history_epoch: term.history_epoch(),
        pointer_semantics: term.pointer_semantic_snapshot(),
        palette_colors: [Rgb::default(); 256],
        palette_overridden: [false; 256],
    }
}

/// Every row and the cursor serialize to exactly the bytes of the old values.
fn assert_same_bytes(frame: &SurfaceRenderFrame, label: &str) {
    let rows = 0..frame.frame.size.1;
    let typed = render_rows_json(frame, rows.clone());
    let reference = render_rows_json_reference(frame, rows);
    assert_eq!(typed.len(), reference.len(), "{label}");
    for (typed, reference) in typed.iter().zip(&reference) {
        assert_eq!(
            serde_json::to_string(typed).unwrap(),
            serde_json::to_string(reference).unwrap(),
            "{label}: row bytes"
        );
        assert_eq!(serde_json::to_value(typed).unwrap(), *reference, "{label}: row value");
    }
    assert_eq!(
        serde_json::to_string(&render_cursor_json(frame)).unwrap(),
        serde_json::to_string(&render_cursor_json_reference(frame)).unwrap(),
        "{label}: cursor bytes"
    );
    for row in 0..frame.frame.size.1 {
        for run in frame.frame.row_runs(row).unwrap_or_default() {
            assert_eq!(
                serde_json::to_string(&styled_run_json(&run)).unwrap(),
                serde_json::to_string(&styled_run_json_reference(&run)).unwrap(),
                "{label}: styled_run_json"
            );
        }
    }
    // The message structs did not change, only the types of their rows and
    // cursor, so equal row and cursor bytes are equal message bytes. The
    // resource path converts the message with `to_value`: equal values.
    let service = Arc::new(RenderService::new());
    let reference_rows = Value::Array(render_rows_json_reference(frame, 0..frame.frame.size.1));
    let reference_cursor = render_cursor_json_reference(frame);
    let mut state = serde_json::to_value(render_state_message(&service, 3, frame)).unwrap();
    assert_eq!(state["rows"].take(), reference_rows, "{label}: render-state rows");
    assert_eq!(state["cursor"].take(), reference_cursor, "{label}: render-state cursor");
    let mut client = RenderClientState::new(service, frame);
    let mut delta = serde_json::to_value(client.delta_message(3, frame)).unwrap();
    assert_eq!(delta["cursor"].take(), reference_cursor, "{label}: render-delta cursor");
}

/// Runs of every kind: colors from the palette, RGB and default, every
/// attribute and underline style, wide and combining text, JSON escapes,
/// blank rows; the cursor visible, hidden, in each shape and with a color.
#[test]
fn typed_render_messages_write_the_bytes_of_the_old_values() {
    let mut term = Terminal::new(40, 8, 100, Callbacks::default()).unwrap();
    let mut state = RenderState::new().unwrap();
    assert_same_bytes(&frame_of(&mut term, &mut state), "blank");
    term.vt_write(
        "plain \x1b[1;2;3;5;7;8;9mall\x1b[0m \x1b[4:1ms\x1b[4:2md\x1b[4:3mc\x1b[4:4mo\x1b[4:5ma\x1b[0m\r\n"
            .as_bytes(),
    );
    term.vt_write(
        "\x1b[31;42mpal\x1b[38;2;1;2;255;48;2;0;16;171mrgb\x1b[0m 日本🙂 e\u{301}\r\n".as_bytes(),
    );
    term.vt_write("quote\" back\\slash \u{7f} tab\there \u{1b}[0m\r\n".as_bytes());
    term.vt_write(b"\x1b[38;5;255mbright\x1b[48;5;16mdark\x1b[0m");
    assert_same_bytes(&frame_of(&mut term, &mut state), "styled");
    for shape in ["\x1b[2 q", "\x1b[4 q", "\x1b[6 q", "\x1b[1 q"] {
        term.vt_write(shape.as_bytes());
        assert_same_bytes(&frame_of(&mut term, &mut state), shape);
    }
    term.vt_write(b"\x1b]12;rgb:0a/bc/ff\x07");
    assert_same_bytes(&frame_of(&mut term, &mut state), "cursor color");
    term.vt_write(b"\x1b[?25l");
    assert_same_bytes(&frame_of(&mut term, &mut state), "hidden cursor");
}

#[test]
fn rgb_hex_is_lowercase_two_digit_hex() {
    for (r, g, b) in [(0, 0, 0), (255, 255, 255), (1, 2, 3), (0xab, 0xcd, 0xef), (16, 15, 160)] {
        let color = Rgb { r, g, b };
        assert_eq!(rgb_hex(color), rgb_hex_reference(color));
        assert_eq!(
            serde_json::to_string(&RgbHex(color)).unwrap(),
            format!("\"{}\"", rgb_hex_reference(color))
        );
    }
}

/// Serialising every row of a full styled frame, old values against typed
/// messages: `cargo test --release -p cmux-tui-core --lib
/// render_wire_bench -- --ignored --nocapture`.
#[test]
#[ignore = "benchmark: run with --release -- --ignored --nocapture"]
fn render_wire_bench_full_frame_rows() {
    const FRAMES: u32 = 2000;
    let mut term = Terminal::new(200, 50, 100, Callbacks::default()).unwrap();
    for row in 0..50u16 {
        let mut line = format!("\x1b[{};1H", row + 1);
        for col in 0..20u16 {
            line.push_str(&format!("\x1b[3{}m{:>9} ", (row + col) % 8, row * 1000 + col));
        }
        term.vt_write(line.as_bytes());
    }
    let mut state = RenderState::new().unwrap();
    let frame = frame_of(&mut term, &mut state);
    let mut out = Vec::with_capacity(1 << 20);
    let mut time = |typed: bool| {
        let started = std::time::Instant::now();
        for _ in 0..FRAMES {
            out.clear();
            if typed {
                serde_json::to_writer(&mut out, &render_rows_json(&frame, 0..50)).unwrap();
                serde_json::to_writer(&mut out, &render_cursor_json(&frame)).unwrap();
            } else {
                serde_json::to_writer(&mut out, &render_rows_json_reference(&frame, 0..50))
                    .unwrap();
                serde_json::to_writer(&mut out, &render_cursor_json_reference(&frame)).unwrap();
            }
        }
        (started.elapsed() / FRAMES, out.len())
    };
    let (reference, reference_bytes) = time(false);
    let (typed, typed_bytes) = time(true);
    assert_eq!(reference_bytes, typed_bytes);
    println!(
        "RENDER-WIRE full-frame 200x50 rows+cursor bytes={typed_bytes} value_us={:.1} typed_us={:.1}",
        reference.as_secs_f64() * 1e6,
        typed.as_secs_f64() * 1e6
    );
}
