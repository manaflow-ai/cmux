//! A catalog provider key's env for a local spawn the base-URL path cannot serve (cmux#48428):
//! OpenCode reads the key from its built-in provider's own variable, and Claude Code on Bedrock
//! runs its Bedrock mode.

use std::collections::BTreeMap;

use super::{Route, RouteEnv, RouteKind, is_anthropic_family, reference_value};
use crate::agent_credentials::Family;
use crate::providers::{self, AnthropicAuth};

/// The variables a catalog provider's key reaches an agent by outside the base-URL path: OpenCode's
/// built-in provider variables and Bedrock's switches. The AWS credentials go only for a Bedrock
/// key, which they would outrank; every other agent keeps them for its own `aws` use.
fn names(bedrock: bool) -> impl Iterator<Item = &'static str> {
    let aws: &[&'static str] =
        if bedrock { &crate::agent_credentials::UNSET_FOR_BEDROCK } else { &[] };
    providers::PROVIDERS
        .iter()
        .filter_map(|p| p.opencode.map(|o| o.env))
        .chain(["CLAUDE_CODE_USE_BEDROCK", "AWS_BEARER_TOKEN_BEDROCK"])
        .chain(aws.iter().copied())
}

/// The env of a catalog key route for `family`, or None for every other route and family, which
/// take the base-URL path.
fn env(route: &Route, family: &str) -> Option<BTreeMap<String, String>> {
    if route.file.kind != RouteKind::DirectApiKey {
        return None;
    }
    let provider = providers::find(route.file.provider.as_deref()?)?;
    let secret = route.file.secret.as_deref().map(reference_value)?;
    let region = route.file.health_url.as_deref().and_then(providers::bedrock_region);
    let mut env = BTreeMap::new();
    if Family::of_harness(family) == Some(Family::OpenCode) {
        env.insert(provider.opencode?.env.to_owned(), secret);
    } else if is_anthropic_family(family)
        && provider.anthropic.is_some_and(|a| a.auth == AnthropicAuth::Bedrock)
    {
        env.insert("CLAUDE_CODE_USE_BEDROCK".to_owned(), "1".to_owned());
        env.insert("AWS_BEARER_TOKEN_BEDROCK".to_owned(), secret);
    } else {
        return None;
    }
    if let Some(region) = region {
        env.insert("AWS_REGION".to_owned(), region.to_owned());
    }
    Some(env)
}

/// Sets `out` to a catalog key route's env and clears the other providers' variables; false (and
/// `out` untouched) when the route and family take the base-URL path.
pub(super) fn fill(route: &Route, family: &str, out: &mut RouteEnv) -> bool {
    let Some(env) = env(route, family) else { return false };
    let bedrock = route.file.provider.as_deref() == Some("bedrock");
    let more: Vec<String> =
        names(bedrock).filter(|k| !out.unset.iter().any(|u| u == k)).map(str::to_owned).collect();
    out.unset.extend(more);
    out.set = env;
    true
}
