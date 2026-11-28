//! The one catalog of everything this crate declares; `emit-ir` writes it.

use crate::example::{GreetOp, GreetTicks};
use crate::git::{GitDiffOp, GitStatusChanged, GitStatusOp};
use crate::ir::{Catalog, InterfaceDecl};
use crate::router::ops::{HelloOp, InterfacesListOp, PagesListOp, ResolveOp, TokenRefreshOp};

/// The interface diff viewers read from.
pub const DIFF_SOURCE: &str = "cmux.diff.source/1";

pub fn catalog() -> Catalog {
    Catalog::builder()
        .namespace("cmux", None)
        .namespace(crate::example::APP_ID, Some(crate::example::APP_ID))
        .op::<GitStatusOp>()
        .op::<GitDiffOp>()
        .op::<HelloOp>()
        .op::<ResolveOp>()
        .op::<TokenRefreshOp>()
        .op::<InterfacesListOp>()
        .op::<PagesListOp>()
        .op::<GreetOp>()
        .event::<GitStatusChanged>()
        .event::<GreetTicks>()
        .interface(diff_source())
        .build()
}

/// `cmux.diff.source/1`, as `cmux-tui/crates/cmux-app-host/interfaces/cmux.diff.source/1.json`
/// declares it. A later `emit-ir` loads that file instead of this copy.
fn diff_source() -> InterfaceDecl {
    InterfaceDecl {
        name: DIFF_SOURCE.into(),
        version: 1,
        docs: "Produce diff resources (git, agents, automations).".into(),
        props: serde_json::Map::new(),
        methods: [("list", "(context) -> DiffSummary[]"), ("open", "(id) -> diff_ handle")]
            .into_iter()
            .map(|(name, signature)| (name.to_owned(), signature.to_owned()))
            .collect(),
        events: vec!["diffs.changed".into()],
        status: "draft: shapes are refined with the first implementing app before the interface is public".into(),
    }
}

/// The committed IR, relative to the crate root.
pub const IR_PATH: &str = "spec/pane-protocol.json";
/// The committed conformance vectors, relative to the crate root.
pub const VECTORS_PATH: &str = "spec/pane-protocol-vectors.json";
