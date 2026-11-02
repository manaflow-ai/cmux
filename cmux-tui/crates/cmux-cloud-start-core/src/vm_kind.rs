//! The Cloud API's caller-relative `vmKind` word (the attach answer's, the app's
//! `CloudAttachEndpoint`): what it grants the signed-in caller on that machine. Only the exact
//! string `owner` opts the link out of the sandbox, starting the machine's remote chains at the VM
//! boundary (acpmux `hub/vm_boundary.rs`); only the exact `team` names a teammate's machine, and it
//! grants nothing. A missing, null or other value keeps the sandbox. A value of another type fails
//! the attach in the app's decoder before it gets here.

use serde::{Deserialize, Serialize};

/// What a `vmKind` word means for the caller.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VmKind {
    /// The caller owns the machine: the link starts with `--vm-kind owner`.
    pub owns_vm: bool,
    /// The machine is a teammate's: a chat start there is refused as one.
    pub teammate: bool,
    /// The link's arguments for it: `--vm-kind owner`, or none.
    pub link_arguments: Vec<String>,
}

/// The meaning of `kind` (absent when the server sent none or null).
pub fn read(kind: Option<&str>) -> VmKind {
    let owns_vm = kind == Some("owner");
    VmKind {
        owns_vm,
        teammate: kind == Some("team"),
        link_arguments: if owns_vm { vec!["--vm-kind".into(), "owner".into()] } else { Vec::new() },
    }
}

#[cfg(test)]
mod tests;
