//! `ForkSpec`: what a fork shares with its parent and what it copies, said explicitly, the way
//! `clone(2)`'s flags say it per resource (RFD 0177 §2, build 8, in cmuxterm-hq
//! `docs/rfd/0177-kernel-proc-lifecycle.md`).
//!
//! A cmux fork shares or copies six things: the context (transcript), the worktree, the machine,
//! the inbox, the token and money budget, and the owner identity that decides who answers. Each
//! fork path chose these implicitly. Here each path's choice is one preset, a pure value, and
//! every path logs it once as `mux/fork_spec` when it forks ([`log`]). Nothing reads the spec back
//! yet: this changes no behaviour, it makes every fork's sharing visible and testable.
//!
//! The presets, one per fork path today:
//! - [`Preset::Chat`]: the person's Fork Conversation, aside and `/btw` (`hub/fork.rs`);
//! - [`Preset::ChatThrough`]: Fork from Here and fork-before, a prefix of the transcript
//!   (`server/fork_through.rs`, `hub/fork_at.rs`, `hub/fork_before.rs`);
//! - [`Preset::Retarget`]: a fork onto another harness, which starts from the chat's transcript;
//! - [`Preset::SubagentFork`]: a subagent's own conversation forked into a new chat
//!   (`hub/fork_subagent.rs`);
//! - [`Preset::Subsession`]: `start_session` with `fork`, a child the parent's agent owns
//!   (`hub/subsessions.rs`);
//! - [`Preset::TerminalChat`]: Fork Conversation of a chat a terminal runs (`chat_fork.rs`);
//! - [`Preset::CloudPlace`]: a new chat placed on a fork of the parent's Cloud machine
//!   (`fork_place.rs`, RFD 0168);
//! - [`Preset::SubVm`]: a working sub-agent on a fork of the parent's machine, its changes
//!   patched back (`placement/sub_fork.rs`, RFD 0144's workload fork);
//! - [`Preset::ForkRun`]: `acpmux fork-run`, one copy-on-write machine per harness
//!   (`cli/fork_run.rs`);
//! - [`Preset::HarnessSubagent`]: a harness's own subagent (Claude's Task tool), which acpmux does
//!   not make; the RFD names it as the model preset, so it is here for comparison and tests.
//!
//! Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I
//! put in fleet wide pauses, esp when this is stuff that materially improves the app".

use serde::{Deserialize, Serialize};

/// The transcript: the parent's own (`share`), a copy the fork goes on from (`copy`), or none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Context {
    Share,
    Copy,
    None,
}

/// The checkout: the parent's folder (`share`), its own copy whose changes come back or stay
/// apart (`branch`), or none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Worktree {
    Share,
    Branch,
    None,
}

/// Where it runs: the parent's machine, a fork of it (memory and disk), or a new one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Machine {
    Same,
    Fork,
    New,
}

/// Who gets the fork's messages: its own inbox, or its parent's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Inbox {
    Own,
    Parent,
}

/// What it spends from: `carve` a part of the parent's budget, or the parent's whole budget.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", content = "tokens")]
pub enum Budget {
    Carve(u64),
    Parent,
}

/// Who answers for it: its parent (its end reaches the parent, `exit_record.rs`) or itself (the
/// person's own new chat).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Owner {
    Parent,
    #[serde(rename = "self")]
    Own,
}

/// The fork path a spec came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Preset {
    Chat,
    ChatThrough,
    Retarget,
    SubagentFork,
    Subsession,
    TerminalChat,
    CloudPlace,
    SubVm,
    ForkRun,
    HarnessSubagent,
}

/// One fork's explicit sharing: `{context, worktree, machine, inbox, budget, owner}`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForkSpec {
    pub preset: Preset,
    pub context: Context,
    pub worktree: Worktree,
    pub machine: Machine,
    pub inbox: Inbox,
    pub budget: Budget,
    pub owner: Owner,
}

impl ForkSpec {
    /// What `preset`'s path does today.
    pub const fn preset(preset: Preset) -> Self {
        use Context as C;
        use Machine as M;
        use Worktree as W;
        let (context, worktree, machine, inbox, owner) = match preset {
            // A copy of the transcript in the chat's folder, a chat of the person's own.
            Preset::Chat | Preset::ChatThrough | Preset::Retarget | Preset::SubagentFork => {
                (C::Copy, W::Share, M::Same, Inbox::Own, Owner::Own)
            }
            // The parent's agent started it in the folder it checked; its end reaches the parent.
            Preset::Subsession => (C::Copy, W::Share, M::Same, Inbox::Own, Owner::Parent),
            // The agent's own `session/fork`, resumed by the person in a new terminal.
            Preset::TerminalChat => (C::Copy, W::Share, M::Same, Inbox::Own, Owner::Own),
            // A new chat (no transcript) on a copy of the parent's machine and its checkout.
            Preset::CloudPlace => (C::None, W::Branch, M::Fork, Inbox::Own, Owner::Own),
            // The sub-agent's prompt (no transcript: `acpmux new` then `send` on the copy) on a
            // copy of the machine; its patch and report come back to the parent.
            Preset::SubVm => (C::None, W::Branch, M::Fork, Inbox::Parent, Owner::Parent),
            // One machine copy per harness from the run's prompt; `select` keeps one. With
            // `--session` each continues that chat (`cli/fork_run.rs` sets `context: copy`).
            Preset::ForkRun => (C::None, W::Branch, M::Fork, Inbox::Own, Owner::Own),
            // RFD 0177 §2(c): "subagent = share context, same machine, parent inbox".
            Preset::HarnessSubagent => (C::Share, W::Share, M::Same, Inbox::Parent, Owner::Parent),
        };
        Self { preset, context, worktree, machine, inbox, budget: Budget::Parent, owner }
    }

    /// A hub fork (`Hub::fork_with_boundary`): which of its presets the request is.
    pub const fn hub(subsession: bool, subagent: bool, retarget: bool, prefix: bool) -> Self {
        let preset = if subsession {
            Preset::Subsession
        } else if subagent {
            Preset::SubagentFork
        } else if retarget {
            Preset::Retarget
        } else if prefix {
            Preset::ChatThrough
        } else {
            Preset::Chat
        };
        Self::preset(preset)
    }
}

/// The event's name in the log.
pub const EVENT: &str = "mux/fork_spec";

/// Logs one fork's spec: `fork` the new thing (a session id, a machine id), `parent` what it
/// forked.
pub fn log(spec: &ForkSpec, parent: &str, fork: &str) {
    let json = serde_json::to_string(spec).unwrap_or_default();
    tracing::info!(event = EVENT, %parent, %fork, spec = %json, "{EVENT}");
}

#[cfg(test)]
#[path = "fork_spec_tests.rs"]
mod tests;
