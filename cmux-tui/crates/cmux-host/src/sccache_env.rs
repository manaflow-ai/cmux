//! The compiler cache's settings for a person's Cloud machine (RFD 0068 item 6), from the bind
//! request file's `sccache` section (pure, plus the Linux copy for the work user).
//!
//! The cloud service puts the section in `/var/lib/cmux/bind.json` only when the cache is on and
//! the machine reaches it through its platform edge:
//!
//! ```json
//! {"sccache": {"env": {"RUSTC_WRAPPER": "sccache", "SCCACHE_ENDPOINT": "https://…", …}}}
//! ```
//!
//! At the bind commit the Cloud role keeps it in [`KEPT_FILE`] (root, 0600), since `bind.json`
//! goes once its token is spent, and a bind without the section removes it (the cache is then
//! off). The supervisor and the Cloud role copy it to [`ENV_FILE`] for the work user (0600, that
//! user's), where acpmux reads it at each agent spawn (acpmux `sccache_env.rs`): acpmux is the
//! work user's own service, not a child of this one, and `/var/lib/cmux` is root's (0700).
//!
//! Only `RUSTC_WRAPPER` and `SCCACHE_*` names are accepted. A section with any other name, a
//! value that is not a short single-line string, or any other shape is refused whole, and the
//! machine runs without the cache, as before. A refusal names the key, never a value: the
//! section carries no credential today, but nothing here relies on that.

use serde_json::{Map, Value};

/// The section as the Cloud role keeps it (root, 0600).
pub const KEPT_FILE: &str = "/var/lib/cmux/sccache.json";

/// The copy acpmux reads, the work user's (0600); `/run/cmux` is that user's directory.
pub const ENV_FILE: &str = "/run/cmux/sccache-env.json";

/// At most this many variables in a section.
const MAX_VARS: usize = 32;
/// At most this many bytes in one value.
const MAX_VALUE: usize = 4096;

/// A name the section may set: `RUSTC_WRAPPER`, or `SCCACHE_` and upper-case letters, digits or
/// underscores.
pub fn allowed_name(name: &str) -> bool {
    name == "RUSTC_WRAPPER"
        || name.strip_prefix("SCCACHE_").is_some_and(|rest| {
            !rest.is_empty()
                && rest.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
        })
}

/// The `sccache` section of `bind.json`: `{"env": {NAME: value}}`, its variables in name order,
/// or why it is refused.
pub fn parse_section(section: &Value) -> Result<Vec<(String, String)>, String> {
    let Value::Object(section) = section else {
        return Err("`sccache` is not an object".to_owned());
    };
    if let Some(key) = section.keys().find(|k| k.as_str() != "env") {
        return Err(format!("`sccache` has an unknown key {key:?}"));
    }
    let Some(Value::Object(env)) = section.get("env") else {
        return Err("`sccache.env` is not an object".to_owned());
    };
    vars(env)
}

fn vars(env: &Map<String, Value>) -> Result<Vec<(String, String)>, String> {
    if env.is_empty() || env.len() > MAX_VARS {
        return Err(format!("`sccache.env` has {} variables", env.len()));
    }
    let mut out = Vec::with_capacity(env.len());
    for (name, value) in env {
        if !allowed_name(name) {
            return Err(format!("`sccache.env` names {name:?}, which is not allowed"));
        }
        let Value::String(value) = value else {
            return Err(format!("`sccache.env.{name}` is not a string"));
        };
        if value.is_empty() || value.len() > MAX_VALUE || value.chars().any(char::is_control) {
            return Err(format!("`sccache.env.{name}` is not a short single-line value"));
        }
        out.push((name.clone(), value.clone()));
    }
    out.sort();
    Ok(out)
}

/// The text of [`KEPT_FILE`] and [`ENV_FILE`]: the section as the platform sent it.
pub fn file_text(vars: &[(String, String)]) -> String {
    let env: Map<String, Value> =
        vars.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect();
    format!("{}\n", serde_json::json!({ "env": env }))
}

/// [`KEPT_FILE`]'s text: its variables, or why it is refused.
pub fn parse_file(text: &str) -> Result<Vec<(String, String)>, String> {
    let value: Value =
        serde_json::from_str(text).map_err(|_| "sccache.json is not JSON".to_owned())?;
    parse_section(&value)
}

/// The names of `vars`, for a log line (never the values).
pub fn names(vars: &[(String, String)]) -> String {
    vars.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>().join(",")
}

/// Copies [`KEPT_FILE`] to [`ENV_FILE`] for the work user, or removes [`ENV_FILE`] when there is
/// no valid kept file. Run at each session host spawn (`/run` is empty after a boot) and after a
/// bind. Best effort: a failure logs and leaves the machine without the cache.
#[cfg(target_os = "linux")]
pub fn publish(paths: &crate::config::Paths) {
    let out = paths.at(ENV_FILE);
    // SAFETY: geteuid has no preconditions.
    let euid = unsafe { libc::geteuid() };
    let kept = crate::linux::trusted_text(&paths.at(KEPT_FILE), "sccache.json", euid)
        .and_then(|text| text.map(|t| parse_file(&t)).transpose());
    let vars = match kept {
        Ok(Some(vars)) => vars,
        Ok(None) => {
            remove(&out);
            return;
        }
        Err(why) => {
            eprintln!("cmux-host: sccache.json refused ({why}); compiler cache off");
            remove(&out);
            return;
        }
    };
    let Some(user) = crate::linux::spawn::lookup_user(crate::daemon_spec::WORK_USER) else {
        remove(&out);
        return;
    };
    let written = crate::linux::identity::write_atomic(&out, file_text(&vars).as_bytes(), 0o600)
        .and_then(|()| std::os::unix::fs::lchown(&out, Some(user.uid), Some(user.gid)));
    match written {
        Ok(()) => {
            eprintln!("cmux-host: compiler cache settings for the work user: {}", names(&vars))
        }
        Err(e) => {
            eprintln!("cmux-host: {}: {e}; compiler cache off", out.display());
            remove(&out);
        }
    }
}

#[cfg(target_os = "linux")]
fn remove(path: &std::path::Path) {
    match std::fs::remove_file(path) {
        Ok(()) => eprintln!("cmux-host: compiler cache off: {} removed", path.display()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => eprintln!("cmux-host: {}: {e}", path.display()),
    }
}

#[cfg(test)]
#[path = "sccache_env_tests.rs"]
mod tests;
