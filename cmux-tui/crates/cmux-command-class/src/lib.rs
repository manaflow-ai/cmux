//! Classifies a shell command by what it needs in order to run.
//!
//! An agent's home can run most tool calls on its own: it reads and writes the
//! workspace through a mount, reads the repository, and reaches the network
//! with its own credentials. Only some calls need the machine itself: builds,
//! tests, servers, project scripts, anything that runs project code or holds
//! machine state. This crate looks at one command string, as an agent's Bash
//! tool would run it, and says which of those it is, so a caller can keep the
//! machine asleep for everything else.
//!
//! The classifier reads the command; it never runs it. It resolves quoting,
//! follows pipelines, `&&`, `||`, `;`, subshells, `$(...)`, backticks and
//! process substitutions, looks through `VAR=val` prefixes, `cd X &&`,
//! `timeout`, `env`, `nice`, `nohup`, `time`, `command`, `xargs`,
//! `find -exec`, `eval`, and `bash -c`/`sh -c` scripts, and reads every
//! redirection. A command it does not know, or cannot parse, is
//! [`CommandClass::Machine`]: forwarding to the machine is always safe.
//!
//! Nothing calls this yet; it is the first step of the agent home.

mod lex;
mod rules;

/// What a command needs, from least to most.
///
/// A compound command (a pipeline, a `&&` chain, a subshell, a substitution)
/// runs in one place, so it takes the class of its most demanding part. The
/// order is the order of how much of the machine's state a class reaches:
///
/// 1. [`FileRead`](Self::FileRead) reads workspace files through the mount and
///    changes nothing.
/// 2. [`Network`](Self::Network) reaches past the workspace, but only to
///    remote services, with the home's own credentials; it changes nothing in
///    the workspace.
/// 3. [`GitLocal`](Self::GitLocal) reads the repository's own state (the
///    index, refs, the object store), which has to be a consistent snapshot of
///    what the machine sees, not just a file read.
/// 4. [`FileWrite`](Self::FileWrite) changes the workspace, so it has to go
///    through the mount's journal and reach the machine's copy.
/// 5. [`GitHooks`](Self::GitHooks) rewrites the index and the working tree and
///    may run the repository's hooks, which are project code.
/// 6. [`Machine`](Self::Machine) needs the machine itself: its toolchain, its
///    processes, its ports, or code the classifier can't see into.
///
/// Each class needs everything the classes before it need, so taking the
/// highest part of a compound command never under-serves the rest of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum CommandClass {
    /// Reads files: `cat`, `grep`, `rg`, `sed -n`, `head`, `ls`, `find`, `jq`.
    FileRead,
    /// Talks to a remote service: `gh`, `curl`, `ssh`, `git push`, `git fetch`,
    /// and the home tools the caller configures.
    Network,
    /// Reads the repository: `git status`, `git diff`, `git log`, `git show`.
    GitLocal,
    /// Writes files: `sed -i`, `mkdir`, `cp`, `mv`, `rm`, `tee`, a `>`
    /// redirect, and a download that saves into the workspace.
    FileWrite,
    /// Runs hooks or rewrites the index and tree: `git commit`, `git checkout`,
    /// `git merge`, `git rebase`, `git pull`, `git worktree add`.
    GitHooks,
    /// Needs the machine: builds, tests, project scripts, servers, package
    /// managers, interpreters, `sleep`, `kill`, `docker`, background jobs, and
    /// anything unknown.
    Machine,
}

impl CommandClass {
    /// Every class, from least to most demanding.
    pub const ALL: [Self; 6] = [
        Self::FileRead,
        Self::Network,
        Self::GitLocal,
        Self::FileWrite,
        Self::GitHooks,
        Self::Machine,
    ];

    /// A stable snake_case name for logs and metrics.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::FileRead => "file_read",
            Self::Network => "network",
            Self::GitLocal => "git_local",
            Self::FileWrite => "file_write",
            Self::GitHooks => "git_hooks",
            Self::Machine => "machine",
        }
    }

    /// Whether a command of this class has to run on the machine.
    pub fn needs_machine(self) -> bool {
        self >= Self::GitHooks
    }
}

/// A command's class and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Classification {
    pub class: CommandClass,
    /// The first word that decided the class, with the subcommand or flag
    /// that mattered: `cargo`, `git commit`, `sed -i`, `>`, `&`. Empty for a
    /// command that runs nothing.
    pub reason: String,
}

impl Classification {
    fn new(class: CommandClass, reason: impl Into<String>) -> Self {
        Self { class, reason: reason.into() }
    }
}

/// A classifier with the caller's list of home tools.
#[derive(Debug, Clone, Default)]
pub struct Classifier {
    home_tools: Vec<String>,
}

impl Classifier {
    pub fn new() -> Self {
        Self::default()
    }

    /// Commands the home itself provides and that only talk to remote
    /// services (a GitHub CLI wrapper, a CI client). They classify as
    /// [`CommandClass::Network`] where they would otherwise be unknown.
    pub fn with_home_tools<I, S>(tools: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self { home_tools: tools.into_iter().map(Into::into).collect() }
    }

    /// Classifies one shell command string.
    pub fn classify(&self, command: &str) -> Classification {
        self.classify_script(command, 0)
    }

    fn is_home_tool(&self, name: &str) -> bool {
        self.home_tools.iter().any(|tool| tool == name)
    }
}

/// Classifies one shell command string with no home tools configured.
pub fn classify(command: &str) -> Classification {
    Classifier::new().classify(command)
}

/// Keeps the most demanding class seen so far, and the first word that set it.
#[derive(Debug, Default)]
struct Verdict(Option<Classification>);

impl Verdict {
    fn add(&mut self, class: CommandClass, reason: impl Into<String>) {
        if self.0.as_ref().is_none_or(|best| class > best.class) {
            self.0 = Some(Classification::new(class, reason));
        }
    }

    fn merge(&mut self, other: Classification) {
        if self.0.as_ref().is_none_or(|best| other.class > best.class) {
            self.0 = Some(other);
        }
    }

    fn finish(self) -> Classification {
        self.0.unwrap_or_else(|| Classification::new(CommandClass::FileRead, ""))
    }
}
