//! The machine credential the join keeps (`acpmux host join`): `machine-credential.json` in the
//! acpmux home, written 0600 by acpmux (acpmux machine_record.rs).
//! `enable --non-interactive` signs this desktop in with it (`POST /v1/auth/machine`); the hub
//! asks cmux-platform whose it is, so no person's token is ever kept here.

use crate::Res;
use serde::Deserialize;
use std::path::{Path, PathBuf};

const FILE: &str = "machine-credential.json";

/// The fields `enable` reads; acpmux writes more.
#[derive(Deserialize)]
struct Record {
    credential: String,
    #[serde(default)]
    revoked: bool,
    /// Marked when this record was copied from another box (acpmux): it speaks for nobody here.
    #[serde(default)]
    cloned: bool,
}

/// Where the join keeps it: the home the joined machine's acpmux resolves (`ACPMUX_HOME`, else
/// its default), asked of the resolver every cmux host uses. None when no acpmux is installed
/// (the machine was never joined).
pub fn default_path() -> Option<PathBuf> {
    let user_home = PathBuf::from(std::env::var_os("HOME").filter(|v| !v.is_empty())?);
    let environment = std::env::vars().collect();
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    let acpmux = cmux_agent_pane_policy::environment::resolve(
        None,
        None,
        &environment,
        &user_home,
        uid,
        |p| p.is_file(),
    )?;
    Some(acpmux.home.join(FILE))
}

/// The credential in `path`; Ok(None) when there is no file (the machine is not joined).
pub fn read(path: &Path) -> Res<Option<String>> {
    let Some(bytes) = super::identity::read_private(path)? else {
        return Ok(None);
    };
    parse(&bytes).map(Some).map_err(|e| format!("{}: {e}", path.display()).into())
}

fn parse(bytes: &[u8]) -> Result<String, String> {
    let record: Record =
        serde_json::from_slice(bytes).map_err(|_| "not a machine credential record".to_owned())?;
    if record.revoked {
        return Err("this machine left cmux (its credential is revoked); join it again".into());
    }
    if record.cloned {
        return Err("this record was copied from another machine; join this one".into());
    }
    let credential = record.credential.trim();
    if credential.is_empty() || credential.contains(char::is_whitespace) {
        return Err("no machine credential in it".into());
    }
    Ok(credential.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_joins_record_and_refuses_one_that_speaks_for_nobody() {
        let record = |extra: &str| {
            format!(
                r#"{{"credential":"cmm_abc","machine_id":"m","team_id":"t","name":"n","hub_origin":"https://p","last_heartbeat":null,"wgPublicKey":"k"{extra}}}"#
            )
        };
        assert_eq!(parse(record("").as_bytes()).unwrap(), "cmm_abc");
        assert!(parse(record(r#","revoked":true"#).as_bytes()).unwrap_err().contains("revoked"));
        assert!(parse(record(r#","cloned":true"#).as_bytes()).unwrap_err().contains("copied"));
        assert!(parse(br#"{"credential":" "}"#).is_err());
        assert!(parse(b"[]").is_err());
    }

    #[test]
    fn a_machine_that_never_joined_has_none() {
        let path =
            std::env::temp_dir().join(format!("cmux-rd-no-join-{}", std::process::id())).join(FILE);
        assert!(read(&path).unwrap().is_none());
    }
}
