//! `cmux host cloud clone-mark`: tells acpmux that this machine began as a copy of another.
//!
//! A person's second Cloud machine starts from a capture of their first (cmux-platform
//! `Seed.ts`), so it is signed in already and no login passes through a cmux server (Leo,
//! 2026-11-02: "cuz man i dont wanna be liable for peoples' subscription tokns"). The copy keeps
//! the first machine's disk: `bound.json` names the first machine, and acpmux's logs hold the
//! turn running there and the prompts queued behind it, which a restart would go on with.
//!
//! The platform writes the copy's own `bind.json` while the copy runs in quarantine (no
//! network), runs this verb as root, and powers the copy off; its cold boot binds as the new
//! machine. This verb writes acpmux's `clone-boot` marker (acpmux `hub/clone_boot.rs`) when the
//! machine `bind.json` names differs from the one `bound.json` recorded, so the daemon's first
//! start on the copy stops those turns instead of running them a second time. It runs before the
//! cold boot because acpmux is the work user's own service, which may start before cmux-host.
//!
//! The marker holds `{"from": <first machine>, "to": <this one>}`, belongs to the work user, 0600.
use super::client::Store;
use super::wire::{BIND_FILE, BOUND_FILE, Bound, parse_bind_file};

/// The marker's name in the acpmux home (acpmux `hub/clone_boot.rs` `MARKER`).
pub const MARKER_NAME: &str = "clone-boot";

/// Where the marker goes: in the work user's acpmux home (`daemon_spec::WORK_HOME`), named by
/// `role::acpmux_home`, never a literal state root (`scripts/cmux-next/check-state-roots.sh`).
#[cfg(target_os = "linux")]
pub fn marker() -> String {
    let home = super::role::acpmux_home(std::path::Path::new(crate::daemon_spec::WORK_HOME));
    home.join(MARKER_NAME).to_string_lossy().into_owned()
}

/// A copy: the machine `bound.json` recorded and the one `bind.json` names now.
#[derive(Debug, PartialEq, Eq)]
pub struct Copied {
    pub from: String,
    pub to: String,
}

/// `Some` when `bind.json` names a machine other than the one `bound.json` recorded. A machine
/// never bound, a valid bind for the same machine, or no pending bind is no copy.
pub fn copied(store: &dyn Store) -> Option<Copied> {
    let bound: Bound = serde_json::from_str(&store.read(BOUND_FILE)?).ok()?;
    let bind = parse_bind_file(&store.read(BIND_FILE)?).ok()?;
    if bound.machine.is_empty() || bound.machine == bind.machine {
        return None;
    }
    Some(Copied { from: bound.machine, to: bind.machine })
}

/// The marker's text for `copied`.
pub fn marker_text(copied: &Copied) -> String {
    format!("{}\n", serde_json::json!({"from": copied.from, "to": copied.to}))
}

#[cfg(test)]
mod tests {
    use super::super::client::MemoryStore;
    use super::*;

    use super::super::wire::Env;

    const A: &str = "vm_00000000000000000001";
    const B: &str = "vm_00000000000000000002";

    fn bind(machine: &str) -> String {
        serde_json::json!({
            "team": "team_00000000000000000001", "machine": machine,
            "bind_token": "bt_vector_one_time_token_000000000000000000",
            "env": "dev", "api_origin": Env::Dev.api_origin(),
        })
        .to_string()
    }

    fn bound(machine: &str) -> String {
        serde_json::to_string(&Bound {
            machine: machine.into(),
            team: "team_00000000000000000001".into(),
            host: "host_00000000000000000001".into(),
            epoch: 1,
            install: "inst_00000000000000000001".into(),
            user: "user_00000000000000000001".into(),
            grant: "grant_00000000000000000001".into(),
            env: Env::Dev,
            api_origin: Env::Dev.api_origin().into(),
            keyset: serde_json::Value::Null,
            bound_at: 1,
        })
        .unwrap()
    }

    fn store(files: &[(&str, String)]) -> MemoryStore {
        let mut store = MemoryStore::default();
        for (file, text) in files {
            store.write(file, text, 0o600).unwrap();
        }
        store
    }

    #[test]
    fn a_bind_for_another_machine_is_a_copy() {
        let s = store(&[(BOUND_FILE, bound(A)), (BIND_FILE, bind(B))]);
        let copied = copied(&s).unwrap();
        assert_eq!(copied, Copied { from: A.into(), to: B.into() });
        let text: serde_json::Value = serde_json::from_str(&marker_text(&copied)).unwrap();
        assert_eq!(text, serde_json::json!({"from": A, "to": B}));
    }

    #[test]
    fn the_same_machine_a_fresh_one_or_no_bind_is_no_copy() {
        assert_eq!(copied(&store(&[(BOUND_FILE, bound(A)), (BIND_FILE, bind(A))])), None);
        assert_eq!(copied(&store(&[(BIND_FILE, bind(A))])), None);
        assert_eq!(copied(&store(&[(BOUND_FILE, bound(A))])), None);
        // A bind file that does not parse is no evidence either way.
        assert_eq!(copied(&store(&[(BOUND_FILE, bound(A)), (BIND_FILE, "{}".to_owned())])), None);
    }
}
