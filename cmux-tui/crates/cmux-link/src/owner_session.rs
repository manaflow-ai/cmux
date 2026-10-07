//! The owner-only trusted session service of a paired server
//! (plans/cmux-next/server-reach.md section 7 step 2).
//!
//! A paired peer normally reaches only the session daemon's remote entry
//! (stamped, conversations only). The server's OWNER, the user who paired
//! it, also gets [`crate::dial::Service::OwnerSession`]: the stream goes to
//! the trusted local socket of the Chief brain's daemon, so the owner's app
//! sees the brain's full tree (the subagent workspaces), as the SSH carrier
//! gives today. Nobody else does:
//!
//! - who: only a peer whose stamped identity (from the WireGuard key's
//!   pairing record, never from the stream) has the configured owner user
//!   AND team ([`OwnerSession::authorize`]);
//! - where: only the socket named in `server.json` (`owner_session`), when
//!   it is a Unix socket (not a symlink) owned by the link's own uid, inside
//!   the configured brain home ([`OwnerSession::check_socket`]), and its
//!   daemon answers `identify` as a brain daemon ([`is_brain_identity`]);
//! - otherwise the link refuses and logs; the stream reaches nothing.

use std::io;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::stamp::{LinkPeer, valid_id};

/// Capabilities a Chief brain's daemon must report (optchat-chief opens
/// subagent workspaces with agent chat tabs through them).
pub const BRAIN_CAPABILITIES: [&str; 2] = ["workspace-registry-v1", "agent-session-tabs-v1"];

/// The `owner_session` block of `server.json`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OwnerSession {
    /// The user who paired this server (the pairing's `user`).
    pub owner_user: String,
    /// The team the server was paired into.
    pub owner_team: String,
    /// The brain daemon's trusted local socket (absolute).
    pub socket: PathBuf,
    /// The brain's home; the socket must be inside it (absolute).
    pub brain_home: PathBuf,
}

/// Why an owner session stream was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnerRefused {
    /// `server.json` has no valid `owner_session` block.
    NotConfigured,
    /// The peer is not the server's owner (user and team).
    NotOwner,
    /// The socket is not inside the brain home (after resolving links).
    OutsideBrainHome,
    /// The path is missing, a symlink, or not a Unix socket.
    NotASocket,
    /// The socket is owned by another uid.
    WrongOwner,
    /// The daemon did not answer `identify` as a brain daemon.
    NotABrain,
}

#[derive(Deserialize)]
struct ServerJson {
    #[serde(default)]
    owner_session: Option<OwnerSession>,
}

impl OwnerSession {
    /// The `owner_session` block of the `server.json` at `path`; `None` when
    /// the file or the block is missing. An invalid block is an error.
    pub fn load(path: &Path) -> io::Result<Option<Self>> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        Self::parse(&text)
    }

    /// Parse a `server.json` text (other keys are the server's, ignored).
    pub fn parse(text: &str) -> io::Result<Option<Self>> {
        let json: ServerJson = serde_json::from_str(text).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let Some(block) = json.owner_session else { return Ok(None) };
        Ok(Some(block)) // RED: no validation yet
    }

    fn is_valid(&self) -> bool {
        valid_id(&self.owner_user)
            && valid_id(&self.owner_team)
            && self.socket.is_absolute()
            && self.brain_home.is_absolute()
    }

    /// The peer may open an owner session only as the owner user in the
    /// owner team. `peer` is the identity the link derived from the
    /// WireGuard key's pairing record.
    pub fn authorize(&self, peer: &LinkPeer) -> Result<(), OwnerRefused> {
        let _ = peer;
        Ok(()) // RED: no owner check yet
    }

    /// The socket to connect to, after checking it: not a symlink, a Unix
    /// socket, owned by `uid`, and inside the brain home once both paths are
    /// resolved (a symlinked parent cannot point it elsewhere).
    #[cfg(unix)]
    pub fn check_socket(&self, uid: u32) -> Result<PathBuf, OwnerRefused> {
        let _ = uid;
        Ok(self.socket.clone()) // RED: no socket checks yet
    }
}

/// The `identify` request line the link sends on a probe connection.
pub const IDENTIFY_REQUEST: &str = "{\"id\":1,\"cmd\":\"identify\"}\n";

/// Whether an `identify` reply line is from a brain daemon: an `ok` cmux-tui
/// that reports every [`BRAIN_CAPABILITIES`].
pub fn is_brain_identity(reply: &str) -> bool {
    let _ = reply;
    true // RED: no identity check yet
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn session(socket: &Path, home: &Path) -> OwnerSession {
        OwnerSession {
            owner_user: "user_owner".into(),
            owner_team: "team_a".into(),
            socket: socket.to_path_buf(),
            brain_home: home.to_path_buf(),
        }
    }

    fn peer(user: &str, team: &str) -> LinkPeer {
        LinkPeer { install: "inst_b".into(), user: user.into(), team: team.into() }
    }

    #[test]
    fn only_the_owner_user_in_the_owner_team_is_authorized() {
        let config = session(Path::new("/h/daemon/cmux.sock"), Path::new("/h"));
        assert_eq!(config.authorize(&peer("user_owner", "team_a")), Ok(()));
        assert_eq!(config.authorize(&peer("user_other", "team_a")), Err(OwnerRefused::NotOwner));
        assert_eq!(config.authorize(&peer("user_owner", "team_b")), Err(OwnerRefused::NotOwner));
    }

    #[test]
    fn server_json_block_is_optional_but_never_half_valid() -> io::Result<()> {
        assert_eq!(OwnerSession::parse(r#"{"roles":["session"]}"#)?, None);
        let parsed = OwnerSession::parse(
            r#"{"roles":[],"owner_session":{"owner_user":"user_owner","owner_team":"team_a","socket":"/h/daemon/cmux.sock","brain_home":"/h"}}"#,
        )?;
        assert_eq!(parsed, Some(session(Path::new("/h/daemon/cmux.sock"), Path::new("/h"))));
        for bad in [
            r#"{"owner_session":{"owner_user":"","owner_team":"team_a","socket":"/h/s","brain_home":"/h"}}"#,
            r#"{"owner_session":{"owner_user":"u","owner_team":"t","socket":"relative.sock","brain_home":"/h"}}"#,
            r#"{"owner_session":{"owner_user":"u","owner_team":"t","socket":"/h/s","brain_home":"/h","extra":1}}"#,
        ] {
            assert!(OwnerSession::parse(bad).is_err(), "{bad}");
        }
        Ok(())
    }

    #[test]
    fn the_socket_must_be_a_socket_of_this_uid_inside_the_brain_home() -> io::Result<()> {
        let directory = cmux_unix_socket::short_test_dir("ownses");
        let home = directory.path().join("brain");
        std::fs::create_dir_all(home.join("daemon"))?;
        let socket = home.join("daemon/s.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&socket)?;
        let uid = unsafe { libc::geteuid() };
        let config = session(&socket, &home);
        assert!(config.check_socket(uid).is_ok());
        assert_eq!(config.check_socket(uid.wrapping_add(1)), Err(OwnerRefused::WrongOwner));
        // A regular file is no socket.
        let file = home.join("daemon/file");
        std::fs::write(&file, b"x")?;
        assert_eq!(session(&file, &home).check_socket(uid), Err(OwnerRefused::NotASocket));
        // A symlink to the real socket is refused (no indirection).
        let link = home.join("daemon/link.sock");
        std::os::unix::fs::symlink(&socket, &link)?;
        assert_eq!(session(&link, &home).check_socket(uid), Err(OwnerRefused::NotASocket));
        // A real socket outside the brain home is refused.
        let outside = directory.path().join("o.sock");
        let _other = std::os::unix::net::UnixListener::bind(&outside)?;
        assert_eq!(session(&outside, &home).check_socket(uid), Err(OwnerRefused::OutsideBrainHome));
        // A symlinked parent directory cannot lead out of the brain home.
        let escape = home.join("escape");
        std::os::unix::fs::symlink(directory.path(), &escape)?;
        assert_eq!(session(&escape.join("o.sock"), &home).check_socket(uid), Err(OwnerRefused::OutsideBrainHome));
        Ok(())
    }

    #[test]
    fn only_a_cmux_tui_with_the_brain_capabilities_is_a_brain() {
        let brain = r#"{"id":1,"ok":true,"data":{"app":"cmux-tui","capabilities":["x","workspace-registry-v1","agent-session-tabs-v1"]}}"#;
        assert!(is_brain_identity(brain));
        assert!(!is_brain_identity(r#"{"id":1,"ok":true,"data":{"app":"cmux-tui","capabilities":["workspace-registry-v1"]}}"#));
        assert!(!is_brain_identity(r#"{"id":1,"ok":true,"data":{"app":"other","capabilities":["workspace-registry-v1","agent-session-tabs-v1"]}}"#));
        assert!(!is_brain_identity(r#"{"id":1,"ok":false,"data":{}}"#));
        assert!(!is_brain_identity("not json"));
    }
}
