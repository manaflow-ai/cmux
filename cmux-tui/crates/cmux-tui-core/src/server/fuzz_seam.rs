//! Fuzz seam, compiled only under `--cfg fuzzing` (cargo-fuzz sets it; no
//! shipped or test build has it). It runs the pure parses a control line
//! takes before dispatch, in the order `connection_frame` runs them: the
//! line-size check, the API-revision upgrade of an older client's line, the
//! `cmux.protocol/2` envelope parse with its catalog validation, else the
//! legacy `{"id","cmd"}` request parse. Nothing here dispatches, so the
//! fuzz targets in `cmux-tui/fuzz` need no `Mux`.

use super::api_revision_wire::NegotiatedRevision;
use super::{MAX_JSON_LINE_BYTES, Request, json_line_payload_len};

/// What the parse of one control line decided.
#[derive(Debug)]
pub enum ControlLine {
    /// Over the line limit: the connection loop closes the connection.
    TooLarge,
    /// A `cmux.protocol/2` line: the validated request, or its typed error code.
    Resource(Result<(), String>),
    /// A legacy line: the parsed command, or serde's error text (sent back
    /// as a `bad request` error reply).
    Legacy(Result<(), String>),
}

/// Parse `line` as a connection from a client at `client_revision` would
/// (`None`: a client of this daemon's own revision, no upgrade).
pub fn parse_control_line(line: &str, client_revision: Option<u32>) -> ControlLine {
    if json_line_payload_len(line) > MAX_JSON_LINE_BYTES {
        return ControlLine::TooLarge;
    }
    let revision = NegotiatedRevision::default();
    if let Some(client_revision) = client_revision {
        // A refused declaration leaves the connection untranslated, as the
        // hello gate does.
        let _ = revision.declare(client_revision);
    }
    let upgraded = revision.upgrade_request(line);
    let line: &str = &upgraded;
    if let Some(parsed) = crate::resource_router::parse_resource_line(line) {
        let validated = parsed.and_then(|envelope| {
            crate::resource_router::validate_resource_envelope(
                envelope,
                crate::workspace_registry::Actor::Legacy,
            )
            .map(drop)
        });
        return ControlLine::Resource(validated.map_err(|error| error.code));
    }
    ControlLine::Legacy(
        serde_json::from_str::<Request>(line).map(drop).map_err(|error| error.to_string()),
    )
}

/// The API revisions this daemon translates, as `(base, current)`.
pub fn revision_range() -> (u32, u32) {
    let (current, base) = super::api_revision_range();
    (base, current)
}
