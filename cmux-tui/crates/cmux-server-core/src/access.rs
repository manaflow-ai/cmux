//! Required owners and permissions of the server's directories, as data
//! (server.md 4.3, 7.4, 8.2).
//!
//! The I/O crate creates each path with this access and checks it again at
//! every start. When an existing path has another owner, wider permissions,
//! an extra ACL entry, or is a symlink where `no_symlink` is set, the server
//! refuses to start and reports the path; it never repairs it silently,
//! because a wrong owner on a shared directory (`/tmp`, `%ProgramData%`)
//! means someone else created it first.

use crate::layout::Layout;
use crate::platform::{HostPath, InstallMode, Platform};

/// A POSIX owner.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PosixOwner {
    Root,
    /// A named account such as the system-mode service user `cmux`.
    Named(&'static str),
    /// The installing user, by numeric id.
    Uid(u32),
    /// The account the service runs as (the installing user), when the pure
    /// layer does not know its id.
    CurrentUser,
}

/// A Windows principal.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WinPrincipal {
    /// `S-1-5-18`.
    System,
    /// `S-1-5-32-544`.
    Administrators,
    /// `S-1-5-32-545`.
    Users,
    /// The service's virtual account, `NT SERVICE\<name>`.
    Service(&'static str),
    CurrentUser,
}

impl WinPrincipal {
    /// The SID string for well-known principals, else the account name.
    pub fn as_str(self) -> String {
        match self {
            WinPrincipal::System => "S-1-5-18".to_owned(),
            WinPrincipal::Administrators => "S-1-5-32-544".to_owned(),
            WinPrincipal::Users => "S-1-5-32-545".to_owned(),
            WinPrincipal::Service(name) => format!("NT SERVICE\\{name}"),
            WinPrincipal::CurrentUser => "CURRENT_USER".to_owned(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WinRights {
    ReadExecute,
    Modify,
    Full,
}

/// One allow entry, inherited by files and subdirectories.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ace {
    pub principal: WinPrincipal,
    pub rights: WinRights,
}

/// A protected DACL (no inherited entries) with exactly these entries.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowsAcl {
    pub owner: WinPrincipal,
    pub entries: Vec<Ace>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Access {
    Posix { owner: PosixOwner, group: Option<&'static str>, mode: u32 },
    Windows(WindowsAcl),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PathAccess {
    pub path: HostPath,
    pub access: Access,
    /// The path itself must not be a symlink (shared parents like `/tmp`).
    pub no_symlink: bool,
}

fn posix(path: HostPath, owner: PosixOwner, group: Option<&'static str>, mode: u32) -> PathAccess {
    PathAccess { path, access: Access::Posix { owner, group, mode }, no_symlink: true }
}

fn windows(
    path: HostPath,
    owner: WinPrincipal,
    entries: &[(WinPrincipal, WinRights)],
) -> PathAccess {
    let entries = entries.iter().map(|&(principal, rights)| Ace { principal, rights }).collect();
    PathAccess { path, access: Access::Windows(WindowsAcl { owner, entries }), no_symlink: true }
}

/// The store root and the state directory of a layout.
///
/// Linux system mode: the store is root-owned 0755, so the long-running
/// `cmux host run` (user `cmux`) can read and run it but never write it;
/// the root `cmux-update.service` writes it (server.md 7.4). Windows system
/// mode: binaries under `%ProgramFiles%\cmux` are writable by SYSTEM and
/// administrators only; state under `%ProgramData%\cmux\server` is writable
/// by the service account and closed to other users.
pub fn access_policy(layout: &Layout) -> Vec<PathAccess> {
    use WinPrincipal::{Administrators, CurrentUser, Service, System, Users};
    use WinRights::{Full, Modify, ReadExecute};
    let user = layout.uid.map_or(PosixOwner::CurrentUser, PosixOwner::Uid);
    let root = layout.root.clone();
    let state = layout.state.clone();
    match (layout.platform, layout.mode) {
        (Platform::Linux, InstallMode::System) => vec![
            posix(root, PosixOwner::Root, Some("root"), 0o755),
            posix(state, PosixOwner::Named(crate::units::SERVICE_USER), Some("cmux"), 0o700),
        ],
        (Platform::MacOs, InstallMode::System) => vec![
            posix(root, PosixOwner::Root, Some("wheel"), 0o755),
            // The LaunchDaemon runs as the account in its `UserName`.
            posix(state, user, None, 0o700),
        ],
        (Platform::Linux | Platform::MacOs, InstallMode::User) => {
            vec![posix(root, user, None, 0o700), posix(state, user, None, 0o700)]
        }
        (Platform::Windows, InstallMode::System) => vec![
            windows(
                root,
                Administrators,
                &[(System, Full), (Administrators, Full), (Users, ReadExecute)],
            ),
            windows(
                state,
                Administrators,
                &[
                    (System, Full),
                    (Administrators, Full),
                    (Service(crate::layout::WINDOWS_SERVICE), Modify),
                ],
            ),
        ],
        (Platform::Windows, InstallMode::User) => vec![
            windows(root, CurrentUser, &[(System, Full), (CurrentUser, Full)]),
            windows(state, CurrentUser, &[(System, Full), (CurrentUser, Full)]),
        ],
    }
}

/// macOS user mode: the checks for the Postgres socket directory
/// `/tmp/cmux-<uid>/pg-<port>` and its parent (server.md 8.2). `/tmp` is
/// world-writable, so both must be real directories owned by the user with
/// mode 0700. `None` on layouts whose socket directory is not under `/tmp`.
pub fn socket_dir_check(layout: &Layout, port: u16) -> Option<Vec<PathAccess>> {
    let (Platform::MacOs, InstallMode::User, Some(uid)) =
        (layout.platform, layout.mode, layout.uid)
    else {
        return None;
    };
    let dir = layout.postgres_socket_dir(port);
    let parent = HostPath::new(Platform::MacOs, &format!("/tmp/cmux-{uid}")).expect("absolute");
    Some(vec![
        posix(parent, PosixOwner::Uid(uid), None, 0o700),
        posix(dir, PosixOwner::Uid(uid), None, 0o700),
    ])
}
