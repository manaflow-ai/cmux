//! Which user a role process runs as (server.md 5.1, "Root"). A supervisor
//! that runs as root (system mode on a VM) starts roles as the work user;
//! a role runs as root only when its config says `runAsRoot: true`.

/// The user roles run as under a root supervisor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkUser {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    pub home: std::path::PathBuf,
}

/// The identity of one role process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Identity {
    /// The supervisor's own user (not root, or `runAsRoot`).
    Inherit,
    /// setgroups(0), setgid, setuid before exec.
    Drop(WorkUser),
}

/// Decides the identity for a role. `euid` is the supervisor's.
pub fn identity_for(
    euid: u32,
    work: Option<&WorkUser>,
    run_as_root: bool,
) -> Result<Identity, String> {
    if euid != 0 || run_as_root {
        return Ok(Identity::Inherit);
    }
    match work {
        Some(user) if user.uid != 0 => Ok(Identity::Drop(user.clone())),
        _ => Err("no work user to run this role as under a root supervisor; \
                  set `runAsRoot: true` to run it as root"
            .to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn work() -> WorkUser {
        WorkUser { name: "cmux".to_owned(), uid: 1000, gid: 1000, home: "/home/cmux".into() }
    }

    #[test]
    fn a_root_supervisor_drops_roles_to_the_work_user() {
        assert_eq!(identity_for(0, Some(&work()), false), Ok(Identity::Drop(work())));
    }

    #[test]
    fn root_only_when_the_role_asks_and_never_without_a_work_user() {
        assert_eq!(identity_for(0, Some(&work()), true), Ok(Identity::Inherit));
        assert_eq!(identity_for(0, None, true), Ok(Identity::Inherit));
        assert!(identity_for(0, None, false).unwrap_err().contains("runAsRoot"));
    }

    #[test]
    fn a_user_supervisor_keeps_its_user() {
        assert_eq!(identity_for(501, Some(&work()), false), Ok(Identity::Inherit));
        assert_eq!(identity_for(501, None, false), Ok(Identity::Inherit));
    }
}
