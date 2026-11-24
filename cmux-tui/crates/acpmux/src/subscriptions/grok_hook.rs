//! Grok Build reads one access token on stdout. The local hook is scoped to
//! the invoking agent's bound route. Cloud passes a single access token with
//! the launch, so the guest hook reads only its own environment.

use serde_json::json;
use std::path::Path;

pub(crate) const ARG: &str = "__grok-subscription-token";
pub(crate) const COMMAND: &str = "GROK_AUTH_PROVIDER_COMMAND";
pub(crate) const PROXY: &str = "GROK_CLI_CHAT_PROXY_BASE_URL";
pub(crate) const ROUTE: &str = "ACPMUX_GROK_PLAN_ROUTE";

/// The command line contains only executable arguments and an optional route id.
pub(crate) fn command(route: Option<&str>) -> anyhow::Result<String> {
    let executable = std::env::current_exe()?;
    let executable =
        executable.to_str().ok_or_else(|| anyhow::anyhow!("invalid executable path"))?;
    let quote = |word: &str| format!("'{}'", word.replace('\'', "'\\''"));
    let mut words = vec![quote(executable)];
    words.extend(crate::daemon::daemon_prefix().iter().map(|arg| quote(&arg.to_string_lossy())));
    words.push(ARG.into());
    if let Some(route) = route {
        words.push(quote(route));
    }
    Ok(words.join(" "))
}

pub(crate) fn run(route: Option<&str>) -> anyhow::Result<()> {
    let unavailable = || anyhow::anyhow!("Grok Build access is unavailable");
    let reply = if let Some(route) = route {
        let socket =
            std::env::var(crate::person_tokens::CALLER_SOCKET_ENV).map_err(|_| unavailable())?;
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(async {
                tokio::time::timeout(std::time::Duration::from_secs(6), async {
                    let client = crate::client::Client::connect(Path::new(&socket)).await?;
                    client
                        .request(
                            crate::rpc::method::MUX_CONNECTIONS_GROK_HOOK,
                            json!({"id": route}),
                        )
                        .await
                })
                .await
            })
            .map_err(|_| unavailable())?
            .map_err(|_| unavailable())?
    } else {
        let token =
            std::env::var(crate::agent_credentials::GROK_PLAN_TOKEN).map_err(|_| unavailable())?;
        if !crate::agent_credentials::token_shaped(&token) {
            return Err(unavailable());
        }
        json!({"access_token": token})
    };
    let token = reply["access_token"].as_str().ok_or_else(unavailable)?;
    let mut output = std::io::stdout().lock();
    if let Some(expires_at) = reply["expires_at"].as_i64() {
        let expires_in = expires_at - super::now();
        if expires_in <= 0 {
            return Err(unavailable());
        }
        serde_json::to_writer(
            &mut output,
            &json!({"access_token": token, "expires_in": expires_in}),
        )
        .map_err(|_| unavailable())?;
    } else {
        use std::io::Write as _;
        output.write_all(token.as_bytes()).map_err(|_| unavailable())?;
    }
    Ok(())
}
