//! Which user a role process runs as (server.md 5.1, "Root"). A supervisor
//! that runs as root (system mode on a VM) starts every role as the work
//! user. Roles never run as root (v1 rule).

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
    /// The supervisor's own user (never root).
    Inherit,
    /// setgroups(0), setgid, setuid before exec.
    Drop(WorkUser),
}

/// Decides the identity for a role. `euid` is the supervisor's.
pub fn identity_for(euid: u32, work: Option<&WorkUser>) -> Result<Identity, String> {
    if euid != 0 {
        return Ok(Identity::Inherit);
    }
    match work {
        Some(user) if user.uid != 0 => Ok(Identity::Drop(user.clone())),
        _ => Err("no work user to run this role as under a root supervisor; \
                  roles never run as root"
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
        assert_eq!(identity_for(0, Some(&work())), Ok(Identity::Drop(work())));
    }

    #[test]
    fn a_root_supervisor_without_a_work_user_refuses_every_role() {
        assert!(identity_for(0, None).unwrap_err().contains("never run as root"));
        let root = WorkUser { uid: 0, ..work() };
        assert!(identity_for(0, Some(&root)).is_err());
    }

    #[test]
    fn a_user_supervisor_keeps_its_user() {
        assert_eq!(identity_for(501, Some(&work())), Ok(Identity::Inherit));
        assert_eq!(identity_for(501, None), Ok(Identity::Inherit));
    }
}
