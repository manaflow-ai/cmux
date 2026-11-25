//! The env acpmux's own tool servers (`tools_mcp.rs`) read: the process env in their own
//! process, and a chat's env in the daemon's gateway (`mcp_gateway.rs`), which serves many chats
//! at once and so never sets the process env. A gateway request runs its server in a
//! [`scope`] with the env that chat's `acpmux tools-mcp` would have had; [`var`] reads that first
//! and the process env for any key it does not name, as a child of the daemon would.

use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;

tokio::task_local! {
    static ENV: Arc<HashMap<String, String>>;
}

/// Runs `f` with [`var`] reading `env` before the process env.
pub async fn scope<F: Future>(env: HashMap<String, String>, f: F) -> F::Output {
    ENV.scope(Arc::new(env), f).await
}

/// [`scope`] for `f`, which does not wait.
pub fn sync_scope<R>(env: HashMap<String, String>, f: impl FnOnce() -> R) -> R {
    ENV.sync_scope(Arc::new(env), f)
}

/// Env var `key`: the [`scope`]'s value when it names it, else the process env's.
pub fn var(key: &str) -> Option<String> {
    ENV.try_with(|env| env.get(key).cloned()).ok().flatten().or_else(|| std::env::var(key).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_scope_names_its_own_values_and_leaves_the_rest_to_the_process() {
        let env = HashMap::from([("ACPMUX_TOOL_ENV_TEST".to_owned(), "chat".to_owned())]);
        let inside = scope(env, async { (var("ACPMUX_TOOL_ENV_TEST"), var("PATH")) }).await;
        assert_eq!(inside.0.as_deref(), Some("chat"));
        assert_eq!(inside.1, std::env::var("PATH").ok());
        assert_eq!(var("ACPMUX_TOOL_ENV_TEST"), None, "outside the scope: the process env");
    }
}
