//! Git-distributed modules: where a module comes from, what it is pinned to,
//! what its tree contains, and what the user must approve before it runs.
//!
//! Pure logic only. The supervisor does the I/O (it runs the [`fetch`] plans
//! with the sandboxed git, reads blobs, stages the tree) and then asks this
//! module to decide. The threat model is plans/cmux-next/module-store-threat-model.md.

pub mod digest;
pub mod fetch;
pub mod review;
pub mod source;

pub use digest::{
    FileInput, MAX_FILE_BYTES, MAX_FILES, MAX_TOTAL_BYTES, ModuleFile, TreeDigest,
    validate_module_path,
};
pub use fetch::{
    FetchPlan, TreeEntry, fetch_plan, ls_remote_plan, ls_tree_plan, parse_ls_remote, parse_ls_tree,
};
pub use review::{
    Approval, InstallPreview, ModuleKind, ScopeGrant, UpdateDecision, UpdateReview,
    check_installed, decide_update, review_install,
};
pub use source::{GitSource, Pin, Transport, is_public_host, parse_install_spec};

use crate::Issue;

/// One refused step, with a stable code (the same codes the tests pin).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
}

impl Refusal {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    /// The same refusal as a manifest-style issue at `path`.
    pub fn issue(&self, path: &str) -> Issue {
        Issue::error(path, self.code, self.message.clone())
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Refusal {}
