//! Coordinator state in SQLite (WAL). One writer: the server holds the
//! connection behind a mutex and never awaits while holding it.

use std::net::Ipv6Addr;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};

use super::CoordError;
use crate::policy::{NodeIdentity, Policy};
use crate::types::{AuditEntry, NodeState, NodeSummary};

/// Node keys expire after this long unless rotated.
pub const NODE_KEY_LIFETIME_MS: u64 = 90 * 24 * 3600 * 1000;
/// Longest auth key lifetime.
pub const MAX_AUTHKEY_TTL_MS: u64 = 90 * 24 * 3600 * 1000;

const SCHEMA: &str = "
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v INTEGER NOT NULL);
INSERT OR IGNORE INTO meta(k, v) VALUES ('version', 1);
CREATE TABLE IF NOT EXISTS tailnets(
  id TEXT PRIMARY KEY,
  net INTEGER NOT NULL UNIQUE,
  policy TEXT NOT NULL,
  policy_version INTEGER NOT NULL,
  next_host INTEGER NOT NULL,
  require_approval INTEGER NOT NULL,
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS authkeys(
  hash TEXT PRIMARY KEY,
  tailnet TEXT NOT NULL REFERENCES tailnets(id),
  tags TEXT NOT NULL,
  user_id TEXT,
  reusable INTEGER NOT NULL,
  preapproved INTEGER NOT NULL,
  expires_ms INTEGER NOT NULL,
  uses INTEGER NOT NULL DEFAULT 0,
  created_by TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS nodes(
  id TEXT PRIMARY KEY,
  tailnet TEXT NOT NULL REFERENCES tailnets(id),
  name TEXT NOT NULL,
  machine_key TEXT NOT NULL UNIQUE,
  node_key TEXT NOT NULL UNIQUE,
  host INTEGER NOT NULL,
  tags TEXT NOT NULL,
  user_id TEXT,
  state TEXT NOT NULL,
  home_relay TEXT,
  created_ms INTEGER NOT NULL,
  last_seen_ms INTEGER,
  key_expires_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS nodes_tailnet ON nodes(tailnet);
CREATE TABLE IF NOT EXISTS audit(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tailnet TEXT NOT NULL,
  ts_ms INTEGER NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  detail TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS audit_tailnet ON audit(tailnet, id);
";

/// A node row.
#[derive(Clone, Debug)]
pub struct NodeRow {
    pub id: String,
    pub tailnet: String,
    pub name: String,
    pub machine_key: [u8; 32],
    pub node_key: String,
    pub address: Ipv6Addr,
    pub tags: Vec<String>,
    pub user: Option<String>,
    pub state: NodeState,
    pub home_relay: Option<String>,
    pub last_seen_ms: Option<u64>,
    pub key_expires_ms: u64,
}

impl NodeRow {
    pub fn identity(&self) -> NodeIdentity {
        NodeIdentity { id: self.id.clone(), user: self.user.clone(), tags: self.tags.clone() }
    }

    pub fn summary(&self) -> NodeSummary {
        NodeSummary {
            id: self.id.clone(),
            name: self.name.clone(),
            address: self.address,
            tags: self.tags.clone(),
            user: self.user.clone(),
            state: self.state,
            home_relay: self.home_relay.clone(),
            last_seen_ms: self.last_seen_ms,
        }
    }
}

pub struct TailnetRow {
    pub policy: Policy,
    pub policy_text: String,
    pub policy_version: u64,
    pub require_approval: bool,
}

pub struct AuthKeyGrant {
    pub tags: Vec<String>,
    pub user: Option<String>,
    pub preapproved: bool,
}

pub struct Store {
    db: Connection,
}

fn internal(error: rusqlite::Error) -> CoordError {
    CoordError::Internal(error.to_string())
}

fn to_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn to_u64(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

/// The overlay address of host `host` in tailnet number `net`:
/// `fd7c:6d78:7766:<net>::<host>` (cmux ULA prefix plus `wf`).
pub fn address_of(net: u16, host: u64) -> Ipv6Addr {
    let host = host & 0xffff_ffff;
    Ipv6Addr::new(0xfd7c, 0x6d78, 0x7766, net, 0, 0, (host >> 16) as u16, (host & 0xffff) as u16)
}

pub fn hash_secret(secret: &str) -> String {
    hex::encode(Sha256::digest(secret.as_bytes()))
}

impl Store {
    pub fn open(path: &Path) -> Result<Self, CoordError> {
        let db = Connection::open(path).map_err(internal)?;
        db.execute_batch(SCHEMA).map_err(internal)?;
        Ok(Self { db })
    }

    pub fn version(&self) -> Result<u64, CoordError> {
        self.db
            .query_row("SELECT v FROM meta WHERE k = 'version'", [], |row| row.get::<_, i64>(0))
            .map(to_u64)
            .map_err(internal)
    }

    /// Bump the global netmap version; every long-poll wakes on it.
    pub fn bump(&self) -> Result<u64, CoordError> {
        self.db.execute("UPDATE meta SET v = v + 1 WHERE k = 'version'", []).map_err(internal)?;
        self.version()
    }

    pub fn audit(
        &self,
        tailnet: &str,
        actor: &str,
        action: &str,
        detail: &serde_json::Value,
        now: u64,
    ) -> Result<(), CoordError> {
        self.db
            .execute(
                "INSERT INTO audit(tailnet, ts_ms, actor, action, detail) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![tailnet, to_i64(now), actor, action, detail.to_string()],
            )
            .map_err(internal)?;
        Ok(())
    }

    pub fn audit_log(&self, tailnet: &str, limit: u32) -> Result<Vec<AuditEntry>, CoordError> {
        let mut statement = self
            .db
            .prepare("SELECT ts_ms, actor, action, detail FROM audit WHERE tailnet = ?1 ORDER BY id DESC LIMIT ?2")
            .map_err(internal)?;
        let rows = statement
            .query_map(params![tailnet, limit], |row| {
                let detail: String = row.get(3)?;
                Ok(AuditEntry {
                    ts_ms: to_u64(row.get(0)?),
                    actor: row.get(1)?,
                    action: row.get(2)?,
                    detail: serde_json::from_str(&detail).unwrap_or(serde_json::Value::Null),
                })
            })
            .map_err(internal)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(internal)
    }

    pub fn create_tailnet(
        &self,
        id: &str,
        require_approval: bool,
        now: u64,
    ) -> Result<(), CoordError> {
        let exists: bool = self
            .db
            .query_row("SELECT 1 FROM tailnets WHERE id = ?1", [id], |_| Ok(true))
            .optional()
            .map_err(internal)?
            .unwrap_or(false);
        if exists {
            return Err(CoordError::Conflict(format!("tailnet {id} exists")));
        }
        let net: i64 = self
            .db
            .query_row("SELECT COALESCE(MAX(net), 0) + 1 FROM tailnets", [], |row| row.get(0))
            .map_err(internal)?;
        if net > 0xffff {
            return Err(CoordError::Conflict("no tailnet numbers left".into()));
        }
        self.db
            .execute(
                "INSERT INTO tailnets(id, net, policy, policy_version, next_host, require_approval, created_ms)
                 VALUES (?1, ?2, '{}', 1, 1, ?3, ?4)",
                params![id, net, require_approval, to_i64(now)],
            )
            .map_err(internal)?;
        Ok(())
    }

    pub fn tailnet(&self, id: &str) -> Result<TailnetRow, CoordError> {
        let row = self
            .db
            .query_row(
                "SELECT policy, policy_version, require_approval FROM tailnets WHERE id = ?1",
                [id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, bool>(2)?)),
            )
            .optional()
            .map_err(internal)?
            .ok_or(CoordError::NotFound)?;
        let policy = Policy::parse(&row.0)
            .map_err(|error| CoordError::Internal(format!("stored policy: {error}")))?;
        Ok(TailnetRow {
            policy,
            policy_text: row.0,
            policy_version: to_u64(row.1),
            require_approval: row.2,
        })
    }

    pub fn set_policy(
        &self,
        id: &str,
        text: &str,
        if_version: Option<u64>,
    ) -> Result<u64, CoordError> {
        let current = self.tailnet(id)?;
        if let Some(expected) = if_version
            && expected != current.policy_version
        {
            return Err(CoordError::Conflict(format!(
                "policy version is {}, not {expected}",
                current.policy_version
            )));
        }
        let next = current.policy_version + 1;
        self.db
            .execute(
                "UPDATE tailnets SET policy = ?1, policy_version = ?2 WHERE id = ?3",
                params![text, to_i64(next), id],
            )
            .map_err(internal)?;
        Ok(next)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn mint_auth_key(
        &self,
        tailnet: &str,
        secret: &str,
        tags: &[String],
        user: Option<&str>,
        reusable: bool,
        preapproved: bool,
        expires_ms: u64,
        created_by: &str,
    ) -> Result<(), CoordError> {
        self.db
            .execute(
                "INSERT INTO authkeys(hash, tailnet, tags, user_id, reusable, preapproved, expires_ms, created_by)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    hash_secret(secret),
                    tailnet,
                    serde_json::to_string(tags).unwrap_or_default(),
                    user,
                    reusable,
                    preapproved,
                    to_i64(expires_ms),
                    created_by
                ],
            )
            .map_err(internal)?;
        Ok(())
    }

    /// Spend an auth key: valid, unexpired, for this tailnet, and unused
    /// unless reusable. The same error for every failure, so a caller
    /// learns nothing about which keys exist.
    pub fn use_auth_key(
        &self,
        tailnet: &str,
        secret: &str,
        now: u64,
    ) -> Result<AuthKeyGrant, CoordError> {
        let hash = hash_secret(secret);
        let row = self
            .db
            .query_row(
                "SELECT tags, user_id, reusable, preapproved, expires_ms, uses FROM authkeys WHERE hash = ?1 AND tailnet = ?2",
                params![hash, tailnet],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, bool>(2)?,
                        row.get::<_, bool>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                    ))
                },
            )
            .optional()
            .map_err(internal)?;
        let refused = || CoordError::Unauthorized("invalid auth key".into());
        let (tags, user, reusable, preapproved, expires, uses) = row.ok_or_else(refused)?;
        if to_u64(expires) < now || (!reusable && uses > 0) {
            return Err(refused());
        }
        // Conditional update so two concurrent registrations cannot both
        // spend a single-use key.
        let changed = self
            .db
            .execute(
                "UPDATE authkeys SET uses = uses + 1 WHERE hash = ?1 AND (reusable = 1 OR uses = 0)",
                [&hash],
            )
            .map_err(internal)?;
        if changed != 1 {
            return Err(refused());
        }
        Ok(AuthKeyGrant {
            tags: serde_json::from_str(&tags).unwrap_or_default(),
            user,
            preapproved,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub fn insert_node(
        &self,
        tailnet: &str,
        name: &str,
        machine_key: &[u8; 32],
        node_key: &str,
        grant: &AuthKeyGrant,
        state: NodeState,
        now: u64,
    ) -> Result<NodeRow, CoordError> {
        self.tailnet(tailnet)?;
        let host: i64 = self
            .db
            .query_row("SELECT next_host FROM tailnets WHERE id = ?1", [tailnet], |row| row.get(0))
            .map_err(internal)?;
        self.db
            .execute("UPDATE tailnets SET next_host = next_host + 1 WHERE id = ?1", [tailnet])
            .map_err(internal)?;
        let id = format!("n{}", crate::random_hex(8));
        let machine = crate::b64::encode_key(machine_key);
        let inserted = self.db.execute(
            "INSERT INTO nodes(id, tailnet, name, machine_key, node_key, host, tags, user_id, state, created_ms, key_expires_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                id,
                tailnet,
                name,
                machine,
                node_key,
                host,
                serde_json::to_string(&grant.tags).unwrap_or_default(),
                grant.user,
                state.as_str(),
                to_i64(now),
                to_i64(now + NODE_KEY_LIFETIME_MS)
            ],
        );
        match inserted {
            Ok(_) => {}
            Err(rusqlite::Error::SqliteFailure(failure, _))
                if failure.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                return Err(CoordError::Conflict("machine or node key already registered".into()));
            }
            Err(error) => return Err(internal(error)),
        }
        self.node(&id)?.ok_or(CoordError::NotFound)
    }

    fn row_to_node(row: &rusqlite::Row<'_>) -> rusqlite::Result<(NodeRow, i64)> {
        let machine: String = row.get(3)?;
        let tags: String = row.get(6)?;
        let state: String = row.get(8)?;
        Ok((
            NodeRow {
                id: row.get(0)?,
                tailnet: row.get(1)?,
                name: row.get(2)?,
                machine_key: crate::b64::decode_key(&machine).unwrap_or([0; 32]),
                node_key: row.get(4)?,
                address: Ipv6Addr::UNSPECIFIED,
                tags: serde_json::from_str(&tags).unwrap_or_default(),
                user: row.get(7)?,
                state: NodeState::parse(&state).unwrap_or(NodeState::Pending),
                home_relay: row.get(9)?,
                last_seen_ms: row.get::<_, Option<i64>>(10)?.map(to_u64),
                key_expires_ms: to_u64(row.get(11)?),
            },
            row.get::<_, i64>(5)?,
        ))
    }

    const NODE_COLUMNS: &str = "n.id, n.tailnet, n.name, n.machine_key, n.node_key, n.host, n.tags, n.user_id, n.state, n.home_relay, n.last_seen_ms, n.key_expires_ms, t.net";

    pub fn node(&self, id: &str) -> Result<Option<NodeRow>, CoordError> {
        let sql = format!(
            "SELECT {} FROM nodes n JOIN tailnets t ON t.id = n.tailnet WHERE n.id = ?1",
            Self::NODE_COLUMNS
        );
        self.db
            .query_row(&sql, [id], |row| {
                let (mut node, host) = Self::row_to_node(row)?;
                node.address =
                    address_of(u16::try_from(row.get::<_, i64>(12)?).unwrap_or(0), to_u64(host));
                Ok(node)
            })
            .optional()
            .map_err(internal)
    }

    pub fn nodes(&self, tailnet: &str) -> Result<Vec<NodeRow>, CoordError> {
        let sql = format!(
            "SELECT {} FROM nodes n JOIN tailnets t ON t.id = n.tailnet WHERE n.tailnet = ?1 ORDER BY n.id",
            Self::NODE_COLUMNS
        );
        let mut statement = self.db.prepare(&sql).map_err(internal)?;
        let rows = statement
            .query_map([tailnet], |row| {
                let (mut node, host) = Self::row_to_node(row)?;
                node.address =
                    address_of(u16::try_from(row.get::<_, i64>(12)?).unwrap_or(0), to_u64(host));
                Ok(node)
            })
            .map_err(internal)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(internal)
    }

    pub fn set_state(&self, tailnet: &str, id: &str, state: NodeState) -> Result<(), CoordError> {
        let changed = self
            .db
            .execute(
                "UPDATE nodes SET state = ?1 WHERE id = ?2 AND tailnet = ?3",
                params![state.as_str(), id, tailnet],
            )
            .map_err(internal)?;
        if changed == 0 { Err(CoordError::NotFound) } else { Ok(()) }
    }

    pub fn delete_node(&self, tailnet: &str, id: &str) -> Result<(), CoordError> {
        let changed = self
            .db
            .execute("DELETE FROM nodes WHERE id = ?1 AND tailnet = ?2", params![id, tailnet])
            .map_err(internal)?;
        if changed == 0 { Err(CoordError::NotFound) } else { Ok(()) }
    }

    /// Record a sighting; returns whether the home relay changed.
    pub fn touch(
        &self,
        id: &str,
        home_relay: Option<Option<&str>>,
        now: u64,
    ) -> Result<bool, CoordError> {
        self.db
            .execute("UPDATE nodes SET last_seen_ms = ?1 WHERE id = ?2", params![to_i64(now), id])
            .map_err(internal)?;
        let Some(home_relay) = home_relay else { return Ok(false) };
        let changed = self
            .db
            .execute(
                "UPDATE nodes SET home_relay = ?1 WHERE id = ?2 AND home_relay IS NOT ?1",
                params![home_relay, id],
            )
            .map_err(internal)?;
        Ok(changed > 0)
    }

    pub fn rotate(&self, id: &str, node_key: &str, now: u64) -> Result<(), CoordError> {
        let result = self.db.execute(
            "UPDATE nodes SET node_key = ?1, key_expires_ms = ?2 WHERE id = ?3",
            params![node_key, to_i64(now + NODE_KEY_LIFETIME_MS), id],
        );
        match result {
            Ok(_) => Ok(()),
            Err(rusqlite::Error::SqliteFailure(failure, _))
                if failure.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                Err(CoordError::Conflict("node key already in use".into()))
            }
            Err(error) => Err(internal(error)),
        }
    }
}
