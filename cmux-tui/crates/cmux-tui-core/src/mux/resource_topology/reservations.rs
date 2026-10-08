//! Reservations an effectful topology creation stores in its intent: the
//! workspace and terminal it will create, with the mutation that creates
//! them. The stored mutation keeps the caller's actor, so the created rows
//! are the caller's also when the effect resumes after a restart.

use anyhow::Context;
use serde_json::{Map, Value};

use super::*;
use crate::resource::WorkspacePublicId;

/// The mutation a reservation was minted with (`id`, `origin`, `actor`); a
/// reservation stored before actors existed is `legacy`.
fn stored_reservation_mutation(
    stored: &Map<String, Value>,
    what: &str,
) -> anyhow::Result<WorkspaceMutation> {
    let field =
        |name: &str| stored[name].as_str().with_context(|| format!("{what} omitted its {name}"));
    let actor = stored
        .get("mutation_actor")
        .and_then(Value::as_str)
        .map_or(crate::Actor::Legacy, crate::Actor::from_wire);
    WorkspaceMutation::new(field("mutation_id")?, field("mutation_origin")?, actor)
}

impl Mux {
    pub(super) fn effect_workspace_reservation(
        &self,
        intent: &Value,
    ) -> anyhow::Result<(String, WorkspacePublicId, WorkspaceMutation)> {
        let reservation = intent["workspace_reservation"]
            .as_object()
            .context("stored topology intent omitted its workspace reservation")?;
        let key = reservation["workspace_key"]
            .as_str()
            .context("stored workspace reservation omitted its key")?
            .to_string();
        let public_id = WorkspacePublicId::parse(
            reservation["workspace_public_id"]
                .as_str()
                .context("stored workspace reservation omitted its public id")?
                .to_string(),
        )?;
        let mutation = stored_reservation_mutation(reservation, "stored workspace reservation")?;
        Ok((key, public_id, mutation))
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn effect_terminal_reservation(
        &self,
        intent: &Value,
        workspace_key: &str,
        argv: Option<&[String]>,
        cwd: Option<&str>,
        name: Option<&str>,
        size: Option<(u16, u16)>,
        on_exit: Option<TerminalOnExit>,
    ) -> anyhow::Result<TerminalReservationRequest> {
        let stored = intent["terminal_reservation"]
            .as_object()
            .context("stored topology intent omitted its terminal reservation")?;
        let terminal_hex = stored["terminal_id"]
            .as_str()
            .context("stored terminal reservation omitted its terminal id")?;
        let terminal_id = TerminalId::from_hex(terminal_hex)
            .context("stored terminal reservation has an invalid terminal id")?;
        let mutation = stored_reservation_mutation(stored, "stored terminal reservation")?;
        Ok(TerminalReservationRequest {
            terminal_id,
            mutation,
            fingerprint: terminal_create_fingerprint(
                workspace_key,
                Some(terminal_hex),
                argv,
                cwd,
                name,
                size,
                on_exit,
            )?,
            expected_generation: None,
            expected_revision: None,
            on_exit: on_exit.unwrap_or_default(),
            env: terminal_env_field(&intent["fields"]),
        })
    }
}
