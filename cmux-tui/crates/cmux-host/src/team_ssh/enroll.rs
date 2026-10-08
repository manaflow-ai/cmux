//! `cmux host team-enroll` (vm-image.md 6b): the guest half of the team VM
//! bind. TeamVmDO runs it through the provider exec API on this exact VM, so
//! the channel proves which machine answers; nothing secret is baked or
//! pushed.
//!
//! - `--team T --epoch E --nonce N`: prints one JSON line
//!   `{instance_id, public_jwk, signature}`, an ES256 signature by this
//!   clone's team install key over [`bind_message`], and remembers the
//!   (team, epoch) it answered for.
//! - `--commit --team T --epoch E --user U --install I --api ORIGIN --env ENV`:
//!   after TeamVmDO checked the proof and registered the install, it tells
//!   the VM its user and install ids. Written only for the clone and the
//!   (team, epoch) of the last enroll, and only for the environment's own API
//!   origin. The sync loop ([`super::sync`]) then gets tokens by signing auth
//!   challenges with the key.
//!
//! The instance id is the one the bind agent bound this clone to
//! (`/etc/cmux/daemon-instance-id`), not a second metadata read (the agent is
//! the single metadata reader); a parked machine (the bake's id) refuses.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use cmux_server_core::install_key::{InstallKey, SystemRandom};

use crate::cloud::wire::Env;
use crate::config::{BAKE_INSTANCE_FILE, BOUND_INSTANCE_FILE, Paths};

use super::store::write_atomic;

/// This clone's team install key: `{instance_id, pkcs8}` (base64url), 0600.
pub const TEAM_KEY_FILE: &str = "/var/lib/cmux/team-install-key.json";
/// The (instance, team, epoch) of the last enroll answer.
pub const TEAM_ENROLL_FILE: &str = "/var/lib/cmux/team-enroll.json";
/// What the commit step delivered ([`TeamBound`]), 0600.
pub const TEAM_BOUND_FILE: &str = "/var/lib/cmux/team-bound.json";

/// What the VM signs (backend team-vm-bind.ts `bindMessage`).
pub fn bind_message(team: &str, epoch: u64, instance: &str, nonce: &str) -> String {
    format!("cmux-team-vm-bind\n{team}\n{epoch}\n{instance}\n{nonce}")
}

/// Ids, nonces: 1 to 128 of `[A-Za-z0-9_-]` (the backend's pattern).
pub fn valid_id(s: &str) -> bool {
    (1..=128).contains(&s.len())
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// The team VM's binding, for the sync loop.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamBound {
    pub instance_id: String,
    pub team: String,
    pub epoch: u64,
    pub user: String,
    pub install: String,
    pub api_origin: String,
    pub env: Env,
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
struct EnrollRecord {
    instance_id: String,
    team: String,
    epoch: u64,
}

fn read_json<T: for<'de> Deserialize<'de>>(paths: &Paths, file: &str) -> Option<T> {
    let text = std::fs::read_to_string(paths.at(file)).ok()?;
    serde_json::from_str(&text).ok()
}

fn write_json(paths: &Paths, file: &str, value: &impl Serialize) -> Result<(), String> {
    let path = paths.at(file);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let text = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    write_atomic(&path, &text, 0o600).map_err(|e| format!("{file}: {e}"))
}

/// The instance id this clone is bound to; refused while parked or unbound.
pub fn machine_instance(paths: &Paths) -> Result<String, String> {
    let read = |f: &str| std::fs::read_to_string(paths.at(f)).ok().map(|s| s.trim().to_owned());
    let bound = read(BOUND_INSTANCE_FILE)
        .filter(|s| !s.is_empty())
        .ok_or("the machine is not bound yet")?;
    if read(BAKE_INSTANCE_FILE).as_deref() == Some(bound.as_str()) {
        return Err("the machine is parked for a snapshot".into());
    }
    crate::metadata::valid_instance_id(&bound)
        .ok_or_else(|| "the bound instance id is malformed".into())
}

/// This clone's key; a key made for another instance id is replaced.
pub fn team_key(paths: &Paths, instance: &str, rng: &SystemRandom) -> Result<InstallKey, String> {
    if let Some(saved) = read_json::<Value>(paths, TEAM_KEY_FILE)
        && saved["instance_id"] == instance
        && let Some(text) = saved["pkcs8"].as_str()
        && let Ok(key) = InstallKey::from_pkcs8_base64url(text, rng)
    {
        return Ok(key);
    }
    let key = InstallKey::generate(rng)?;
    write_json(
        paths,
        TEAM_KEY_FILE,
        &json!({ "instance_id": instance, "pkcs8": key.pkcs8_base64url() }),
    )?;
    Ok(key)
}

/// The enroll answer for (team, epoch, nonce) on clone `instance`.
pub fn enroll(
    paths: &Paths,
    instance: &str,
    team: &str,
    epoch: u64,
    nonce: &str,
) -> Result<Value, String> {
    if !valid_id(team) || !valid_id(nonce) {
        return Err("team and nonce must be 1 to 128 of [A-Za-z0-9_-]".into());
    }
    let rng = SystemRandom::new();
    let key = team_key(paths, instance, &rng)?;
    let signature = key.sign(bind_message(team, epoch, instance, nonce).as_bytes(), &rng)?;
    write_json(
        paths,
        TEAM_ENROLL_FILE,
        &EnrollRecord { instance_id: instance.into(), team: team.into(), epoch },
    )?;
    Ok(json!({ "instance_id": instance, "public_jwk": key.public_jwk(), "signature": signature }))
}

/// Writes the binding after a matching enroll on this clone.
pub fn commit(paths: &Paths, instance: &str, bound: &TeamBound) -> Result<(), String> {
    if bound.instance_id != instance {
        return Err("commit is for another clone".into());
    }
    if ![&bound.team, &bound.user, &bound.install].iter().all(|v| valid_id(v)) {
        return Err("team, user and install must be 1 to 128 of [A-Za-z0-9_-]".into());
    }
    if bound.api_origin != bound.env.api_origin() {
        return Err("api origin is not this environment's".into());
    }
    let key = read_json::<Value>(paths, TEAM_KEY_FILE).ok_or("no team key: enroll first")?;
    let enrolled =
        read_json::<EnrollRecord>(paths, TEAM_ENROLL_FILE).ok_or("no enroll on this clone")?;
    if key["instance_id"] != instance
        || enrolled
            != (EnrollRecord {
                instance_id: instance.into(),
                team: bound.team.clone(),
                epoch: bound.epoch,
            })
    {
        return Err("commit does not match this clone's last enroll".into());
    }
    write_json(paths, TEAM_BOUND_FILE, bound)
}

/// The binding for this clone, if any (a binding of another clone is ignored).
pub fn load_bound(paths: &Paths, instance: &str) -> Option<TeamBound> {
    read_json::<TeamBound>(paths, TEAM_BOUND_FILE).filter(|b| b.instance_id == instance)
}

/// `cmux host team-enroll …`.
pub fn run(args: &[String]) -> u8 {
    let mut paths = Paths::new("/");
    let mut flags = std::collections::HashMap::new();
    let mut commit_mode = false;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--commit" => commit_mode = true,
            "--root" => match it.next() {
                Some(v) => paths = Paths::new(v),
                None => return usage("--root needs a value"),
            },
            flag if flag.starts_with("--") => match it.next() {
                Some(v) => {
                    flags.insert(flag.trim_start_matches("--").to_owned(), v.clone());
                }
                None => return usage(&format!("{flag} needs a value")),
            },
            other => return usage(&format!("unexpected {other}")),
        }
    }
    let get = |k: &str| flags.get(k).cloned().unwrap_or_default();
    let Ok(epoch) = get("epoch").parse::<u64>() else { return usage("--epoch needs a number") };
    let instance = match machine_instance(&paths) {
        Ok(i) => i,
        Err(e) => return fail(&e),
    };
    if commit_mode {
        let env = match serde_json::from_value::<Env>(Value::String(get("env"))) {
            Ok(env) => env,
            Err(_) => return usage("--env must be dev, stg or prod"),
        };
        let bound = TeamBound {
            instance_id: instance.clone(),
            team: get("team"),
            epoch,
            user: get("user"),
            install: get("install"),
            api_origin: get("api"),
            env,
        };
        return match commit(&paths, &instance, &bound) {
            Ok(()) => {
                println!("{}", json!({ "committed": true }));
                0
            }
            Err(e) => fail(&e),
        };
    }
    match enroll(&paths, &instance, &get("team"), epoch, &get("nonce")) {
        Ok(proof) => {
            println!("{proof}");
            0
        }
        Err(e) => fail(&e),
    }
}

fn usage(msg: &str) -> u8 {
    eprintln!(
        "cmux host team-enroll: {msg}\nusage: cmux host team-enroll --team T --epoch E --nonce N | --commit --team T --epoch E --user U --install I --api ORIGIN --env dev|stg|prod"
    );
    2
}

fn fail(msg: &str) -> u8 {
    eprintln!("cmux host team-enroll: {msg}");
    1
}
