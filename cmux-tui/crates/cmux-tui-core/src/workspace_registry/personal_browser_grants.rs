//! Browser grants of the home session (RFD 0125 D7.2): an agent borrows the
//! person's sign-in on one site of one browser profile. A row names the
//! profile, who holds it (`agent_scope` session, agent or workspace, and the
//! `holder` id in that scope), the site (a registrable domain), the tier
//! (read, act, commit), when it ends and how it was given. A row that is
//! neither revoked nor expired is a lease; the browser host enforces the
//! leases of a session (`browser.repl.leases`). Commit is never remembered:
//! a commit grant is for one session. The shared rules live in
//! `cmux-browser-grants`.

use cmux_browser_grants::{AgentScope, Lease, Leases, Tier, check_scope, expiry, grant_site};
use rusqlite::{Connection, Transaction, params};
use serde::Serialize;
use serde_json::json;

use super::personal_browser_profiles::resolve_browser_profile_id_in;
use super::personal_store::{commit_personal, subject};
use super::{WorkspaceRegistry, new_uuid_v4};

/// The table. Additive and idempotent: it runs at every open.
pub(super) fn create_browser_grant_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS browser_grants (
           id TEXT PRIMARY KEY NOT NULL,
           profile_id TEXT NOT NULL,
           agent_scope TEXT NOT NULL CHECK(agent_scope IN ('session', 'agent', 'workspace')),
           holder TEXT NOT NULL,
           site TEXT NOT NULL,
           tier TEXT NOT NULL CHECK(tier IN ('read', 'act', 'commit')),
           expires_at INTEGER NOT NULL,
           granted_via TEXT NOT NULL,
           created_at INTEGER NOT NULL,
           revoked_at INTEGER,
           CHECK(tier != 'commit' OR agent_scope = 'session')
         );
         CREATE INDEX IF NOT EXISTS browser_grants_profile ON browser_grants(profile_id, site);
         CREATE INDEX IF NOT EXISTS browser_grants_site ON browser_grants(site);",
    )?;
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BrowserGrant {
    pub id: String,
    pub profile_id: String,
    pub agent_scope: &'static str,
    pub holder: String,
    pub site: String,
    pub tier: &'static str,
    pub expires_at: u64,
    pub granted_via: String,
    pub created_at: u64,
    pub revoked_at: Option<u64>,
}

impl BrowserGrant {
    /// Not revoked and not expired at `now_ms`.
    pub fn live_at(&self, now_ms: u64) -> bool {
        self.revoked_at.is_none() && now_ms < self.expires_at
    }
}

/// Fields of a grant. `scope` defaults to session; `expires_at` to 8 hours.
#[derive(Debug, Clone, Default)]
pub struct BrowserGrantInput {
    pub profile: String,
    pub scope: Option<AgentScope>,
    /// The session, agent or workspace id the scope names.
    pub holder: String,
    pub site: String,
    pub tier: Option<Tier>,
    pub expires_at: Option<u64>,
    /// How the person gave it (`chip`, `settings`, `cli`, ...).
    pub granted_via: String,
}

/// The holders an agent session answers to, for its leases.
#[derive(Debug, Clone, Default)]
pub struct BrowserGrantHolder<'a> {
    pub session: &'a str,
    pub agent: Option<&'a str>,
    pub workspace: Option<&'a str>,
}

const COLUMNS: &str = "id, profile_id, agent_scope, holder, site, tier, expires_at, granted_via,
     created_at, revoked_at";

fn ms(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

fn sql_ms(value: u64) -> anyhow::Result<i64> {
    Ok(i64::try_from(value)?)
}

fn read_grants(
    connection: &Connection,
    filter: &str,
    args: &[&dyn rusqlite::ToSql],
) -> anyhow::Result<Vec<BrowserGrant>> {
    let sql = format!(
        "SELECT {COLUMNS} FROM browser_grants WHERE {filter} ORDER BY created_at ASC, id ASC"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(args, |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, String>(5)?,
            row.get::<_, i64>(6)?,
            row.get::<_, String>(7)?,
            row.get::<_, i64>(8)?,
            row.get::<_, Option<i64>>(9)?,
        ))
    })?;
    let mut grants = Vec::new();
    for row in rows {
        let (id, profile_id, scope, holder, site, tier, expires_at, granted_via, created, revoked) =
            row?;
        grants.push(BrowserGrant {
            id,
            profile_id,
            agent_scope: AgentScope::parse(&scope).map_err(anyhow::Error::msg)?.as_str(),
            holder,
            site,
            tier: Tier::parse(&tier).map_err(anyhow::Error::msg)?.as_str(),
            expires_at: ms(expires_at),
            granted_via,
            created_at: ms(created),
            revoked_at: revoked.map(ms),
        });
    }
    Ok(grants)
}

fn read_grant(connection: &Connection, id: &str) -> anyhow::Result<Option<BrowserGrant>> {
    Ok(read_grants(connection, "id = ?1", &[&id])?.into_iter().next())
}

impl WorkspaceRegistry {
    /// Lend `site` of a browser profile to a holder. Session scope and an
    /// 8 hour lease unless named; a commit grant is for one session only.
    pub fn grant_browser_site(
        &mut self,
        input: BrowserGrantInput,
        now_ms: u64,
    ) -> anyhow::Result<BrowserGrant> {
        let scope = input.scope.unwrap_or_default();
        let tier = input.tier.unwrap_or(Tier::Read);
        check_scope(scope, tier).map_err(anyhow::Error::msg)?;
        let site = grant_site(&input.site).map_err(anyhow::Error::msg)?;
        let expires_at =
            expiry(scope, tier, now_ms, input.expires_at).map_err(anyhow::Error::msg)?;
        let holder = input.holder.trim();
        anyhow::ensure!(!holder.is_empty(), "holder: expected the {} id", scope.as_str());
        let granted_via = input.granted_via.trim();
        anyhow::ensure!(!granted_via.is_empty(), "granted_via: expected how it was given");
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let profile_id = resolve_browser_profile_id_in(&tx, &input.profile)?;
        let id = new_uuid_v4();
        tx.execute(
            "INSERT INTO browser_grants(id, profile_id, agent_scope, holder, site, tier,
               expires_at, granted_via, created_at)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                id,
                profile_id,
                scope.as_str(),
                holder,
                site,
                tier.as_str(),
                sql_ms(expires_at)?,
                granted_via,
                sql_ms(now_ms)?
            ],
        )?;
        let grant = read_grant(&tx, &id)?.ok_or_else(|| anyhow::anyhow!("grant {id} vanished"))?;
        commit_personal(
            &tx,
            "personal.browser_grant.granted",
            vec![subject("browser_grant", &id), subject("browser_profile", &profile_id)],
            &json!({"browser_grant": grant}),
        )?;
        tx.commit()?;
        Ok(grant)
    }

    /// Revoke one grant. Revoking a revoked grant returns it unchanged
    /// with `false`.
    pub fn revoke_browser_grant(
        &mut self,
        id: &str,
        now_ms: u64,
    ) -> anyhow::Result<(BrowserGrant, bool)> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let grant =
            read_grant(&tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown browser grant {id}"))?;
        if grant.revoked_at.is_some() {
            return Ok((grant, false));
        }
        tx.execute(
            "UPDATE browser_grants SET revoked_at = ?2 WHERE id = ?1",
            params![id, sql_ms(now_ms)?],
        )?;
        let grant = read_grant(&tx, id)?.ok_or_else(|| anyhow::anyhow!("grant {id} vanished"))?;
        commit_personal(
            &tx,
            "personal.browser_grant.revoked",
            vec![subject("browser_grant", id), subject("browser_profile", &grant.profile_id)],
            &json!({"browser_grant": grant}),
        )?;
        tx.commit()?;
        Ok((grant, true))
    }

    /// Stop All: revoke every unrevoked grant on a profile. Returns the
    /// ids it revoked.
    pub fn revoke_browser_grants_for_profile(
        &mut self,
        profile: &str,
        now_ms: u64,
    ) -> anyhow::Result<Vec<String>> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let profile_id = resolve_browser_profile_id_in(&tx, profile)?;
        let ids: Vec<String> =
            read_grants(&tx, "profile_id = ?1 AND revoked_at IS NULL", &[&profile_id])?
                .into_iter()
                .map(|grant| grant.id)
                .collect();
        if ids.is_empty() {
            return Ok(ids);
        }
        tx.execute(
            "UPDATE browser_grants SET revoked_at = ?2 WHERE profile_id = ?1 AND revoked_at IS NULL",
            params![profile_id, sql_ms(now_ms)?],
        )?;
        commit_personal(
            &tx,
            "personal.browser_grant.stopped_all",
            vec![subject("browser_profile", &profile_id)],
            &json!({"browser_profile_id": profile_id, "revoked": ids}),
        )?;
        tx.commit()?;
        Ok(ids)
    }

    /// Every grant on a profile, revoked and expired ones included.
    pub fn list_browser_grants_by_profile(
        &self,
        profile: &str,
    ) -> anyhow::Result<Vec<BrowserGrant>> {
        let db = self.connection.get();
        let profile_id = resolve_browser_profile_id_in(&db, profile)?;
        read_grants(&db, "profile_id = ?1", &[&profile_id])
    }

    /// Every grant on a site (any host or URL of it), across profiles.
    pub fn list_browser_grants_by_site(&self, site: &str) -> anyhow::Result<Vec<BrowserGrant>> {
        let site = grant_site(site).map_err(anyhow::Error::msg)?;
        let db = self.connection.get();
        read_grants(&db, "site = ?1", &[&site])
    }

    /// The live leases an agent session holds on a profile: its own session
    /// grants, its agent's and its workspace's. What the browser host
    /// enforces (`browser.repl.leases`).
    pub fn live_browser_leases(
        &self,
        profile: &str,
        holder: &BrowserGrantHolder<'_>,
        now_ms: u64,
    ) -> anyhow::Result<Leases> {
        let db = self.connection.get();
        let profile_id = resolve_browser_profile_id_in(&db, profile)?;
        let now = sql_ms(now_ms)?;
        let grants = read_grants(
            &db,
            "profile_id = ?1 AND revoked_at IS NULL AND expires_at > ?2
             AND ((agent_scope = 'session' AND holder = ?3)
               OR (agent_scope = 'agent' AND holder = ?4)
               OR (agent_scope = 'workspace' AND holder = ?5))",
            &[&profile_id, &now, &holder.session, &holder.agent, &holder.workspace],
        )?;
        let leases = grants
            .into_iter()
            .map(|grant| {
                Ok(Lease {
                    tier: Tier::parse(grant.tier).map_err(anyhow::Error::msg)?,
                    site: grant.site,
                    expires_at_ms: grant.expires_at,
                })
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        Ok(Leases(leases))
    }
}

#[cfg(test)]
#[path = "personal_browser_grants_tests.rs"]
mod tests;
