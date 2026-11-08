//! Wire adapter for Settings > Skills (`skills-v1`, crate::skills_catalog).
//!
//! | `cmd` | fields | reply `data` |
//! | --- | --- | --- |
//! | `skills-list` | `projects?` (absolute folders) | `{home, projects, skills}` |
//! | `skills-set-enabled` | `skill_id`, `enabled` | `{skill}` |
//! | `skills-create` | `harness`, `scope`, `project?`, `name`, `description` | `{skill}` |
//! | `skills-locate` | `skill_id` | `{file, dir}` |
//!
//! A skill is named by `skill_id` because the envelope's `id` is the request's number. Without
//! `projects` the list looks in the git roots of this daemon's terminals' folders. Every write and
//! locate re-lists first and acts only on a listed skill, so a caller never names a path the
//! daemon did not find. Only the owner's own local connection (Unix socket, not a remote or
//! relayed client) is served (`skills.not_trusted`).

use std::path::PathBuf;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};

use super::{MessageWriter, Response, send_response};
use crate::mux::Mux;
use crate::skills_catalog::{self as catalog, NewSkill, Project, SkillsEnv, SkillsError};
use crate::surface::SurfaceKind;

pub(super) const CAPABILITY: &str = "skills-v1";
/// The most terminals whose folders name the projects.
const MAX_TERMINALS: usize = 64;

#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
enum Command {
    SkillsList {
        #[serde(default)]
        projects: Option<Vec<String>>,
    },
    SkillsSetEnabled {
        skill_id: String,
        enabled: bool,
    },
    SkillsCreate {
        harness: String,
        scope: String,
        #[serde(default)]
        project: Option<String>,
        name: String,
        #[serde(default)]
        description: String,
    },
    SkillsLocate {
        skill_id: String,
    },
}

pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"skills-") {
        return None;
    }
    let mut value: Value = serde_json::from_str(message).ok()?;
    if !value.get("cmd").and_then(Value::as_str)?.starts_with("skills-") {
        return None;
    }
    let id = value.as_object_mut().and_then(|o| o.remove("id"));
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(reply(writer, id, Err("skills.not_trusted")));
    }
    let command = match serde_json::from_value::<Command>(value) {
        Ok(command) => command,
        Err(_) => return Some(reply(writer, id, Err(SkillsError::BadRequest.code()))),
    };
    let Some(env) = SkillsEnv::from_process() else {
        return Some(reply(writer, id, Err("skills.unavailable")));
    };
    Some(reply(writer, id, answer(mux, &env, command)))
}

fn answer(mux: &Mux, env: &SkillsEnv, command: Command) -> Result<Value, &'static str> {
    match command {
        Command::SkillsList { projects } => {
            let projects = match projects {
                Some(folders) => catalog::projects(folders.into_iter().map(PathBuf::from), &env.home),
                None => terminal_projects(mux, env),
            };
            Ok(catalog::list_reply(env, &projects))
        }
        Command::SkillsSetEnabled { skill_id, enabled } => {
            let projects = terminal_projects(mux, env);
            catalog::set_enabled(env, &projects, &skill_id, enabled)
                .map(|skill| json!({ "skill": skill }))
                .map_err(SkillsError::code)
        }
        Command::SkillsCreate { harness, scope, project, name, description } => {
            let mut projects = terminal_projects(mux, env);
            // A project the page listed from its own `projects` is one the person chose.
            if let Some(root) = &project
                && !projects.iter().any(|p| &p.root == root)
            {
                projects.extend(catalog::projects([PathBuf::from(root)], &env.home));
            }
            let new = NewSkill { harness, scope, project, name, description };
            catalog::create(env, &projects, &new)
                .map(|skill| json!({ "skill": skill }))
                .map_err(SkillsError::code)
        }
        Command::SkillsLocate { skill_id } => {
            let projects = terminal_projects(mux, env);
            catalog::find(env, &projects, &skill_id)
                .map(|skill| json!({ "file": skill.file, "dir": skill.dir }))
                .ok_or(SkillsError::NotFound.code())
        }
    }
}

/// The git roots of this daemon's terminals' folders (the shell's reported folder, else the
/// process's), at most [`MAX_TERMINALS`] terminals.
fn terminal_projects(mux: &Mux, env: &SkillsEnv) -> Vec<Project> {
    let surfaces: Vec<_> = mux.with_state(|state| {
        state
            .surfaces
            .values()
            .filter(|surface| matches!(surface.kind(), SurfaceKind::Pty))
            .take(MAX_TERMINALS)
            .cloned()
            .collect()
    });
    let folders = surfaces
        .iter()
        .filter_map(|surface| surface.pwd().or_else(|| surface.local_cwd()))
        .map(PathBuf::from);
    catalog::projects(folders, &env.home)
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, &'static str>) -> bool {
    match result {
        Ok(data) => send_response(
            writer,
            Response {
                id,
                ok: true,
                data: Some(data),
                error: None,
                error_code: None,
                error_delivery: None,
            },
        ),
        Err(code) => send_response(
            writer,
            Response {
                id,
                ok: false,
                data: None,
                error: Some(code.to_owned()),
                error_code: Some(code.to_owned()),
                error_delivery: None,
            },
        ),
    }
}

#[cfg(test)]
#[path = "skills_wire_tests.rs"]
mod tests;
