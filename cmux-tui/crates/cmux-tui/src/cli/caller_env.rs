//! The environment of the caller a request runs for.
//!
//! The CLI learns who calls from its process: the agent session
//! (`CMUX_AGENT_SESSION`), the terminal (`CMUX_TUI_TERMINAL_ID`), the acpmux
//! session credential, the launch credential, the socket routes and the
//! working directory. One `cmux mcp` catalog host serves every agent of an app
//! (`mcp/host.rs`), each with its own environment, so a request the host runs
//! reads the environment of the agent that sent it: [`scope`] makes a
//! caller's [`CallerEnv`] current on the thread that dispatches that caller's
//! requests, as Chromium's `mojo::ReceiverSet::current_context()` names the
//! receiver whose message is being dispatched
//! (mojo/public/cpp/bindings/receiver_set.h). With no caller in scope every
//! read is this process's own, so the CLI itself is unchanged.

#[cfg(unix)]
use std::cell::RefCell;
#[cfg(unix)]
use std::collections::BTreeMap;
use std::ffi::OsString;
#[cfg(unix)]
use std::path::PathBuf;
#[cfg(unix)]
use std::sync::Arc;

#[cfg(unix)]
use serde_json::{Value, json};

/// One caller's environment: its variables (UTF-8 ones; a value that is not
/// UTF-8 is not carried), working directory and launch credential.
#[cfg(unix)]
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct CallerEnv {
    vars: BTreeMap<String, String>,
    cwd: Option<PathBuf>,
    launch_credential: Option<String>,
}

#[cfg(unix)]
impl CallerEnv {
    /// This process's own environment, as a request it sends elsewhere
    /// would run with it.
    pub(in crate::cli) fn of_process() -> Self {
        Self {
            vars: std::env::vars_os()
                .filter_map(|(key, value)| {
                    Some((key.into_string().ok()?, value.into_string().ok()?))
                })
                .collect(),
            cwd: std::env::current_dir().ok(),
            launch_credential: crate::startup_env::launch_credential(),
        }
    }

    #[cfg(test)]
    pub(in crate::cli) fn from_parts(
        vars: impl IntoIterator<Item = (String, String)>,
        cwd: Option<PathBuf>,
        launch_credential: Option<String>,
    ) -> Self {
        Self { vars: vars.into_iter().collect(), cwd, launch_credential }
    }

    pub(in crate::cli) fn var(&self, key: &str) -> Option<&str> {
        self.vars.get(key).map(String::as_str)
    }

    pub(in crate::cli) fn vars(&self) -> impl Iterator<Item = (&str, &str)> {
        self.vars.iter().map(|(key, value)| (key.as_str(), value.as_str()))
    }

    pub(in crate::cli) fn cwd(&self) -> Option<&PathBuf> {
        self.cwd.as_ref()
    }

    pub(in crate::cli) fn to_json(&self) -> Value {
        json!({
            "env": self.vars,
            "cwd": self.cwd.as_ref().map(|cwd| cwd.to_string_lossy().into_owned()),
            "launch_credential": self.launch_credential,
        })
    }

    /// The environment [`CallerEnv::to_json`] wrote; `None` when `value` has
    /// another shape.
    pub(in crate::cli) fn from_json(value: &Value) -> Option<Self> {
        let vars = value.get("env")?.as_object()?;
        let vars = vars
            .iter()
            .map(|(key, value)| Some((key.clone(), value.as_str()?.to_owned())))
            .collect::<Option<BTreeMap<_, _>>>()?;
        let text = |name: &str| match value.get(name) {
            None | Some(Value::Null) => Some(None),
            Some(Value::String(text)) => Some(Some(text.clone())),
            Some(_) => None,
        };
        Some(Self {
            vars,
            cwd: text("cwd")?.map(PathBuf::from),
            launch_credential: text("launch_credential")?,
        })
    }
}

#[cfg(unix)]
thread_local! {
    static CURRENT: RefCell<Option<Arc<CallerEnv>>> = const { RefCell::new(None) };
}

/// Puts the previous caller back when a scope ends, also by a panic.
#[cfg(unix)]
struct Restore(Option<Arc<CallerEnv>>);

#[cfg(unix)]
impl Drop for Restore {
    fn drop(&mut self) {
        let previous = self.0.take();
        CURRENT.with(|current| *current.borrow_mut() = previous);
    }
}

/// Runs `body` with `caller` current on this thread.
#[cfg(unix)]
pub(in crate::cli) fn scope<T>(caller: Arc<CallerEnv>, body: impl FnOnce() -> T) -> T {
    let previous = CURRENT.with(|current| current.borrow_mut().replace(caller));
    let _restore = Restore(previous);
    body()
}

/// The caller in scope on this thread, to carry into a thread it starts.
#[cfg(unix)]
pub(in crate::cli) fn current() -> Option<Arc<CallerEnv>> {
    CURRENT.with(|current| current.borrow().clone())
}

/// Variable `key` of the caller in scope (a variable the caller does not
/// have is unset, never this process's), else of this process.
pub(in crate::cli) fn var(key: &str) -> Option<String> {
    #[cfg(unix)]
    if let Some(caller) = current() {
        return caller.var(key).map(str::to_owned);
    }
    std::env::var(key).ok()
}

/// [`var`] as an `OsString`, for path variables.
pub(in crate::cli) fn var_os(key: &str) -> Option<OsString> {
    #[cfg(unix)]
    if let Some(caller) = current() {
        return caller.var(key).map(OsString::from);
    }
    std::env::var_os(key)
}

/// The working directory of the caller in scope, else of this process.
#[cfg(unix)]
pub(in crate::cli) fn current_dir() -> Option<PathBuf> {
    match current() {
        Some(caller) => caller.cwd.clone(),
        None => std::env::current_dir().ok(),
    }
}

/// The launch credential of the caller in scope, else the one this process
/// was started with (`startup_env::launch_credential`).
pub(in crate::cli) fn launch_credential() -> Option<String> {
    #[cfg(unix)]
    if let Some(caller) = current() {
        return caller.launch_credential.clone();
    }
    crate::startup_env::launch_credential()
}

/// The acpmux session the caller in scope runs inside, with its caller
/// token, for an acpmux connection made for it.
#[cfg(unix)]
pub(in crate::cli) fn acpmux_caller() -> acpmux::client::ClientCaller {
    acpmux::client::ClientCaller::from_env(var)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn caller(pairs: &[(&str, &str)]) -> Arc<CallerEnv> {
        Arc::new(CallerEnv::from_parts(
            pairs.iter().map(|(key, value)| ((*key).to_owned(), (*value).to_owned())),
            Some(PathBuf::from("/work/project")),
            Some("credential".into()),
        ))
    }

    #[test]
    fn a_scope_reads_its_caller_and_only_its_caller() {
        let agent = caller(&[("CMUX_AGENT_SESSION", "s1")]);
        scope(agent, || {
            assert_eq!(var("CMUX_AGENT_SESSION").as_deref(), Some("s1"));
            // Set in this process (cargo sets it for every test), not in the caller's env.
            assert_eq!(var("CARGO_PKG_NAME"), None);
            assert_eq!(current_dir(), Some(PathBuf::from("/work/project")));
            assert_eq!(launch_credential().as_deref(), Some("credential"));
        });
        assert_eq!(var("CARGO_PKG_NAME").as_deref(), Some("cmux-tui"));
        assert!(current().is_none());
    }

    #[test]
    fn scopes_nest_and_restore_after_a_panic() {
        let outer = caller(&[("CMUX_TUI_TERMINAL_ID", "term_outer")]);
        let inner = caller(&[("CMUX_TUI_TERMINAL_ID", "term_inner")]);
        scope(outer, || {
            let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                scope(inner, || {
                    assert_eq!(var("CMUX_TUI_TERMINAL_ID").as_deref(), Some("term_inner"));
                    panic!("a request that panics");
                })
            }));
            assert!(caught.is_err());
            assert_eq!(var("CMUX_TUI_TERMINAL_ID").as_deref(), Some("term_outer"));
        });
        assert!(current().is_none());
    }

    #[test]
    fn the_wire_form_round_trips() {
        let agent = caller(&[("A", "1"), ("ACPMUX_SESSION_ID", "s")]);
        let back = CallerEnv::from_json(&agent.to_json()).unwrap();
        assert_eq!(&back, agent.as_ref());
        assert_eq!(back.vars().count(), 2);
        assert!(CallerEnv::from_json(&json!({"env": {"A": 1}})).is_none());
        assert!(CallerEnv::from_json(&json!({"env": {}, "cwd": 3})).is_none());
    }

    #[test]
    fn the_acpmux_caller_is_the_scoped_session() {
        let agent = caller(&[
            ("ACPMUX_SESSION_ID", "s1"),
            ("ACPMUX_SESSION_TOKEN", "t1"),
            ("ACPMUX_SESSION_TOKEN_SOCKET", "/tmp/a.sock"),
        ]);
        let named = scope(agent, acpmux_caller);
        assert_eq!(named.session_id.as_deref(), Some("s1"));
        assert_eq!(named.token.as_deref(), Some("t1"));
        assert_eq!(named.issuer_socket.as_deref(), Some("/tmp/a.sock"));
        assert_eq!(scope(caller(&[]), acpmux_caller), acpmux::client::ClientCaller::default());
    }
}
