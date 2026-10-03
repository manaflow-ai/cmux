//! The spec's example (spec/team-vm.md, "Permission hierarchy"): Lawrence is admin of team
//! `acme`, Austin writes project `acme.web`, Aziz is a plain member, Austin's ordinary agents run
//! as `austin-agents`. Shared by the model test and the root test.
#![allow(dead_code)]

use cmux_team_host::Directory;

pub fn acme() -> Directory {
    serde_json::from_str(include_str!("../fixtures/acme.json")).expect("fixture parses")
}

pub const USERS: [&str; 4] = ["lawrence", "austin", "austin-agents", "aziz"];

/// Path under the team root, then the access of each of [`USERS`] (`rwx`, `r-x` or `---`).
pub const MATRIX: [(&str, [&str; 4]); 5] = [
    ("t/acme", ["rwx", "r-x", "r-x", "r-x"]),
    ("t/acme/p/web", ["rwx", "rwx", "rwx", "r-x"]),
    ("t/acme/p/web/p/checkout", ["rwx", "rwx", "rwx", "r-x"]),
    ("memory/people/austin", ["---", "rwx", "rwx", "---"]),
    ("memory/org", ["rwx", "rwx", "rwx", "rwx"]),
];
