//! Argument parsers and the mutation of legacy control commands (moved out of
//! server.rs for P8 landing 3a, behavior unchanged).

use super::*;

pub(super) fn parse_split_dir(dir: &str) -> anyhow::Result<SplitDir> {
    match dir {
        "right" => Ok(SplitDir::Right),
        "down" => Ok(SplitDir::Down),
        other => anyhow::bail!("bad dir {other:?} (want \"right\" or \"down\")"),
    }
}

/// The mutation `client` asks for, caused by the client's connection actor.
pub(super) fn workspace_mutation(
    mux: &Mux,
    client: u64,
    request: &MutationRequest,
) -> anyhow::Result<WorkspaceMutation> {
    let actor = origin_gate::connection_actor(mux, client);
    match (&request.mutation_id, &request.origin) {
        (Some(id), Some(origin)) => WorkspaceMutation::new(id.clone(), origin.clone(), actor),
        (None, None) => Ok(WorkspaceMutation::local("legacy-control", actor)),
        _ => anyhow::bail!("origin and mutation_id must be provided together"),
    }
}

pub(super) fn parse_direction(dir: &str) -> anyhow::Result<Direction> {
    match dir {
        "left" => Ok(Direction::Left),
        "right" => Ok(Direction::Right),
        "up" => Ok(Direction::Up),
        "down" => Ok(Direction::Down),
        other => anyhow::bail!("bad dir {other:?} (want \"left\", \"right\", \"up\", or \"down\")"),
    }
}

pub(super) fn parse_zoom_mode(mode: Option<String>) -> anyhow::Result<ZoomMode> {
    match mode.as_deref().unwrap_or("toggle") {
        "toggle" => Ok(ZoomMode::Toggle),
        "on" => Ok(ZoomMode::On),
        "off" => Ok(ZoomMode::Off),
        other => anyhow::bail!("bad mode {other:?} (want \"toggle\", \"on\", or \"off\")"),
    }
}

/// Deserialize a field whose absence and `null` mean different things:
/// absent is `None` (via `#[serde(default)]`), `null` is `Some(None)`.
pub(super) fn present_nullable<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

/// Deserialize a field that must be present and may be `null`: serde reads a
/// missing `Option` field as `None` unless the field has its own deserializer,
/// so with this one a missing field is refused. check-sdk-schema.py reads it
/// as required and nullable.
pub(super) fn required_nullable<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer)
}

/// Deserialize an optional field that may be absent but never `null`: absent
/// is `None` (via `#[serde(default)]`), `null` is refused like any other value
/// that is not a `T`. check-sdk-schema.py reads it as optional, not nullable.
pub(super) fn present_non_null<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}
