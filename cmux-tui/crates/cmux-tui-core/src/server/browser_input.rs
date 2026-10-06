//! Browser pointer, wheel and key input commands (moved unchanged from server.rs so the
//! activity owner can observe a person's browser input without growing server.rs).

use super::*;

pub(super) fn handle(mux: &Mux, client: u64, cmd: Command) -> anyhow::Result<Value> {
    let result = dispatch(mux, client, cmd);
    if result.is_ok() {
        // A person's browser input is user activity for the Cloud VM idle pause.
        super::activity::note_person_input(mux, client);
    }
    result
}

fn dispatch(mux: &Mux, client: u64, cmd: Command) -> anyhow::Result<Value> {
    match cmd {
        Command::BrowserMouse { surface, kind, x_px, y_px, button, click_count, frame_seq } => {
            handle_browser_mouse_command(
                mux,
                client,
                BrowserMouseCommand {
                    surface,
                    kind: &kind,
                    x_px,
                    y_px,
                    button: button.as_deref(),
                    click_count,
                    frame_seq,
                },
            )
        }
        Command::BrowserMouseGuarded {
            surface,
            kind,
            x_px,
            y_px,
            button,
            click_count,
            frame_seq,
        } => handle_browser_mouse_command(
            mux,
            client,
            BrowserMouseCommand {
                surface,
                kind: &kind,
                x_px,
                y_px,
                button: button.as_deref(),
                click_count,
                frame_seq: Some(frame_seq),
            },
        ),
        Command::BrowserWheel { surface, x_px, y_px, delta_y_px, frame_seq } => {
            handle_browser_wheel_command(mux, client, surface, x_px, y_px, delta_y_px, frame_seq)
        }
        Command::BrowserWheelGuarded { surface, x_px, y_px, delta_y_px, frame_seq } => {
            handle_browser_wheel_command(
                mux,
                client,
                surface,
                x_px,
                y_px,
                delta_y_px,
                Some(frame_seq),
            )
        }
        Command::BrowserKey {
            surface,
            kind,
            key,
            code,
            windows_virtual_key_code,
            modifiers,
            text,
        } => {
            let surface = get_surface(mux, surface)?;
            require_browser(mux, &surface)?;
            let event_type = match kind.as_str() {
                "down" => "keyDown",
                "up" => "keyUp",
                other => anyhow::bail!("bad browser key kind {other:?}"),
            };
            surface.browser_key_event(
                event_type,
                &key,
                &code,
                windows_virtual_key_code,
                modifiers,
                text.as_deref(),
            )?;
            Ok(json!({}))
        }
        Command::BrowserKeyPress {
            surface,
            key,
            code,
            windows_virtual_key_code,
            modifiers,
            text,
        } => {
            let surface = get_surface(mux, surface)?;
            require_browser(mux, &surface)?;
            surface.browser_key_press(
                &key,
                &code,
                windows_virtual_key_code,
                modifiers,
                text.as_deref(),
            )?;
            Ok(json!({}))
        }
        Command::BrowserInsertText { surface, text } => {
            let surface = get_surface(mux, surface)?;
            require_browser(mux, &surface)?;
            surface.browser_insert_text(&text)?;
            Ok(json!({}))
        }
        _ => anyhow::bail!("not a browser input command"),
    }
}

struct BrowserMouseCommand<'a> {
    surface: SurfaceId,
    kind: &'a str,
    x_px: f64,
    y_px: f64,
    button: Option<&'a str>,
    click_count: Option<u32>,
    frame_seq: Option<u64>,
}

fn handle_browser_mouse_command(
    mux: &Mux,
    client: u64,
    command: BrowserMouseCommand<'_>,
) -> anyhow::Result<Value> {
    let frame_seq = command
        .frame_seq
        .ok_or_else(|| anyhow::anyhow!("browser pointer input requires a frame guard"))?;
    let surface = get_surface(mux, command.surface)?;
    require_browser(mux, &surface)?;
    let event_type = match command.kind {
        "down" => "mousePressed",
        "up" => "mouseReleased",
        "move" => "mouseMoved",
        other => anyhow::bail!("bad browser mouse kind {other:?}"),
    };
    // Capability-aware clients keep a connection-scoped capture owner. Legacy
    // one-shot calls share a bounded compatibility owner so down/move/up calls
    // issued through separate short-lived sockets remain wire-compatible.
    let input_owner = mux.control_clients.browser_pointer_owner(client)?;
    surface.browser_mouse_event_for_frame_from(BrowserMouseDispatch {
        input_owner,
        event_type,
        x: command.x_px,
        y: command.y_px,
        button: command.button,
        click_count: command.click_count,
        frame_seq: Some(frame_seq),
    })?;
    Ok(json!({}))
}

fn handle_browser_wheel_command(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    x_px: f64,
    y_px: f64,
    delta_y_px: f64,
    frame_seq: Option<u64>,
) -> anyhow::Result<Value> {
    let frame_seq =
        frame_seq.ok_or_else(|| anyhow::anyhow!("browser pointer input requires a frame guard"))?;
    let surface = get_surface(mux, surface)?;
    require_browser(mux, &surface)?;
    let input_owner = mux.control_clients.browser_pointer_owner(client)?;
    surface.browser_wheel_for_frame_from(input_owner, x_px, y_px, delta_y_px, Some(frame_seq))?;
    Ok(json!({}))
}
