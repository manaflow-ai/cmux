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
