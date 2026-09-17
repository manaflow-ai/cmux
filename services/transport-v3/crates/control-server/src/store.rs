use crate::{
    auth::Identity, identifier, now, Authorization, DeviceUpdate, Enrollment, Error, PolicyUpdate,
    Revocation, Signed,
};
use cmux_v3_authority::{Device, TeamPolicy, DEFAULT_POLICY};
use cmux_v3_grants::{Grant, GrantSigner, LeasePolicy, Scope};
use libp2p_identity::PeerId;
use serde::Serialize;
use sqlx::{FromRow, PgPool, Postgres, Transaction};

#[derive(Clone)]
pub struct Store(pub PgPool);
#[derive(FromRow)]
struct Team {
    revision: i64,
    cedar: String,
}
#[derive(FromRow, Serialize)]
struct Record {
    peer_id: String,
    device_id: uuid::Uuid,
    owner_user_id: String,
    active: bool,
    tags: serde_json::Value,
    lease: serde_json::Value,
}
impl Record {
    fn device(&self) -> Result<Device, Error> {
        Ok(Device {
            peer: self.peer_id.parse().map_err(|_| Error::Unavailable)?,
            owner: self.owner_user_id.clone(),
            active: self.active,
            tags: serde_json::from_value(self.tags.clone()).map_err(|_| Error::Unavailable)?,
            lease: serde_json::from_value(self.lease.clone()).map_err(|_| Error::Unavailable)?,
        })
    }
}
impl Store {
    pub async fn ready(&self) -> Result<(), Error> {
        sqlx::query("SELECT revision FROM transport_v3_teams LIMIT 1")
            .execute(&self.0)
            .await?;
        Ok(())
    }
    async fn lock(&self, identity: &Identity) -> Result<(Transaction<'_, Postgres>, Team), Error> {
        if !identifier(&identity.team) || !identifier(&identity.user) {
            return Err(Error::Denied);
        }
        let mut tx = self.0.begin().await?;
        sqlx::query("SET LOCAL statement_timeout = '5s'")
            .execute(&mut *tx)
            .await?;
        sqlx::query("SET LOCAL lock_timeout = '3s'")
            .execute(&mut *tx)
            .await?;
        // The team row serializes authorization, device updates and policy/revocation changes.
        sqlx::query(
            "INSERT INTO transport_v3_teams(team_id,cedar) VALUES($1,$2) ON CONFLICT DO NOTHING",
        )
        .bind(&identity.team)
        .bind(DEFAULT_POLICY)
        .execute(&mut *tx)
        .await?;
        let team = sqlx::query_as::<_, Team>(
            "SELECT revision,cedar FROM transport_v3_teams WHERE team_id=$1 FOR UPDATE",
        )
        .bind(&identity.team)
        .fetch_one(&mut *tx)
        .await?;
        Ok((tx, team))
    }
    async fn nonce(
        tx: &mut Transaction<'_, Postgres>,
        identity: &Identity,
        proof: &crate::proof::Proof,
    ) -> Result<(), Error> {
        let now = now();
        if proof.issued_at > now || now - proof.issued_at > 60 {
            return Err(Error::Unauthorized);
        }
        // A used proof cannot mint again after reconnecting to a different region.
        sqlx::query("INSERT INTO transport_v3_nonces(user_id,nonce,expires_at) VALUES($1,$2,$3)")
            .bind(&identity.user)
            .bind(proof.nonce)
            .bind((proof.issued_at + 120) as i64)
            .execute(&mut **tx)
            .await?;
        Ok(())
    }
    async fn event(
        tx: &mut Transaction<'_, Postgres>,
        identity: &Identity,
        revision: i64,
        action: &str,
        peer: Option<&str>,
    ) -> Result<(), Error> {
        sqlx::query("INSERT INTO transport_v3_events(team_id,revision,actor,action,peer_id) VALUES($1,$2,$3,$4,$5)")
            .bind(&identity.team).bind(revision).bind(&identity.user).bind(action).bind(peer).execute(&mut **tx).await?;
        Ok(())
    }
    pub async fn enroll(
        &self,
        identity: &Identity,
        input: &Signed<Enrollment>,
        peer: PeerId,
    ) -> Result<i64, Error> {
        if input.request.team != identity.team || input.request.device_id.is_nil() {
            return Err(Error::Denied);
        }
        let (mut tx, team) = self.lock(identity).await?;
        Self::nonce(&mut tx, identity, &input.proof).await?;
        let old=sqlx::query_as::<_,Record>("SELECT peer_id,device_id,owner_user_id,active,tags,lease FROM transport_v3_devices WHERE team_id=$1 AND peer_id=$2")
            .bind(&identity.team).bind(peer.to_string()).fetch_optional(&mut *tx).await?;
        if let Some(old) = old {
            if old.owner_user_id != identity.user
                || old.device_id != input.request.device_id
                || !old.active
            {
                return Err(Error::Denied);
            }
            tx.commit().await?;
            return Ok(team.revision);
        }
        let count: i64 =
            sqlx::query_scalar("SELECT count(*) FROM transport_v3_devices WHERE team_id=$1")
                .bind(&identity.team)
                .fetch_one(&mut *tx)
                .await?;
        if count >= 10000 {
            return Err(Error::Denied);
        }
        sqlx::query("INSERT INTO transport_v3_devices(team_id,peer_id,device_id,owner_user_id) VALUES($1,$2,$3,$4)")
            .bind(&identity.team).bind(peer.to_string()).bind(input.request.device_id).bind(&identity.user).execute(&mut *tx).await?;
        Self::event(
            &mut tx,
            identity,
            team.revision,
            "enroll",
            Some(&peer.to_string()),
        )
        .await?;
        tx.commit().await?;
        Ok(team.revision)
    }
    pub async fn owner(&self, team: &str, peer: &str) -> Result<String, Error> {
        sqlx::query_scalar("SELECT owner_user_id FROM transport_v3_devices WHERE team_id=$1 AND peer_id=$2 AND active")
            .bind(team).bind(peer).fetch_optional(&self.0).await?.ok_or(Error::Denied)
    }
    pub async fn authorize(
        &self,
        identity: &Identity,
        input: &Signed<Authorization>,
        source: PeerId,
        signer: &GrantSigner,
    ) -> Result<String, Error> {
        if input.request.team != identity.team {
            return Err(Error::Denied);
        }
        let destination: PeerId = input
            .request
            .destination
            .parse()
            .map_err(|_| Error::Invalid)?;
        let (mut tx, team) = self.lock(identity).await?;
        Self::nonce(&mut tx, identity, &input.proof).await?;
        let rows=sqlx::query_as::<_,Record>("SELECT peer_id,device_id,owner_user_id,active,tags,lease FROM transport_v3_devices WHERE team_id=$1 AND (peer_id=$2 OR peer_id=$3)")
            .bind(&identity.team).bind(source.to_string()).bind(destination.to_string()).fetch_all(&mut *tx).await?;
        let src = rows
            .iter()
            .find(|r| r.peer_id == source.to_string())
            .ok_or(Error::Denied)?;
        if !src.active || src.owner_user_id != identity.user {
            return Err(Error::Denied);
        }
        let issued = now();
        if identity.verified_at > issued || issued - identity.verified_at >= 20 {
            return Err(Error::Unavailable);
        }
        let grant = if input.request.action == "relay_reserve" {
            let exists: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM transport_v3_relays WHERE peer_id=$1 AND active)",
            )
            .bind(destination.to_string())
            .fetch_one(&mut *tx)
            .await?;
            if !exists {
                return Err(Error::Denied);
            }
            // Infrastructure admission always renews; offline endpoint permission is separate.
            Grant::new(
                Scope {
                    team: &identity.team,
                    source,
                    destination,
                    action: "relay_reserve",
                },
                team.revision as u64,
                LeasePolicy::default(),
                identity.verified_at,
                issued,
            )
            .map_err(|_| Error::Denied)?
        } else {
            let devices = rows
                .iter()
                .map(Record::device)
                .collect::<Result<Vec<_>, _>>()?;
            let policy = TeamPolicy::new(
                identity.team.clone(),
                team.revision as u64,
                identity.verified_at,
                identity.verified_at + 20,
                devices,
                &team.cedar,
            )
            .map_err(|_| Error::Unavailable)?;
            policy
                .authorize(source, destination, &input.request.action, issued)
                .map_err(|_| Error::Denied)?
        };
        let token = signer
            .sign(&grant, issued)
            .map_err(|_| Error::Unavailable)?;
        Self::event(
            &mut tx,
            identity,
            team.revision,
            "grant",
            Some(&source.to_string()),
        )
        .await?;
        tx.commit().await?;
        Ok(token)
    }
    pub async fn set_policy(&self, identity: &Identity, input: PolicyUpdate) -> Result<i64, Error> {
        if !identity.admin || input.team != identity.team {
            return Err(Error::Denied);
        }
        TeamPolicy::new(
            identity.team.clone(),
            1,
            now(),
            now() + 1,
            Vec::new(),
            &input.cedar,
        )
        .map_err(|_| Error::Invalid)?;
        let (mut tx, team) = self.lock(identity).await?;
        if team.revision != input.expected_revision {
            return Err(Error::Conflict);
        }
        let revision = team.revision.checked_add(1).ok_or(Error::Unavailable)?;
        sqlx::query("UPDATE transport_v3_teams SET revision=$2,cedar=$3 WHERE team_id=$1")
            .bind(&identity.team)
            .bind(revision)
            .bind(input.cedar)
            .execute(&mut *tx)
            .await?;
        Self::event(&mut tx, identity, revision, "policy", None).await?;
        tx.commit().await?;
        Ok(revision)
    }
    pub async fn set_device_policy(
        &self,
        identity: &Identity,
        input: DeviceUpdate,
    ) -> Result<i64, Error> {
        if !identity.admin || input.team != identity.team {
            return Err(Error::Denied);
        }
        input.lease.validate().map_err(|_| Error::Invalid)?;
        if input.tags.len() > 32
            || input.tags.iter().any(|t| !identifier(t))
            || input.peer.parse::<PeerId>().is_err()
        {
            return Err(Error::Invalid);
        }
        let (mut tx, team) = self.lock(identity).await?;
        if team.revision != input.expected_revision {
            return Err(Error::Conflict);
        }
        let changed=sqlx::query("UPDATE transport_v3_devices SET tags=$3,lease=$4 WHERE team_id=$1 AND peer_id=$2 AND active")
            .bind(&identity.team).bind(&input.peer).bind(serde_json::json!(input.tags)).bind(serde_json::json!(input.lease)).execute(&mut *tx).await?;
        if changed.rows_affected() != 1 {
            return Err(Error::Denied);
        }
        let revision =
            Self::advance(&mut tx, identity, &team, "device_policy", Some(&input.peer)).await?;
        tx.commit().await?;
        Ok(revision)
    }
    pub async fn revoke(&self, identity: &Identity, input: Revocation) -> Result<i64, Error> {
        if !identity.admin || input.team != identity.team {
            return Err(Error::Denied);
        }
        let (mut tx, team) = self.lock(identity).await?;
        if team.revision != input.expected_revision {
            return Err(Error::Conflict);
        }
        let changed = sqlx::query(
            "UPDATE transport_v3_devices SET active=false WHERE team_id=$1 AND peer_id=$2",
        )
        .bind(&identity.team)
        .bind(&input.peer)
        .execute(&mut *tx)
        .await?;
        if changed.rows_affected() != 1 {
            return Err(Error::Denied);
        }
        let revision = Self::advance(&mut tx, identity, &team, "revoke", Some(&input.peer)).await?;
        tx.commit().await?;
        Ok(revision)
    }
    async fn advance(
        tx: &mut Transaction<'_, Postgres>,
        identity: &Identity,
        team: &Team,
        action: &str,
        peer: Option<&str>,
    ) -> Result<i64, Error> {
        let revision = team.revision.checked_add(1).ok_or(Error::Unavailable)?;
        sqlx::query("UPDATE transport_v3_teams SET revision=$2 WHERE team_id=$1")
            .bind(&identity.team)
            .bind(revision)
            .execute(&mut **tx)
            .await?;
        Self::event(tx, identity, revision, action, peer).await?;
        Ok(revision)
    }
    pub async fn directory(&self, identity: &Identity) -> Result<serde_json::Value, Error> {
        let (mut tx, team) = self.lock(identity).await?;
        let rows=sqlx::query_as::<_,Record>("SELECT peer_id,device_id,owner_user_id,active,tags,lease FROM transport_v3_devices WHERE team_id=$1 ORDER BY peer_id LIMIT 10001")
            .bind(&identity.team).fetch_all(&mut *tx).await?;
        if rows.len() > 10000 {
            return Err(Error::Unavailable);
        }
        tx.commit().await?;
        Ok(serde_json::json!({"team":identity.team,"revision":team.revision,"devices":rows}))
    }
}
