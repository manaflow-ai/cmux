//! Part of `Hub`; see `hub/mod.rs`. A short generated title for a chat its
//! harness never titles (cx-ncc.91).
//!
//! Codex names its threads (`session_info_update.title`); Claude Code's `-p`
//! stream-json has no title event, so a Claude chat kept its first prompt's
//! line ("Plan a three-dish picnic menu") and so did the workspace named
//! after it. After such a chat's first turn the title command is asked once
//! for 3-6 words. A harness title, then or later, always wins.

use super::*;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// `SessionMeta.title_source` values.
const PROMPT: &str = "prompt";
const ADOPTED: &str = "adopted";
pub(super) const HARNESS: &str = "harness";
const ASKED: &str = "asked";
const GENERATED: &str = "generated";

/// The env that names a title command (one program), over `titles.command`.
const COMMAND_ENV: &str = "ACPMUX_TITLE_COMMAND";
const DEFAULT_MODEL: &str = "haiku";
const TIMEOUT: Duration = Duration::from_secs(20);
const SYSTEM: &str = "You title chats. Reply with a title of 3 to 6 words for the chat and nothing else: no quotes, no trailing punctuation.";
const MAX_WORDS: usize = 6;
const MAX_CHARS: usize = 60;

/// A chat's first prompt titles it until a better title comes.
pub(super) fn set_fallback_title(m: &mut SessionMeta, text: &str) {
    let gist = prompt_gist(text);
    if m.title.is_some() || gist.line.is_empty() {
        return;
    }
    m.title = Some(short_text(gist.line, 80));
    m.title_source = Some(PROMPT.to_owned());
    m.title_prompt = Some(short_text(gist.body.trim(), 2000));
}

/// What a first prompt says, for its title: `line` names the chat, `body` is
/// what the title command reads.
#[derive(Debug, PartialEq, Eq)]
struct PromptGist<'a> {
    line: &'a str,
    body: &'a str,
}

/// The gist of a first prompt (2026-10-20: every Chief subagent tab read
/// "<chat>"). A prompt that opens with context blocks (a Chief's `<chat>…</chat>`
/// view) is titled by what follows them; a label line ("Your task:") and a
/// `Group:` header are skipped; a `Title:` header names the chat.
fn prompt_gist(text: &str) -> PromptGist<'_> {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    PromptGist { line, body: text }
}

/// An adopted chat keeps the title it came with: a prompt sent here is not
/// its first, so nothing generates one from it.
pub(super) fn keep_adopted_title(m: &mut SessionMeta) {
    if matches!(m.title_source.as_deref(), None | Some(PROMPT)) {
        m.title_source = Some(ADOPTED.to_owned());
        m.title_prompt = None;
    }
}

impl Hub {
    /// Title chats as their turns complete (a local `turn_result` with
    /// status `completed`), off the turn's own path.
    pub(super) fn watch_titles(self: &Arc<Self>) {
        let mut events = self.subscribe();
        let hub = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                let ev = match events.recv().await {
                    Ok(ev) => ev,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return,
                };
                let rec = &ev.record;
                let completed = rec.dir == "mux"
                    && rec.kind == "turn_result"
                    && rec.msg.get("status").and_then(Value::as_str) == Some("completed");
                if !completed || ev.remote.is_some() {
                    continue;
                }
                let Some(hub) = hub.upgrade() else { return };
                if let Ok(session) = hub.resolve(&ev.session_id) {
                    hub.title_after_turn(&session);
                }
            }
        });
    }

    /// After a completed turn: ask for a title once if the chat still has
    /// only its first prompt's line.
    fn title_after_turn(self: &Arc<Self>, session: &Arc<Session>) {
        let (harness, request) = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if m.title_source.as_deref() != Some(PROMPT) {
                return;
            }
            let Some(prompt) = m.title_prompt.take().or_else(|| m.title.clone()) else {
                return;
            };
            m.title_source = Some(ASKED.to_owned());
            // The reply is the first turn's only while no later turn has started.
            let reply = match m.turn_count {
                1 => m.preview.as_deref().map(|p| short_text(p.trim(), 600)).unwrap_or_default(),
                _ => String::new(),
            };
            (m.harness.clone(), request(&prompt, &reply))
        };
        let hub = self.clone();
        let session = session.clone();
        tokio::spawn(async move {
            let title = match hub.title_command(&harness).await {
                Some(cmd) => run(cmd, &request).await,
                None => None,
            };
            hub.apply_generated_title(&session, title);
        });
    }

    /// The command that titles a chat on `harness`, or None (none applies,
    /// or `titles.generate` is off).
    async fn title_command(&self, harness: &str) -> Option<tokio::process::Command> {
        // Never the shared temp dir or the daemon's folder: Claude Code runs
        // `rg --files --hidden` over its cwd at start, and one titler per
        // finished chat over all of `$TMPDIR` pegged the Mac's CPU.
        let cwd =
            tokio::task::spawn_blocking(crate::protected_folders::unattended_cwd).await.ok()?;
        let cfg = self.config.read().await;
        if cfg.titles.generate == Some(false) {
            return None;
        }
        let argv = std::env::var(COMMAND_ENV)
            .ok()
            .filter(|c| !c.trim().is_empty())
            .map(|c| vec![c])
            .or_else(|| cfg.titles.command.clone().filter(|c| !c.is_empty()));
        if let Some(argv) = argv {
            let mut cmd = tokio::process::Command::new(&argv[0]);
            cmd.args(&argv[1..]).current_dir(&cwd);
            #[cfg(unix)]
            cmd.process_group(0);
            return Some(cmd);
        }
        // The chat's own Claude Code: the sign-in and route its turn just used.
        let profile = cfg.harnesses.get(harness)?;
        if profile.kind != crate::config::HarnessKind::ClaudeStdio {
            return None;
        }
        let model = cfg.titles.model.clone().unwrap_or_else(|| DEFAULT_MODEL.to_owned());
        let program = profile.argv.first().cloned().unwrap_or_else(|| "claude".into());
        let mut args: Vec<String> = profile.argv.iter().skip(1).cloned().collect();
        args.extend(
            [
                "-p",
                "--output-format",
                "text",
                "--model",
                model.as_str(),
                "--no-session-persistence",
                "--tools",
                "",
                "--strict-mcp-config",
                "--disable-slash-commands",
                // The person's Claude hooks (notifications, Stop) are not for this call.
                "--settings",
                r#"{"disableAllHooks":true}"#,
                "--system-prompt",
                SYSTEM,
            ]
            .map(str::to_owned),
        );
        match crate::agent::harness_command(harness, profile, &cwd, Some((program, args)), None) {
            Ok(cmd) => Some(cmd),
            Err(e) => {
                tracing::debug!("no title command for {harness}: {e}");
                None
            }
        }
    }

    fn apply_generated_title(&self, session: &Session, title: Option<String>) {
        let Some(title) = title else { return };
        {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            // A harness title that came meanwhile wins.
            if m.title_source.as_deref() != Some(ASKED) {
                return;
            }
            m.title = Some(title.clone());
            m.title_source = Some(GENERATED.to_owned());
        }
        self.append(session, "mux", "titled", json!({"title": title}));
        self.save_meta(session);
    }
}

fn request(prompt: &str, reply: &str) -> String {
    let mut text = format!("Title this chat.\n\nThe person's first message:\n{prompt}\n");
    if !reply.is_empty() {
        text.push_str(&format!("\nThe start of the agent's reply:\n{reply}\n"));
    }
    text
}

/// Run a title command with the request on stdin; its cleaned first line.
async fn run(mut cmd: tokio::process::Command, request: &str) -> Option<String> {
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true);
    let mut child = cmd.spawn().map_err(|e| tracing::debug!("title command: {e}")).ok()?;
    let pid = child.id();
    let mut stdin = child.stdin.take()?;
    let mut stdout = child.stdout.take()?;
    let request = request.to_owned();
    let answer = async {
        stdin.write_all(request.as_bytes()).await.ok()?;
        drop(stdin);
        let mut out = String::new();
        stdout.read_to_string(&mut out).await.ok()?;
        let status = child.wait().await.ok()?;
        status.success().then_some(out)
    };
    let Ok(out) = tokio::time::timeout(TIMEOUT, answer).await else {
        // The command runs in its own group (a wrapper's children too): end it
        // all while its leader, not yet reaped, still holds the group's id.
        #[cfg(unix)]
        if let Some(pid) = pid {
            unsafe {
                libc::killpg(pid as i32, libc::SIGKILL);
            }
        }
        drop(child);
        return None;
    };
    clean(&out?)
}

/// The title in a model's answer: its first line without quotes, a
/// `Title:` label or trailing punctuation, at most 6 words and 60 chars.
fn clean(out: &str) -> Option<String> {
    let line = out.lines().map(str::trim).find(|l| !l.is_empty())?;
    let line = line.strip_prefix("Title:").unwrap_or(line);
    let quotes: &[char] = &['"', '\'', '`', '*', '“', '”', '‘', '’'];
    let line = line.trim().trim_matches(quotes).trim();
    let line = line.trim_end_matches(['.', '!', '?', ':', ';', ',']).trim_matches(quotes).trim();
    let mut title = String::new();
    for word in line.split_whitespace().take(MAX_WORDS) {
        if title.chars().count() + word.chars().count() + 1 > MAX_CHARS {
            break;
        }
        if !title.is_empty() {
            title.push(' ');
        }
        title.push_str(word);
    }
    (!title.is_empty()).then_some(title)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_prompt_is_titled_by_its_first_line() {
        let gist = prompt_gist("\n  Plan a three-dish picnic menu\nwith dessert");
        assert_eq!(gist.line, "Plan a three-dish picnic menu");
    }

    #[test]
    fn a_chief_subagent_prompt_is_titled_by_its_task_title_not_its_chat_view() {
        let text = "<chat>\n0+512|user: merge PR 17453\n</chat>Your task:\n\nTitle: ACP agent tab names\nGroup: cmux-next app\nUser (msg 5944): rename the tabs";
        let gist = prompt_gist(text);
        assert_eq!(gist.line, "ACP agent tab names");
        assert!(
            !gist.body.contains("<chat>"),
            "the title command reads the task, not the chat view: {}",
            gist.body
        );
        assert!(gist.body.contains("rename the tabs"));
    }

    #[test]
    fn a_task_without_a_title_header_skips_its_label_and_group() {
        let gist = prompt_gist(
            "<chat>\nview\n</chat>\nYour task:\nGroup: Performance\nMake create and close fast",
        );
        assert_eq!(gist.line, "Make create and close fast");
    }

    #[test]
    fn an_unclosed_context_block_gives_no_title() {
        assert_eq!(prompt_gist("<chat> 0+512|user: merge cmux PR 17453 (outcome?)…").line, "");
    }

    #[test]
    fn a_line_that_only_looks_like_a_tag_still_titles() {
        assert_eq!(prompt_gist("<3 this app, make it faster").line, "<3 this app, make it faster");
        assert_eq!(prompt_gist("a < b: why").line, "a < b: why");
    }
}
