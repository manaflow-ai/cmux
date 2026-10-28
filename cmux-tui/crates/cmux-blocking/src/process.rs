//! `std::process` waits through [`scoped_blocking_call`].

use std::io;
use std::process::{Child, Command, ExitStatus, Output};

use crate::{BlockingKind, scoped_blocking_call};

/// `Command::output`: runs the child to exit.
#[track_caller]
pub fn output(command: &mut Command) -> io::Result<Output> {
    scoped_blocking_call("process::output", BlockingKind::ProcessWait, || command.output())
}

/// `Command::status`: runs the child to exit.
#[track_caller]
pub fn status(command: &mut Command) -> io::Result<ExitStatus> {
    scoped_blocking_call("process::status", BlockingKind::ProcessWait, || command.status())
}

/// `Child::wait`.
#[track_caller]
pub fn wait(child: &mut Child) -> io::Result<ExitStatus> {
    scoped_blocking_call("process::wait", BlockingKind::ProcessWait, || child.wait())
}

/// `Child::wait_with_output`.
#[track_caller]
pub fn wait_with_output(child: Child) -> io::Result<Output> {
    scoped_blocking_call("process::wait_with_output", BlockingKind::ProcessWait, || {
        child.wait_with_output()
    })
}
