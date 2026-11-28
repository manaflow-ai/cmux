//! The runner group's roster in GitHub. The org lists about 20k runners, mostly dead one-job registrations,
//! so this reads one runner group (`cmux-fleet-linux`), 100 a page, never the org-wide list.

use reqwest::Method;
use serde_json::Value;

use crate::http::{self, CallError, Result};
use crate::model::Runner;

pub const API: &str = "https://api.github.com";
pub const DEFAULT_ORG: &str = "manaflow-ai";
pub const DEFAULT_GROUP: &str = "cmux-fleet-linux";
const HEADERS: [(&str, &str); 2] =
    [("accept", "application/vnd.github+json"), ("x-github-api-version", "2022-11-28")];

#[derive(Clone, Debug)]
pub struct GitHub {
    pub token: String,
    pub org: String,
    pub group_id: u64,
}

impl GitHub {
    /// From `GH_TOKEN` or `GITHUB_TOKEN`, resolving the group's id by name. `Ok(None)` with no token.
    pub async fn from_env(
        client: &reqwest::Client,
        env: &dyn Fn(&str) -> Option<String>,
        org: &str,
        group: &str,
    ) -> Result<Option<Self>> {
        let Some(token) = env("GH_TOKEN").or_else(|| env("GITHUB_TOKEN")).filter(|t| !t.is_empty())
        else {
            return Ok(None);
        };
        let url = format!("{API}/orgs/{org}/actions/runner-groups?per_page=100");
        let body = http::call(client, Method::GET, &url, &token, &HEADERS, None).await?;
        let group_id = body
            .get("runner_groups")
            .and_then(Value::as_array)
            .and_then(|groups| {
                groups.iter().find(|g| g.get("name").and_then(Value::as_str) == Some(group))
            })
            .and_then(|g| g.get("id").and_then(Value::as_u64))
            .ok_or_else(|| CallError(format!("GitHub: no runner group `{group}` in {org}")))?;
        Ok(Some(Self { token, org: org.to_owned(), group_id }))
    }

    /// Every runner in the group.
    pub async fn roster(&self, client: &reqwest::Client) -> Result<Vec<Runner>> {
        let mut runners = Vec::new();
        for page in 1.. {
            let url = format!(
                "{API}/orgs/{}/actions/runner-groups/{}/runners?per_page=100&page={page}",
                self.org, self.group_id
            );
            let body = http::call(client, Method::GET, &url, &self.token, &HEADERS, None).await?;
            let rows = body.get("runners").and_then(Value::as_array).cloned().unwrap_or_default();
            runners.extend(rows.iter().filter_map(parse_runner));
            if rows.len() < 100 {
                break;
            }
        }
        Ok(runners)
    }
}

pub fn parse_runner(row: &Value) -> Option<Runner> {
    Some(Runner {
        name: row.get("name")?.as_str()?.to_owned(),
        online: row.get("status").and_then(Value::as_str) == Some("online"),
        busy: row.get("busy").and_then(Value::as_bool).unwrap_or(false),
    })
}
