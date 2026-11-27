//! What a child's descriptor 0, 1 or 2 is connected to.

use std::fs::File;
#[cfg(unix)]
use std::os::fd::OwnedFd;

/// What a child's stdin, stdout or stderr is connected to, as
/// `std::process::Stdio`.
#[derive(Debug)]
pub struct Stdio(pub(crate) Kind);

#[derive(Debug)]
pub(crate) enum Kind {
    /// `/dev/null`.
    Null,
    /// This process's own descriptor of the same number.
    Inherit,
    /// A new pipe; the parent end lands in [`crate::Child`].
    Piped,
    /// This descriptor (the child gets a copy).
    #[cfg(unix)]
    Fd(OwnedFd),
    /// A `std::process::Stdio` (Windows: handles have no `OwnedFd`).
    #[cfg(not(unix))]
    Std(std::process::Stdio),
}

impl Stdio {
    /// Connect the stream to `/dev/null`.
    pub fn null() -> Self {
        Self(Kind::Null)
    }

    /// Give the child this process's descriptor of the same number.
    pub fn inherit() -> Self {
        Self(Kind::Inherit)
    }

    /// Connect the stream to a new pipe whose other end is in
    /// [`crate::Child`]'s `stdin`, `stdout` or `stderr`.
    pub fn piped() -> Self {
        Self(Kind::Piped)
    }

    /// The `std::process::Stdio` the std path of [`crate::Command`] uses.
    #[cfg(not(target_vendor = "apple"))]
    pub(crate) fn into_std(self) -> std::process::Stdio {
        match self.0 {
            Kind::Null => std::process::Stdio::null(),
            Kind::Inherit => std::process::Stdio::inherit(),
            Kind::Piped => std::process::Stdio::piped(),
            #[cfg(unix)]
            Kind::Fd(fd) => std::process::Stdio::from(fd),
            #[cfg(not(unix))]
            Kind::Std(stdio) => stdio,
        }
    }
}

#[cfg(unix)]
impl From<OwnedFd> for Stdio {
    fn from(fd: OwnedFd) -> Self {
        Self(Kind::Fd(fd))
    }
}

#[cfg(unix)]
impl From<File> for Stdio {
    fn from(file: File) -> Self {
        Self(Kind::Fd(file.into()))
    }
}

#[cfg(not(unix))]
impl From<File> for Stdio {
    fn from(file: File) -> Self {
        Self(Kind::Std(file.into()))
    }
}

#[cfg(unix)]
impl From<std::process::ChildStdout> for Stdio {
    fn from(stdout: std::process::ChildStdout) -> Self {
        Self(Kind::Fd(stdout.into()))
    }
}

#[cfg(unix)]
impl From<std::process::ChildStderr> for Stdio {
    fn from(stderr: std::process::ChildStderr) -> Self {
        Self(Kind::Fd(stderr.into()))
    }
}

#[cfg(unix)]
impl From<std::process::ChildStdin> for Stdio {
    fn from(stdin: std::process::ChildStdin) -> Self {
        Self(Kind::Fd(stdin.into()))
    }
}
