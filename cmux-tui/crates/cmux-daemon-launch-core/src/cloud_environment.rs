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
mod tests {
    use serde_json::{Value, json};

    struct Home(std::path::PathBuf);
    impl Drop for Home {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn home(name: &str) -> Home {
        let path = std::env::temp_dir()
            .join(format!("cmux-launch-cloud-env-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Home(path)
    }

    fn launch(home: &Home, arguments: &[&str], environment: &[(&str, &str)]) -> Value {
        let request = json!({
            "bundleId": "com.cmuxterm.app.debug.cloud-env-test",
            "home": home.0.display().to_string(),
            "arguments": arguments,
            "environment": environment.iter().map(|(k, v)| ((*k).to_owned(), json!(v)))
                .collect::<serde_json::Map<_, _>>(),
        });
        crate::ops::call("cloud_environment_launch_read", &request).unwrap()
    }

    #[test]
    fn a_known_deployment_answers_in_process() {
        let home = home("known");
        let reply = launch(&home, &["cmux"], &[]);
        assert_eq!(reply["selection"]["name"], "dev", "{reply}");
        assert_eq!(reply["selection"]["config_source"], "known_origin_fallback", "{reply}");
        assert_eq!(reply["selection"]["bundle_id"], "com.cmuxterm.app.debug.cloud-env-test");
        let staging = launch(
            &home,
            &["cmux", "--cloud-backend", "staging"],
            &[("CMUX_NEXT_CLOUD_ENV", "prod")],
        );
        assert_eq!(staging["selection"]["name"], "staging", "the arguments come first: {staging}");
        let prod = launch(&home, &["cmux"], &[("CMUX_NEXT_CLOUD_ENV", "prod")]);
        assert_eq!(prod["selection"]["name"], "prod", "{prod}");
    }

    #[test]
    fn a_custom_origin_with_no_cache_goes_to_the_cli_and_a_bad_seed_fails() {
        let home = home("custom");
        assert_eq!(
            launch(&home, &["cmux", "--cloud-backend=http://127.0.0.1:9"], &[]),
            json!("fetch")
        );
        let bad = launch(&home, &["cmux", "--cloud-backend"], &[]);
        assert!(bad["error"].as_str().is_some_and(|m| m.contains("--cloud-backend")), "{bad}");
        let refused =
            launch(&home, &["cmux"], &[("CMUX_NEXT_CLOUD_BACKEND", "https://example.com")]);
        assert!(refused["error"].is_string(), "{refused}");
    }

    #[test]
    fn a_request_with_no_bundle_or_home_is_refused() {
        assert!(crate::ops::call("cloud_environment_launch_read", &json!({})).is_err());
    }
}
