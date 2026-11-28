//! Auto: which tier a chat's task gets. Pure, so the rule is the tests below.
//!
//! In order, the first that applies:
//!
//! 1. **The person's own bytes** (the chat starts from a folder on their Mac with work GitHub does
//!    not have: uncommitted or unpushed changes, or no GitHub remote): the folder must reach the
//!    machine. Past the copy's limits, and with a machine that serves `projection-v1`, it is
//!    **projected**; otherwise it is **copied** (the full checkout tier, today's copy).
//! 2. **A run over the whole tree** (a build, a full test suite, a command whose inputs are not
//!    known): **full checkout**. Every file is read anyway, and a clone reads them from GitHub in
//!    one pack.
//! 3. **A run over more paths than [`PROJECT_MAX_FILES`] or [`PROJECT_MAX_BYTES`]**: **full
//!    checkout**; projecting that much is a checkout by another name, a file at a time.
//! 4. **A GitHub repository** (an edit, a review, a targeted test of named paths): **no
//!    checkout**.
//! 5. Anything else: **full checkout**.

/// Past this many paths a projected run costs about what a clone does.
pub const PROJECT_MAX_FILES: u64 = 2_000;
/// Past this many bytes of paths a projected run costs about what a clone does.
pub const PROJECT_MAX_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tier {
    NoCheckout,
    Projection,
    Checkout,
}

impl Tier {
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::NoCheckout => "no-checkout",
            Self::Projection => "projection",
            Self::Checkout => "checkout",
        }
    }
}

/// A folder on the person's Mac the chat starts from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Folder {
    /// It holds work GitHub does not have: uncommitted or unpushed changes, or no GitHub remote.
    pub local_work: bool,
    /// It is past the copy's limits (`sync_cli/size_cap.rs`: 20 GiB or 500,000 files).
    pub past_copy_limits: bool,
}

/// What the task must run on disk.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Run {
    /// Nothing: reads, edits, a review.
    Nothing,
    /// A command over these paths only (a targeted test and the files it imports).
    Paths { files: u64, bytes: u64 },
    /// A command over the whole tree, or one whose inputs are not known.
    WholeTree,
}

/// The facts Auto decides on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Task {
    /// The work names a GitHub repository the team's GitHub connection reaches.
    pub github_repo: bool,
    pub folder: Option<Folder>,
    pub run: Run,
    /// The machine serves `projection-v1` (its `identify` capabilities).
    pub projection_served: bool,
}

/// A tier and the one sentence that says why.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Choice {
    pub tier: Tier,
    pub why: &'static str,
}

/// The Auto rule (module docs).
#[must_use]
pub fn choose(task: &Task) -> Choice {
    let pick = |tier, why| Choice { tier, why };
    if let Some(folder) = task.folder.filter(|f| f.local_work || !task.github_repo) {
        return if folder.past_copy_limits && task.projection_served {
            pick(Tier::Projection, "the folder has work only the Mac holds and is too big to copy")
        } else {
            pick(
                Tier::Checkout,
                "the folder has work only the Mac holds, and a copy of it is small",
            )
        };
    }
    match task.run {
        Run::WholeTree => {
            pick(Tier::Checkout, "the task runs over the whole tree, so every file is read anyway")
        }
        Run::Paths { files, bytes } if files > PROJECT_MAX_FILES || bytes > PROJECT_MAX_BYTES => {
            pick(Tier::Checkout, "the paths the task runs are about as big as a clone")
        }
        _ if task.github_repo => pick(
            Tier::NoCheckout,
            "a GitHub repository and a small task: read and commit through GitHub, project only what runs",
        ),
        _ => pick(Tier::Checkout, "no GitHub repository to read from"),
    }
}

#[cfg(test)]
#[path = "tier_tests.rs"]
mod tests;
