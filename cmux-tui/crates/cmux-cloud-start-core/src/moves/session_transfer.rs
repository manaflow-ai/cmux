//! Moving sessions between builds on one Mac (`session.transfer.*`): what a classic peer's
//! surfaces, a classic workspace's split tree and a failed `acpmux transfer` mean, and the
//! arguments that move a chat. The app talks to the peers and the daemon; it asks here.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A classic workspace's split tree, the `layout` of `session.transfer.open`
/// (scripts/cmux-next/classic-to-next.py): a pane lists indices into the workspace's
/// `terminals`, in tab order; a split names `right` or `down` and the first child's share.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Layout {
    Pane { terminals: Vec<usize> },
    Split { direction: Direction, ratio: f64, first: Box<Layout>, second: Box<Layout> },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Direction {
    Right,
    Down,
}

impl Layout {
    /// The tree in `json`, None unless it names every index below `count` exactly once.
    pub fn parse(json: &Value, count: usize) -> Option<Layout> {
        let layout = Self::node(json)?;
        let mut terminals = layout.terminals();
        terminals.sort_unstable();
        (terminals.len() == count && terminals.into_iter().eq(0..count)).then_some(layout)
    }

    fn node(node: &Value) -> Option<Layout> {
        if let Some(indices) = node.get("terminals").and_then(Value::as_array) {
            let terminals: Vec<usize> = indices.iter().filter_map(whole_index).collect();
            if terminals.is_empty() || terminals.len() != indices.len() {
                return None;
            }
            return Some(Layout::Pane { terminals });
        }
        let direction = match node.get("split").and_then(Value::as_str)? {
            "right" => Direction::Right,
            "down" => Direction::Down,
            _ => return None,
        };
        let first = Self::node(node.get("first")?)?;
        let second = Self::node(node.get("second")?)?;
        let ratio = node.get("ratio").and_then(Value::as_f64).unwrap_or(0.5);
        let ratio = if ratio > 0.0 && ratio < 1.0 { ratio } else { 0.5 };
        Some(Layout::Split { direction, ratio, first: Box::new(first), second: Box::new(second) })
    }

    /// Terminal indices in pane order; the first one opens the workspace.
    pub fn terminals(&self) -> Vec<usize> {
        match self {
            Layout::Pane { terminals } => terminals.clone(),
            Layout::Split { first, second, .. } => {
                let mut all = first.terminals();
                all.extend(second.terminals());
                all
            }
        }
    }
}

/// A JSON number that is a whole, non-negative index (`1.0` is, `1.5` and `-1` are not).
fn whole_index(value: &Value) -> Option<usize> {
    if let Some(index) = value.as_u64() {
        return usize::try_from(index).ok();
    }
    let number = value.as_f64()?;
    // Negative whole numbers parse in the app too, then fail the exactly-once check; none is an index.
    (number.fract() == 0.0 && number >= 0.0 && number <= u32::MAX as f64).then_some(number as usize)
}

/// What a classic surface is to a taker, the app's `SessionTransferItem` fields.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClassicItem {
    pub source_surface: String,
    pub workspace: String,
    /// `agent` or `terminal`.
    pub kind: String,
    pub title: String,
    pub cwd: Option<String>,
    pub ssh_target: Option<String>,
    pub agent_harness: Option<String>,
    #[serde(rename = "agentSessionID")]
    pub agent_session_id: Option<String>,
}

fn text<'a>(object: Option<&'a Value>, key: &str) -> Option<&'a str> {
    object?.get(key)?.as_str()
}

/// A classic `surface.list` surface as a movable item: a terminal (`terminal` or `pty`) or an
/// agent whose resume command names its session. Only an SSH command is replayed; another launch
/// command may be one-shot (a deploy), so the terminal reopens as a shell.
pub fn classic_item(
    value: &Value,
    workspace: &str,
    fallback_cwd: Option<&str>,
) -> Option<ClassicItem> {
    let object = value.as_object().map(|_| value);
    let source_surface = text(object, "id").or_else(|| text(object, "ref"))?;
    let kind = text(object, "type").unwrap_or("");
    if kind != "terminal" && kind != "pty" {
        return None;
    }
    let binding = object.and_then(|o| o.get("resume_binding")).filter(|b| b.is_object());
    let harness = text(binding, "kind").filter(|kind| *kind == "claude" || *kind == "codex");
    let session = harness.and_then(|harness| {
        [text(binding, "command"), text(binding, "launch_command")]
            .into_iter()
            .find_map(|command| agent_session_id(harness, command))
    });
    let is_agent = harness.is_some() && session.is_some();
    let command = text(object, "initial_command").or_else(|| text(binding, "command"));
    let cwd = text(object, "requested_working_directory")
        .or_else(|| text(binding, "cwd"))
        .or(fallback_cwd);
    let ssh_target = text(object, "ssh_target").map(str::to_owned).or_else(|| ssh_target(command));
    Some(ClassicItem {
        source_surface: source_surface.to_owned(),
        workspace: workspace.to_owned(),
        kind: if is_agent { "agent" } else { "terminal" }.to_owned(),
        title: text(object, "title").unwrap_or("").to_owned(),
        cwd: cwd.map(str::to_owned),
        ssh_target,
        agent_harness: if is_agent { harness.map(str::to_owned) } else { None },
        agent_session_id: if is_agent { session } else { None },
    })
}

fn tokens(command: &str) -> impl Iterator<Item = &str> {
    command.split([' ', '\t']).filter(|token| !token.is_empty())
}

fn unquoted(token: &str) -> &str {
    token.trim_matches(['\'', '"'])
}

/// The session id in a classic resume command: `claude --resume|-r|--session-id <id>` or
/// `codex resume <id>`.
pub fn agent_session_id(harness: &str, command: Option<&str>) -> Option<String> {
    let words: Vec<&str> = tokens(command?).map(unquoted).collect();
    let flags: &[&str] =
        if harness == "codex" { &["resume"] } else { &["--resume", "-r", "--session-id"] };
    let index = words.iter().position(|word| flags.contains(word))?;
    let id = words.get(index + 1)?;
    (!id.is_empty() && !id.starts_with('-')).then(|| (*id).to_owned())
}

/// The host of an `ssh` command: its first word past `ssh` that is no flag, skipping `-p`,
/// `-o` and `-J`'s values.
pub fn ssh_target(command: Option<&str>) -> Option<String> {
    let words: Vec<&str> = tokens(command?).collect();
    let index = words.iter().position(|word| *word == "ssh" || word.ends_with("/ssh"))?;
    let mut skip_next = false;
    for word in words.iter().skip(index + 1) {
        if skip_next {
            skip_next = false;
            continue;
        }
        if *word == "-p" || *word == "-o" || *word == "-J" {
            skip_next = true;
            continue;
        }
        if word.starts_with('-') {
            continue;
        }
        return Some(unquoted(word).to_owned());
    }
    None
}

/// The command that reopens an SSH terminal at `target`.
pub fn ssh_command(target: &str) -> String {
    format!("exec ssh -- '{}'", target.replace('\'', "'\\''"))
}

/// Whether a peer's control error `code` means it has no transfer method (an older build): its
/// sessions are then closed by hand.
pub fn is_missing_transfer_method(code: &str) -> bool {
    ["method_not_found", "unknown_method", "unsupported", "unavailable"].contains(&code)
}

/// The `acpmux` arguments that move chat `session` to the daemon at `to`.
pub fn transfer_arguments(
    session: &str,
    to: &str,
    interrupt: bool,
    cwd: Option<&str>,
) -> Vec<String> {
    let mut arguments: Vec<String> =
        ["--json", "transfer", session, "--to", to].into_iter().map(str::to_owned).collect();
    if interrupt {
        arguments.push("--interrupt".to_owned());
    }
    if let Some(cwd) = cwd {
        arguments.extend(["--cwd".to_owned(), cwd.to_owned()]);
    }
    arguments
}

/// The moved chat's session here: `sessionId` of `acpmux transfer --json`'s output, else `session`.
pub fn moved_session(stdout: &str, session: &str) -> String {
    serde_json::from_str::<Value>(stdout)
        .ok()
        .and_then(|value| value.get("sessionId")?.as_str().map(str::to_owned))
        .unwrap_or_else(|| session.to_owned())
}

/// A failed `acpmux transfer`, as its `--json` error line (the last line of stderr) tells it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ChatFailure {
    /// The chat's folder is not on this machine; pulled again with `cwd`, it moves there.
    FolderMissing { folder: String },
    /// acpmux's message, else its text, else its exit status.
    NotMoved { reason: String },
}

pub fn acpmux_failure(stderr: &str, status: i32) -> ChatFailure {
    let text = stderr.trim();
    let last = text.split('\n').rfind(|line| !line.is_empty()).unwrap_or("");
    let line = serde_json::from_str::<Value>(last).ok().filter(Value::is_object);
    let error = line.as_ref().and_then(|line| line.get("error"));
    let object = error.filter(|error| error.is_object());
    if text_of(object, "detail") == Some("cwd_missing")
        && let Some(folder) =
            object.and_then(|e| e.get("data")).and_then(|d| d.get("cwd")).and_then(Value::as_str)
    {
        return ChatFailure::FolderMissing { folder: folder.to_owned() };
    }
    if let Some(message) = text_of(object, "message").or_else(|| error.and_then(Value::as_str)) {
        return ChatFailure::NotMoved { reason: message.to_owned() };
    }
    let reason =
        if text.is_empty() { format!("acpmux exited with {status}") } else { text.to_owned() };
    ChatFailure::NotMoved { reason }
}

fn text_of<'a>(object: Option<&'a Value>, key: &str) -> Option<&'a str> {
    object?.get(key)?.as_str()
}

/// A peer's `system.identify` answer as the app lists it; None for this build itself.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    pub app: String,
    pub build: String,
    /// The answer's tag; without one, the app reads it off `bundleIdentifier`.
    pub tag: Option<String>,
    pub bundle_identifier: Option<String>,
    pub pid: i32,
}

/// Classic answers without `pid` and `tag` (its bundle id carries the tag); shipped classic
/// nightlies answer only `socket_path`, `focused` and `caller`.
pub fn identity(answer: &Value, own_pid: i64) -> Option<Identity> {
    let fields = answer.as_object()?;
    let pid = fields.get("pid").and_then(Value::as_i64);
    if pid == Some(own_pid) {
        return None;
    }
    let string = |key: &str| fields.get(key).and_then(Value::as_str).map(str::to_owned);
    Some(Identity {
        app: string("app").unwrap_or_else(|| "cmux".to_owned()),
        build: string("build").or_else(|| string("version")).unwrap_or_default(),
        tag: string("tag"),
        bundle_identifier: string("bundle_identifier"),
        pid: pid.map_or(0, |pid| pid.clamp(i32::MIN as i64, i32::MAX as i64) as i32),
    })
}

#[cfg(test)]
#[path = "session_transfer_tests.rs"]
mod tests;
