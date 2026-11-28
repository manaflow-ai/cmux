//! The launch's Cloud environment read in the app's own process: what the bundled CLI's
//! `cloud env get --cache-first --launch-args ARGS` answered, from cmux-cloud-environment's
//! [`Resolver::launch_read`], with no child process and no network I/O.
//!
//! CMUX-571 (goal next-launch-instant): the app spawned that CLI from `main` and waited for it
//! before its launch work (`did_finish_launching_start`); a fresh copy's first CLI run took
//! 662 ms (17 ms warm). Only a custom origin with no cached client-config needs a fetch; that
//! answer ([`Read::Fetch`]) sends the app to the CLI as before.

use crate::Env;
use cmux_cloud_environment::{Resolver, Selection, launch_seed};
use serde::{Deserialize, Serialize};
use std::path::Path;

/// One launch: the app's bundle, its home folder, its launch arguments and its environment
/// (only `CMUX_NEXT_CLOUD_BACKEND` and `CMUX_NEXT_CLOUD_ENV` are read).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Launch {
    pub bundle_id: String,
    pub home: String,
    #[serde(default)]
    pub arguments: Vec<String>,
    #[serde(default)]
    pub environment: Env,
}

/// The read's answer.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Read {
    /// The selection, the CLI's `--json` answer (snake_case fields).
    Selection(Box<Selection>),
    /// Only a fetch answers: run the CLI.
    Fetch,
    /// What the CLI would have failed with.
    Error(String),
}

/// The launch's read ([`Read`]).
pub fn launch_read(launch: &Launch) -> Read {
    let read = launch_seed(&launch.arguments, |key| launch.environment.get(key).cloned()).and_then(
        |seed| {
            Resolver::new(&launch.bundle_id, Path::new(&launch.home))?.launch_read(seed.as_deref())
        },
    );
    match read {
        Ok(Some(selection)) => Read::Selection(Box::new(selection)),
        Ok(None) => Read::Fetch,
        Err(message) => Read::Error(message),
    }
}

#[cfg(test)]
#[path = "cloud_environment_tests.rs"]
mod tests;
