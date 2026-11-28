//! Compatibility entry point for a Grok runner whose access token was delivered at launch.

pub(crate) const ARG: &str = "__grok-subscription-token";
pub(crate) const COMMAND: &str = "GROK_AUTH_PROVIDER_COMMAND";
pub(crate) const PROXY: &str = "GROK_CLI_CHAT_PROXY_BASE_URL";
pub(crate) const ROUTE: &str = "ACPMUX_GROK_PLAN_ROUTE";

pub(crate) fn run(route: Option<&str>) -> anyhow::Result<()> {
    use std::io::Write as _;

    let unavailable = || anyhow::anyhow!("Grok Build access is unavailable");
    if route.is_some() {
        return Err(unavailable());
    }
    let token =
        std::env::var(crate::agent_credentials::GROK_PLAN_TOKEN).map_err(|_| unavailable())?;
    if !crate::agent_credentials::token_shaped(&token) {
        return Err(unavailable());
    }
    std::io::stdout().lock().write_all(token.as_bytes()).map_err(|_| unavailable())?;
    Ok(())
}
