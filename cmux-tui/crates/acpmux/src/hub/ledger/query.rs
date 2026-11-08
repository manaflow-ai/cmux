//! `_acpmux/ledger` reads: totals, session rows and rollups over the buckets of the days in a
//! range. Only those days are visited (`BTreeMap::range`), so a read costs the session-days in
//! range. A range is whole UTC days: a bucket counts when its day overlaps `[since, until]`.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::Arc;

use serde::Serialize;
use serde_json::Value;

use super::{DAY_MS, SessionInfo, State, Totals, vendor_of};

/// Rows a reply holds when the request names no `limit`, and the most it may ask for.
pub const DEFAULT_LIMIT: usize = 200;
pub const MAX_LIMIT: usize = 5000;
/// The range a request without `since` gets.
pub const DEFAULT_RANGE_MS: u64 = 30 * DAY_MS;

/// A rollup dimension.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Dim {
    Workspace,
    Repo,
    Pr,
    Day,
    Person,
    Vendor,
    Model,
    Account,
}

impl Dim {
    pub const ALL: [Dim; 8] = [
        Dim::Workspace,
        Dim::Repo,
        Dim::Pr,
        Dim::Day,
        Dim::Person,
        Dim::Vendor,
        Dim::Model,
        Dim::Account,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Dim::Workspace => "workspace",
            Dim::Repo => "repo",
            Dim::Pr => "pr",
            Dim::Day => "day",
            Dim::Person => "person",
            Dim::Vendor => "vendor",
            Dim::Model => "model",
            Dim::Account => "account",
        }
    }

    pub fn parse(name: &str) -> Option<Dim> {
        Dim::ALL.into_iter().find(|d| d.name() == name)
    }
}

/// What one request asks for.
#[derive(Debug, Clone, PartialEq)]
pub struct LedgerQuery {
    pub since: u64,
    pub until: u64,
    pub limit: usize,
    pub dims: Vec<Dim>,
}

impl LedgerQuery {
    /// From `{since?, until?, limit?, groupBy?}` at `now`. An unknown dimension is an error.
    pub fn from_params(params: &Value, now: u64) -> Result<Self, String> {
        let until = params.get("until").and_then(Value::as_u64).unwrap_or(now);
        let since = params
            .get("since")
            .and_then(Value::as_u64)
            .unwrap_or(until.saturating_sub(DEFAULT_RANGE_MS));
        if since > until {
            return Err("since is after until".into());
        }
        let limit = params
            .get("limit")
            .and_then(Value::as_u64)
            .map_or(DEFAULT_LIMIT, |n| (n as usize).min(MAX_LIMIT));
        let dims = match params.get("groupBy") {
            None | Some(Value::Null) => Dim::ALL.to_vec(),
            Some(Value::Array(names)) => {
                let mut dims = Vec::new();
                for name in names {
                    let name = name.as_str().ok_or("groupBy holds strings")?;
                    let dim =
                        Dim::parse(name).ok_or_else(|| format!("unknown groupBy {name:?}"))?;
                    if !dims.contains(&dim) {
                        dims.push(dim);
                    }
                }
                dims
            }
            Some(_) => return Err("groupBy is a list".into()),
        };
        Ok(Self { since, until, limit, dims })
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PriceTableRef {
    pub version: String,
    pub currency: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Range {
    pub since: u64,
    pub until: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    #[serde(flatten)]
    pub totals: Totals,
    pub session_id: String,
    pub title: Option<String>,
    pub harness: String,
    pub vendor: String,
    pub models: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    pub pull_requests: Vec<String>,
    pub person: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    pub created_at: u64,
    pub last_at: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Rollup {
    #[serde(flatten)]
    pub totals: Totals,
    pub key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LedgerReply {
    pub price_table: PriceTableRef,
    pub range: Range,
    pub totals: Totals,
    pub rows: Vec<Row>,
    pub rollups: serde_json::Map<String, Value>,
}

/// The key a session-less value rolls up under (no workspace, repository or account).
pub const NONE_KEY: &str = "none";

#[derive(Default)]
struct Acc {
    totals: Totals,
    sessions: HashSet<Arc<str>>,
}

impl Acc {
    fn add(&mut self, session: &Arc<str>, t: &Totals) {
        self.totals.add(t);
        self.sessions.insert(session.clone());
    }

    fn done(mut self) -> Totals {
        self.totals.sessions = self.sessions.len() as u64;
        self.totals
    }
}

struct RowAcc {
    totals: Totals,
    models: BTreeSet<Arc<str>>,
    last_at: u64,
}

/// The reply, and how many buckets the fold visited.
pub(crate) fn fold(state: &State, q: &LedgerQuery, person: &str) -> (LedgerReply, usize) {
    let mut visited = 0usize;
    let mut total = Acc::default();
    let mut rows: HashMap<Arc<str>, RowAcc> = HashMap::new();
    let mut rollups: HashMap<Dim, HashMap<String, Acc>> = HashMap::new();
    let none = SessionInfo::default();
    let (first, last) = (q.since / DAY_MS, q.until / DAY_MS);
    for (day, buckets) in state.days.range(first..=last) {
        let date = crate::stats::civil_date(*day as i64);
        for (key, bucket) in buckets {
            visited += 1;
            let t = &bucket.totals;
            let info = state.sessions.get(&key.session).unwrap_or(&none);
            total.add(&key.session, t);
            let row = rows.entry(key.session.clone()).or_insert_with(|| RowAcc {
                totals: Totals::default(),
                models: BTreeSet::new(),
                last_at: 0,
            });
            row.totals.add(t);
            row.models.insert(key.model.clone());
            row.last_at = row.last_at.max(bucket.last_at);
            for dim in &q.dims {
                let family = info.family.as_deref().unwrap_or(&info.harness);
                let keys: Vec<String> = match dim {
                    Dim::Workspace => vec![or_none(&info.workspace_id)],
                    Dim::Repo => vec![or_none(&info.repo)],
                    Dim::Pr => info.pull_requests.clone(),
                    Dim::Day => vec![date.clone()],
                    Dim::Person => vec![person.to_owned()],
                    Dim::Vendor => vec![vendor_of(family, &key.model)],
                    Dim::Model => vec![key.model.to_string()],
                    Dim::Account => vec![or_none(&info.account)],
                };
                let groups = rollups.entry(*dim).or_default();
                for k in keys {
                    groups.entry(k).or_default().add(&key.session, t);
                }
            }
        }
    }
    let mut out_rows: Vec<Row> = rows
        .into_iter()
        .map(|(sid, acc)| {
            let info = state.sessions.get(&sid).unwrap_or(&none);
            let family = info.family.as_deref().unwrap_or(&info.harness);
            let first_model = acc.models.iter().find(|m| &***m != "unknown");
            let mut totals = acc.totals;
            totals.sessions = 1;
            Row {
                totals,
                session_id: sid.to_string(),
                title: info.title.clone(),
                harness: info.harness.clone(),
                vendor: vendor_of(family, first_model.map_or("", |m| &**m)),
                models: acc.models.iter().map(|m| m.to_string()).collect(),
                workspace_id: info.workspace_id.clone(),
                repo: info.repo.clone(),
                branch: info.branch.clone(),
                pull_requests: info.pull_requests.clone(),
                person: person.to_owned(),
                account: info.account.clone(),
                created_at: info.created_at,
                last_at: acc.last_at,
            }
        })
        .collect();
    out_rows
        .sort_by(|a, b| b.last_at.cmp(&a.last_at).then_with(|| a.session_id.cmp(&b.session_id)));
    out_rows.truncate(q.limit);
    let mut out_rollups = serde_json::Map::new();
    for dim in &q.dims {
        let mut list: Vec<Rollup> = rollups
            .remove(dim)
            .unwrap_or_default()
            .into_iter()
            .map(|(key, acc)| {
                let label = match dim {
                    Dim::Pr => pull_label(&key),
                    _ => None,
                };
                Rollup { totals: acc.done(), key, label }
            })
            .collect();
        list.sort_by(|a, b| {
            b.totals
                .cost_usd
                .partial_cmp(&a.totals.cost_usd)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.key.cmp(&b.key))
        });
        out_rollups.insert(dim.name().into(), serde_json::to_value(list).unwrap_or_default());
    }
    let table = crate::pricing::table();
    let reply = LedgerReply {
        price_table: PriceTableRef {
            version: table.version.clone(),
            currency: table.currency.clone(),
        },
        range: Range { since: q.since, until: q.until },
        totals: total.done(),
        rows: out_rows,
        rollups: out_rollups,
    };
    (reply, visited)
}

fn or_none(v: &Option<String>) -> String {
    v.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| NONE_KEY.into())
}

/// `owner/name#N` for a pull request URL.
fn pull_label(url: &str) -> Option<String> {
    let repo = super::repo_of_pull(url)?;
    let n = url.rsplit('/').next()?;
    Some(format!("{repo}#{n}"))
}
