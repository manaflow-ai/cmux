//! The LocalApp origin: the app's own agent pane on this machine, which the
//! session pool serves. Every WebSocket connection is remote-origin
//! (`Origin::Web`) unless ALL of these hold:
//!
//! 1. the listener is bound to a loopback address only, and the peer
//!    address is loopback;
//! 2. the connection's first frame is `initialize` carrying this launch's
//!    LocalApp token in `_meta.acpmux.localAppToken`, compared in constant
//!    time. The token is 32 random bytes made at every daemon start, kept
//!    only in `ACPMUX_HOME/run/localapp.token` (mode 0600, created with
//!    `O_EXCL`), never returned by any RPC, never sent to or stored by a
//!    peer, a relay or `acpmux host setup`;
//! 3. the WebSocket `Origin` header is exactly the bundled page's origin
//!    (`cmux-agent://pane`) or an explicit `--allow-dev-origin` value, one
//!    header, never a wildcard;
//! 4. an absent `Origin` header is never local: local clients that are not
//!    browsers use the unix socket. Peer daemons, ssh tunnels and relays
//!    send none, so they stay remote-origin even with the token.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};

/// Where the LocalApp token of `home` lives.
pub fn token_path(home: &Path) -> PathBuf {
    home.join("run").join("localapp.token")
}

/// The `_meta.acpmux` field the first frame carries the token in.
pub const TOKEN_FIELD: &str = "localAppToken";

/// This launch's LocalApp token and the page origins it may come from.
pub struct LocalAppAuth {
    token: String,
    page_origins: Vec<String>,
    path: PathBuf,
}

/// What one WebSocket connection presented.
pub struct Hello<'a> {
    /// The listener's bound address.
    pub listener: SocketAddr,
    pub peer: SocketAddr,
    /// Every `Origin` header value of the upgrade request.
    pub origins: &'a [String],
    /// The first text frame, if one arrived.
    pub first_frame: Option<&'a str>,
}

impl LocalAppAuth {
    /// Make this launch's token: remove any file a previous launch left
    /// (never following a link), then create it fresh with `O_EXCL` and mode
    /// 0600 in a private `run` directory. `page_origins` are the bundled
    /// page's origin and the explicit `--allow-dev-origin` values.
    pub fn create(home: &Path, page_origins: &[String]) -> anyhow::Result<Self> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let path = token_path(home);
        let dir = home.join("run");
        crate::agent_host::ensure_private_dir(&dir)?;
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(anyhow::anyhow!("remove stale {}: {e}", path.display())),
        }
        let mut bytes = [0u8; 32];
        {
            use std::io::Read;
            std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
        }
        let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
            .map_err(|e| anyhow::anyhow!("create {}: {e}", path.display()))?;
        f.write_all(token.as_bytes())?;
        f.sync_all()?;
        let page_origins =
            page_origins.iter().filter_map(|o| cmux_local_auth::parse_origin(o)).collect();
        Ok(Self { token, page_origins, path })
    }

    /// Whether `hello` is the local app: every condition in the module docs.
    pub fn is_local_app(&self, hello: &Hello<'_>) -> bool {
        let loopback = hello.listener.ip().is_loopback() && hello.peer.ip().is_loopback();
        let origin = match hello.origins {
            [one] => cmux_local_auth::parse_origin(one)
                .is_some_and(|o| self.page_origins.iter().any(|p| p == &o)),
            _ => false,
        };
        loopback && origin && hello.first_frame.is_some_and(|f| self.frame_has_token(f))
    }

    fn frame_has_token(&self, frame: &str) -> bool {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(frame) else { return false };
        v.get("method").and_then(serde_json::Value::as_str) == Some(crate::rpc::method::INITIALIZE)
            && v.pointer(&format!("/params/_meta/acpmux/{TOKEN_FIELD}"))
                .and_then(serde_json::Value::as_str)
                .is_some_and(|t| cmux_local_auth::tokens_match(t, &self.token))
    }

    /// The file this launch's token is in (removed when the daemon stops).
    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// `frame` without the token field, so the token never reaches the
/// protocol handler, a log or a reply.
pub fn strip_token(frame: &str) -> String {
    let Ok(mut v) = serde_json::from_str::<serde_json::Value>(frame) else {
        return frame.to_owned();
    };
    let removed = v
        .pointer_mut("/params/_meta/acpmux")
        .and_then(serde_json::Value::as_object_mut)
        .and_then(|m| m.remove(TOKEN_FIELD))
        .is_some();
    if removed { v.to_string() } else { frame.to_owned() }
}

/// Request fields that would shape a preset's harness command. The local
/// app names a preset by id only (`session/new {preset}`); with a preset,
/// any of these is refused, like a Web client's preset that shapes one.
const SHAPING_FIELDS: &[&str] = &[
    "args",
    "systemPrompt",
    "system_prompt",
    "env",
    "argv",
    "command",
    "harness",
    "harnessCommand",
];

/// Whether a `session/new` names a preset.
pub(super) fn names_preset(params: &serde_json::Value, meta: Option<&serde_json::Value>) -> bool {
    meta.and_then(|m| m.get("preset"))
        .or_else(|| params.get("preset"))
        .is_some_and(|p| !p.is_null())
}

/// The cwd a LocalApp preset session runs in: the caller's path must be
/// absolute and resolve to an existing directory; the harness gets the
/// canonical path (symlinks resolved, no `..`), never the caller's string.
pub(super) async fn canonical_cwd(
    given: &std::path::Path,
) -> Result<std::path::PathBuf, crate::rpc::RpcError> {
    // RED stub: the caller's string, unchecked.
    Ok(given.to_path_buf())
}

pub(super) fn preset_by_id_only(
    params: &serde_json::Value,
    meta: Option<&serde_json::Value>,
) -> Result<(), crate::rpc::RpcError> {
    let preset = meta
        .and_then(|m| m.get("preset"))
        .or_else(|| params.get("preset"))
        .is_some_and(|p| !p.is_null());
    if !preset {
        return Ok(());
    }
    for field in SHAPING_FIELDS {
        if params.get(*field).is_some() || meta.is_some_and(|m| m.get(*field).is_some()) {
            return Err(crate::rpc::RpcError::invalid_params(format!(
                "the local app starts a preset by its id only; {field} is refused"
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const PANE: &str = "cmux-agent://pane";
    const DEV: &str = "http://127.0.0.1:5173";

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-la-{tag}-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn auth() -> (LocalAppAuth, String) {
        let home = scratch("auth");
        let auth = LocalAppAuth::create(&home, &[PANE.to_owned(), DEV.to_owned()]).unwrap();
        let token = std::fs::read_to_string(token_path(&home)).unwrap();
        (auth, token)
    }

    fn init(token: &str) -> String {
        serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": 1, "_meta": {"acpmux": {TOKEN_FIELD: token}}}})
        .to_string()
    }

    fn addr(s: &str) -> SocketAddr {
        s.parse().unwrap()
    }

    /// Every condition holds; each test below breaks exactly one.
    fn verdict(
        auth: &LocalAppAuth,
        listener: &str,
        peer: &str,
        origins: &[&str],
        frame: Option<&str>,
    ) -> bool {
        let origins: Vec<String> = origins.iter().map(|s| s.to_string()).collect();
        auth.is_local_app(&Hello {
            listener: addr(listener),
            peer: addr(peer),
            origins: &origins,
            first_frame: frame,
        })
    }

    #[test]
    fn all_conditions_make_the_local_app() {
        let (auth, token) = auth();
        let frame = init(&token);
        assert!(verdict(&auth, "127.0.0.1:47811", "127.0.0.1:50000", &[PANE], Some(&frame)));
        assert!(verdict(&auth, "[::1]:47811", "[::1]:50000", &[PANE], Some(&frame)));
        // The explicit dev page origin counts like the bundled page.
        assert!(verdict(&auth, "127.0.0.1:47811", "127.0.0.1:50000", &[DEV], Some(&frame)));
    }

    #[test]
    fn a_listener_that_is_not_loopback_only_is_not_local() {
        let (auth, token) = auth();
        let frame = init(&token);
        assert!(!verdict(&auth, "0.0.0.0:47811", "127.0.0.1:50000", &[PANE], Some(&frame)));
        assert!(!verdict(&auth, "192.168.1.5:47811", "127.0.0.1:50000", &[PANE], Some(&frame)));
    }

    #[test]
    fn a_peer_that_is_not_loopback_is_not_local() {
        let (auth, token) = auth();
        let frame = init(&token);
        assert!(!verdict(&auth, "127.0.0.1:47811", "10.0.0.7:50000", &[PANE], Some(&frame)));
    }

    #[test]
    fn a_wrong_missing_or_late_token_is_not_local() {
        let (auth, token) = auth();
        let ok = ("127.0.0.1:47811", "127.0.0.1:50000");
        let wrong = init(&"0".repeat(64));
        assert!(!verdict(&auth, ok.0, ok.1, &[PANE], Some(&wrong)));
        let empty = init("");
        assert!(!verdict(&auth, ok.0, ok.1, &[PANE], Some(&empty)));
        let none =
            serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
                .to_string();
        assert!(!verdict(&auth, ok.0, ok.1, &[PANE], Some(&none)));
        assert!(!verdict(&auth, ok.0, ok.1, &[PANE], None), "no first frame");
        // The token in a first frame that is not `initialize`.
        let other = init(&token).replace("\"initialize\"", "\"_acpmux/status\"");
        assert!(!verdict(&auth, ok.0, ok.1, &[PANE], Some(&other)));
        // A token from another launch.
        let (_, previous) = auth_with_new_launch();
        assert!(!verdict(&auth, ok.0, ok.1, &[PANE], Some(&init(&previous))));
    }

    fn auth_with_new_launch() -> (LocalAppAuth, String) {
        auth()
    }

    #[test]
    fn a_foreign_wildcard_or_doubled_origin_is_not_local() {
        let (auth, token) = auth();
        let frame = init(&token);
        let ok = ("127.0.0.1:47811", "127.0.0.1:50000");
        // The dashboard page (the listener's own origin) is not the app.
        assert!(!verdict(&auth, ok.0, ok.1, &["http://127.0.0.1:47811"], Some(&frame)));
        assert!(!verdict(&auth, ok.0, ok.1, &["https://example.com"], Some(&frame)));
        assert!(!verdict(&auth, ok.0, ok.1, &["*"], Some(&frame)));
        assert!(!verdict(&auth, ok.0, ok.1, &["null"], Some(&frame)));
        assert!(!verdict(&auth, ok.0, ok.1, &[PANE, PANE], Some(&frame)));
    }

    #[test]
    fn a_missing_origin_is_not_local_even_with_the_token() {
        // Peer daemons, ssh tunnels and relays send no Origin header.
        let (auth, token) = auth();
        let frame = init(&token);
        assert!(!verdict(&auth, "127.0.0.1:47811", "127.0.0.1:50000", &[], Some(&frame)));
    }

    #[test]
    fn the_token_is_new_at_every_launch_and_private() {
        use std::os::unix::fs::PermissionsExt;
        let home = scratch("launch");
        let first = LocalAppAuth::create(&home, &[PANE.to_owned()]).unwrap();
        let a = std::fs::read_to_string(token_path(&home)).unwrap();
        let mode = std::fs::metadata(token_path(&home)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert_eq!(a.len(), 64, "32 random bytes");
        let second = LocalAppAuth::create(&home, &[PANE.to_owned()]).unwrap();
        let b = std::fs::read_to_string(token_path(&home)).unwrap();
        assert_ne!(a, b, "a new launch, a new token");
        // The previous launch's token no longer opens LocalApp.
        let hello = |frame: &str, auth: &LocalAppAuth| {
            auth.is_local_app(&Hello {
                listener: addr("127.0.0.1:1"),
                peer: addr("127.0.0.1:2"),
                origins: &[PANE.to_owned()],
                first_frame: Some(frame),
            })
        };
        assert!(!hello(&init(&a), &second));
        assert!(hello(&init(&b), &second));
        drop(first);
    }

    #[test]
    fn a_stale_link_at_the_token_path_is_replaced_never_followed() {
        let home = scratch("link");
        let target = home.join("elsewhere");
        std::fs::write(&target, "keep").unwrap();
        crate::agent_host::ensure_private_dir(&home.join("run")).unwrap();
        std::os::unix::fs::symlink(&target, token_path(&home)).unwrap();
        LocalAppAuth::create(&home, &[PANE.to_owned()]).unwrap();
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "keep");
        assert!(!std::fs::symlink_metadata(token_path(&home)).unwrap().file_type().is_symlink());
    }

    #[test]
    fn the_token_is_stripped_before_the_protocol_handler() {
        let (_, token) = auth();
        let stripped = strip_token(&init(&token));
        assert!(!stripped.contains(&token));
        assert!(stripped.contains("\"initialize\""));
    }
}
