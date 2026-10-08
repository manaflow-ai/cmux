//! The person's view of the cookie backups (crate::cookie_backups): list
//! them, and delete them only with a confirmation. Both are user-origin
//! ops (the origin comes from the connection, never from the request); an
//! agent, script or remote caller is refused, so an agent cannot remove the
//! undo of what it cleared.
//!
//! `browser.cookieBackups.purge {restoreId} | {all: true}` without
//! `confirm` deletes nothing: it answers what would go (no cookie values)
//! and a one-time `confirm` token for exactly that request, valid for two
//! minutes. The same request with that token deletes. A new request
//! replaces the pending one. A purge that deleted is logged in the host's
//! private-data log (crate::private_data_log), which `list` answers as
//! `log`.

use super::{Caller, Host};
use crate::cookie_backups::{self, CookieBackups};
use crate::protocol::{DriverError, ErrorCode};
use serde_json::{Value, json};
use std::sync::{Arc, PoisonError};
use std::time::{Duration, Instant};

const CONFIRM_FOR: Duration = Duration::from_secs(120);

/// A purge the person was asked to confirm.
pub(super) struct Pending {
    token: String,
    target: String,
    until: Instant,
}

fn refuse_agent(caller: &Caller, op: &str) -> Result<(), DriverError> {
    if caller.origin == "user" {
        return Ok(());
    }
    Err(DriverError::new(
        ErrorCode::Forbidden,
        format!(
            "{op}: only the person (user origin) manages cookie backups; restore a backup with its restoreId instead"
        ),
    ))
}

impl Host {
    fn backups(&self) -> Result<Arc<CookieBackups>, DriverError> {
        match &self.cookie_backups {
            Some(backups) => Ok(backups.clone()),
            None => cookie_backups::shared()
                .map_err(|message| DriverError::new(ErrorCode::Unsupported, message)),
        }
    }

    pub(super) fn cookie_backups_list(&self, caller: &Caller) -> Result<Value, DriverError> {
        refuse_agent(caller, "browser.cookieBackups.list")?;
        Ok(json!({
            "backups": self.backups()?.list(cookie_backups::now_secs()),
            "log": self.private_data.entries(),
        }))
    }

    pub(super) fn cookie_backups_purge(
        &self,
        caller: &Caller,
        params: &Value,
    ) -> Result<Value, DriverError> {
        const OP: &str = "browser.cookieBackups.purge";
        refuse_agent(caller, OP)?;
        let backups = self.backups()?;
        let target = match (params.get("restoreId").and_then(Value::as_str), params.get("all")) {
            (Some(id), None) => id.to_owned(),
            (None, Some(Value::Bool(true))) => "*".to_owned(),
            _ => {
                return Err(DriverError::invalid(format!(
                    "{OP}: name one backup ({{restoreId}}) or {{all: true}}"
                )));
            }
        };
        let affected: Vec<Value> = backups
            .list(cookie_backups::now_secs())
            .into_iter()
            .filter(|backup| target == "*" || backup["restoreId"] == target.as_str())
            .collect();
        let mut pending = self.purge_pending.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(confirm) = params.get("confirm").and_then(Value::as_str) else {
            let mut bytes = [0u8; 16];
            getrandom::fill(&mut bytes)
                .map_err(|e| DriverError::new(ErrorCode::Unsupported, e.to_string()))?;
            let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
            *pending =
                Some(Pending { token: token.clone(), target, until: Instant::now() + CONFIRM_FOR });
            return Ok(json!({"confirm": token, "backups": affected, "deleted": 0}));
        };
        let confirmed = pending
            .take()
            .filter(|p| p.token == confirm && p.target == target && Instant::now() <= p.until);
        if confirmed.is_none() {
            return Err(DriverError::invalid(format!(
                "{OP}: the confirmation does not match this request or expired; ask again without confirm"
            )));
        }
        let mut removed = Vec::new();
        let mut failed = None;
        for backup in &affected {
            if let Some(id) = backup["restoreId"].as_str() {
                match backups.remove(id) {
                    Ok(()) => removed.push(id.to_owned()),
                    Err(error) => {
                        failed = Some(error);
                        break;
                    }
                }
            }
        }
        // A purge is a host op with no session: its entry goes to the host
        // log only the person reads (crate::private_data_log), also when it
        // stopped part way.
        self.private_data.push(json!({
            "op": "cookieBackups.purge",
            "restoreIds": removed,
            "deleted": removed.len(),
            "actor": caller.actor,
            "origin": caller.origin,
            "at": std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |elapsed| elapsed.as_millis() as u64),
        }));
        if let Some(error) = failed {
            return Err(DriverError::new(ErrorCode::Unsupported, error));
        }
        Ok(json!({"deleted": removed.len()}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::Engines;

    struct NoEngines;
    impl Engines for NoEngines {
        fn driver(
            &self,
            _: &str,
            _: crate::driver::EventSink,
            _: &crate::host::SessionContext,
        ) -> Result<Arc<dyn crate::driver::Driver>, DriverError> {
            Err(DriverError::unsupported_method("driver"))
        }
    }

    fn caller(origin: &str) -> Caller {
        Caller {
            actor: "t".into(),
            on_behalf_of: None,
            origin: origin.into(),
            locality: crate::locality::CallerLocality::Local,
        }
    }

    fn host(name: &str) -> (Host, Arc<CookieBackups>, std::path::PathBuf) {
        let dir =
            std::env::temp_dir().join(format!("cmux-cookie-purge-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let backups = Arc::new(CookieBackups::open(&dir).unwrap());
        let host = Host::new(Arc::new(NoEngines), "/tmp").with_cookie_backups(backups.clone());
        (host, backups, dir)
    }

    fn backup(backups: &CookieBackups) -> String {
        backups
            .save(&json!({"site": "a.test", "store": null, "createdAt": 1, "cookies": [
                {"name": "sid", "value": "v", "domain": "a.test", "path": "/", "session": true}]}))
            .unwrap()
    }

    #[test]
    fn only_the_person_lists_or_purges_cookie_backups() {
        let (host, backups, dir) = host("origin");
        let id = backup(&backups);
        for origin in ["cli", "mcp", "script", "remote"] {
            for (op, params) in [
                ("browser.cookieBackups.list", json!({})),
                ("browser.cookieBackups.purge", json!({"restoreId": id})),
                ("browser.cookieBackups.purge", json!({"all": true, "confirm": "x"})),
            ] {
                let refused = host.dispatch(&caller(origin), op, &params).unwrap_err();
                assert_eq!(refused.code, ErrorCode::Forbidden, "{origin} {op}");
            }
        }
        assert!(backups.load(&id).is_ok(), "no agent removed the backup");
        let listed =
            host.dispatch(&caller("user"), "browser.cookieBackups.list", &json!({})).unwrap();
        assert_eq!(listed["backups"][0]["restoreId"], id.as_str());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_purge_deletes_only_after_its_own_confirmation() {
        let (host, backups, dir) = host("confirm");
        let (a, b) = (backup(&backups), backup(&backups));
        let purge =
            |params: Value| host.dispatch(&caller("user"), "browser.cookieBackups.purge", &params);
        let asked = purge(json!({"restoreId": a})).unwrap();
        assert_eq!(asked["deleted"], 0);
        assert_eq!(asked["backups"].as_array().unwrap().len(), 1);
        let token = asked["confirm"].as_str().unwrap().to_owned();
        assert!(backups.load(&a).is_ok(), "asking deletes nothing");
        // A token confirms only its own request, once.
        assert!(purge(json!({"all": true, "confirm": token})).is_err());
        assert!(backups.load(&a).is_ok() && backups.load(&b).is_ok());
        let token = purge(json!({"restoreId": a})).unwrap()["confirm"].as_str().unwrap().to_owned();
        assert_eq!(purge(json!({"restoreId": a, "confirm": token})).unwrap()["deleted"], 1);
        assert!(backups.load(&a).is_err() && backups.load(&b).is_ok());
        assert!(purge(json!({"restoreId": a, "confirm": token})).is_err(), "used once");
        let token = purge(json!({"all": true})).unwrap()["confirm"].as_str().unwrap().to_owned();
        assert_eq!(purge(json!({"all": true, "confirm": token})).unwrap()["deleted"], 1);
        assert!(backups.ids().is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_purge_is_logged_where_the_person_reads_it() {
        let (host, backups, dir) = host("log");
        let (a, _b) = (backup(&backups), backup(&backups));
        let user = caller("user");
        let purge = |params: Value| host.dispatch(&user, "browser.cookieBackups.purge", &params);
        let token = purge(json!({"restoreId": a})).unwrap()["confirm"].as_str().unwrap().to_owned();
        let log = |host: &Host| {
            host.dispatch(&user, "browser.cookieBackups.list", &json!({})).unwrap()["log"].clone()
        };
        assert_eq!(log(&host), json!([]), "asking deletes nothing and logs nothing");
        purge(json!({"restoreId": a, "confirm": token})).unwrap();
        let entries = log(&host);
        let entries = entries.as_array().unwrap();
        assert_eq!(entries.len(), 1, "{entries:?}");
        let entry = &entries[0];
        assert_eq!(entry["op"], "cookieBackups.purge");
        assert_eq!(entry["restoreIds"], json!([a]));
        assert_eq!(entry["deleted"], 1);
        assert_eq!(entry["origin"], "user");
        assert_eq!(entry["actor"], "t");
        assert!(entry["at"].as_u64().is_some());
        assert!(!entry.to_string().contains("\"v\""), "no cookie value: {entry}");
        let _ = std::fs::remove_dir_all(dir);
    }
}
