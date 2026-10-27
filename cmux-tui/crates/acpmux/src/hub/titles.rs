//! Part of `Hub`; see `hub/mod.rs`. A short generated title for a chat its
//! harness never titles (cx-ncc.91).
//!
//! Codex names its threads (`session_info_update.title`); Claude Code's `-p`
//! stream-json has no title event, so a Claude chat kept its first prompt's
//! line ("Plan a three-dish picnic menu") and so did the workspace named
//! after it. After such a chat's first turn the title command is asked for
//! 3-6 words, on the title model (haiku), never for a chat the person named
//! (`NAMED`); an empty answer is asked again after a later turn, from the
//! latest prompt (`wants_title`). A harness title, then or later, always wins.

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
/// The person named the chat (at `session/new`, or a rename): no title is generated for it.
pub(super) const NAMED: &str = "named";

/// The env that names a title command (one program), over `titles.command`.
const COMMAND_ENV: &str = "ACPMUX_TITLE_COMMAND";
const DEFAULT_MODEL: &str = "haiku";
const TIMEOUT: Duration = Duration::from_secs(20);
const SYSTEM: &str = "You title chats. Reply in the user's language with a title of 3 to 6 words for the chat and nothing else: no quotes, no trailing punctuation.";
const MAX_WORDS: usize = 6;
const MAX_CHARS: usize = 60;
/// A chat's first prompt titles it until a better title comes. A probe ("Reply with only:
/// OK", `probe_prompt.rs`) titles nothing: the first real message does, also in a chat a
/// probe titled before (its title still that prompt's line).
pub(super) fn set_fallback_title(m: &mut SessionMeta, text: &str) {
    fallback_title_fields(&mut m.title, &mut m.title_source, &mut m.title_prompt, text);
}

fn fallback_title_fields(
    title: &mut Option<String>,
    source: &mut Option<String>,
    title_prompt: &mut Option<String>,
    text: &str,
) {
    if crate::probe_prompt::is_probe(text) {
        return;
    }
    if source.as_deref() == Some(PROMPT)
        && title.as_deref().is_some_and(crate::probe_prompt::is_probe)
    {
        *title = None;
    }
    let gist = prompt_gist(text);
    if title.is_some() || gist.line.is_empty() {
        return;
    }
    *title = Some(short_text(gist.line, 80));
    // A chat the person named keeps the prompt line as its title, and asks no model for one.
    if source.as_deref() == Some(NAMED) {
        return;
    }
    *source = Some(PROMPT.to_owned());
    *title_prompt = Some(short_text(gist.body.trim(), 2000));
}

/// A rename of a chat no title has settled yet (by its prompt, or by a request that came back
/// empty and may ask again, `wants_title`) makes it `NAMED`: no title is generated after it.
pub(super) fn title_renamed(m: &mut SessionMeta) {
    if renamed_source(&mut m.title_source) {
        m.title_prompt = None;
    }
}

fn renamed_source(source: &mut Option<String>) -> bool {
    if !matches!(source.as_deref(), None | Some(PROMPT) | Some(ASKED)) {
        return false;
    }
    *source = Some(NAMED.to_owned());
    true
}

/// A sub-session's title as it starts (2026-10-20: seven sub-sessions all read
/// "Read /Users/…/COMMON.md fi…", their prompts' shared first line). Its
/// session name (`parent/short`) is the mux's, not the person's, so it is not
/// `NAMED` for that: a name the starter gave titles it, and without one the
/// prompt and then a generated title do, as for any chat.
pub(super) fn title_subsession(m: &mut SessionMeta, requested: Option<&str>) {
    subsession_title_fields(&mut m.title, &mut m.title_source, requested);
}

fn subsession_title_fields(
    title: &mut Option<String>,
    source: &mut Option<String>,
    requested: Option<&str>,
) {
    match requested.map(str::trim).filter(|n| !n.is_empty()) {
        Some(name) => {
            *title = Some(short_text(name, 80));
            *source = Some(NAMED.to_owned());
        }
        None if source.as_deref() == Some(NAMED) => *source = None,
        None => {}
    }
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
    let body = strip_leading_blocks(text);
    let mut line = "";
    for l in body.lines().map(str::trim) {
        if l.is_empty() || is_label(l) || header_value(l, "group").is_some() {
            continue;
        }
        line = header_value(l, "title").unwrap_or(l);
        break;
    }
    PromptGist { line, body }
}

/// `text` without the `<tag>…</tag>` blocks it opens with. A block that never
/// closes leaves nothing: its first line is no title.
fn strip_leading_blocks(text: &str) -> &str {
    let mut rest = text.trim_start();
    while let Some(tag) = opening_tag(rest) {
        let close = format!("</{tag}>");
        match rest.find(&close) {
            Some(at) => rest = rest[at + close.len()..].trim_start(),
            None => return "",
        }
    }
    rest
}

/// The name of the tag `text` opens with (`<chat>`, `<context kind="x">`), if
/// it opens with one.
fn opening_tag(text: &str) -> Option<&str> {
    let inner = text.strip_prefix('<')?;
    let end = inner.find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))?;
    let name = &inner[..end];
    let first = name.chars().next()?;
    let after = &inner[end..];
    (first.is_ascii_alphabetic()
        && (after.starts_with('>') || after.starts_with(' '))
        && after.contains('>'))
    .then_some(name)
}

/// A short line that only introduces what follows ("Your task:").
fn is_label(line: &str) -> bool {
    line.ends_with(':') && line.split_whitespace().count() <= 3
}

/// The value of a `Key: value` header line, if `line` is one.
fn header_value<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let (k, v) = line.split_once(':')?;
    let v = v.trim();
    (k.trim().eq_ignore_ascii_case(key) && !v.is_empty()).then_some(v)
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
    /// Retry a thin first-message title after its first turn completes. The normal request starts
    /// when the first prompt is accepted; this watcher is only the optional refresh path.
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

    /// Ask for a title as soon as the first user prompt is accepted. The fallback line is already
    /// visible to clients; this replaces it asynchronously without waiting for the agent reply.
    pub(super) fn title_after_prompt(self: &Arc<Self>, session: &Arc<Session>) {
        let request = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if m.title_source.as_deref() != Some(PROMPT) || m.title_asking {
                return;
            }
            // `title_prompt` is ephemeral. A daemon restart before the request was written can
            // leave a persisted prompt placeholder with source `PROMPT`; recover from it.
            let Some(prompt) =
                m.title_prompt.take().or_else(|| m.title.clone()).or_else(|| m.last_prompt.clone())
            else {
                return;
            };
            m.title_thin = is_thin_prompt(&prompt);
            m.title_source = Some(ASKED.to_owned());
            m.title_asking = true;
            request(&prompt, "", true)
        };
        self.spawn_title_request(session.clone(), request);
    }

    /// After a completed first turn, refresh once when the first prompt was too thin to name.
    fn title_after_turn(self: &Arc<Self>, session: &Arc<Session>) {
        let request = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let thin_retry = m.title_thin && m.title_failures == 1;
            // `title_source` is persisted but the in-flight fields are not. On a daemon restart,
            // one completed turn recovers an interrupted request from the latest prompt.
            let restarted_request = !m.title_thin
                && m.title_prompt.is_none()
                && m.title_failures == 0
                && !m.title_asking;
            if m.title_source.as_deref() != Some(ASKED)
                || (!thin_retry && !restarted_request)
                || m.title_asking
                || m.turn_count == 0
            {
                return;
            }
            // Only one refresh is allowed. It reads the latest prompt because the first one was
            // too thin; a later empty answer keeps the first-message placeholder.
            m.title_thin = false;
            let Some(prompt) = m.last_prompt.clone().or_else(|| m.title.clone()) else { return };
            m.title_source = Some(ASKED.to_owned());
            m.title_asking = true;
            request(&prompt, "", false)
        };
        self.spawn_title_request(session.clone(), request);
    }

    fn spawn_title_request(self: &Arc<Self>, session: Arc<Session>, request: String) {
        let hub = self.clone();
        tokio::spawn(async move {
            // Let a harness's own session-info title and a manual rename win before spending a
            // completion. This is also the debounce between the prompt placeholder and the model.
            tokio::time::sleep(Duration::from_millis(50)).await;
            let (source, harness) = {
                let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                (m.title_source.clone(), m.harness.clone())
            };
            if source.as_deref() != Some(ASKED) {
                return;
            }
            let title = hub.generate_title(&session, &harness, &request).await;
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

    async fn generate_title(
        self: &Arc<Self>,
        session: &Session,
        harness: &str,
        request: &str,
    ) -> Option<String> {
        let (custom, model, enabled) = {
            let cfg = self.config.read().await;
            let custom = std::env::var(COMMAND_ENV)
                .ok()
                .filter(|c| !c.trim().is_empty())
                .map(|c| vec![c])
                .or_else(|| cfg.titles.command.clone().filter(|c| !c.is_empty()));
            (custom, cfg.titles.model.clone(), cfg.titles.generate != Some(false))
        };
        if !enabled {
            return None;
        }
        if custom.is_some() {
            let command = self.title_command(harness).await?;
            if session.meta.lock().unwrap_or_else(|e| e.into_inner()).title_source.as_deref()
                != Some(ASKED)
            {
                return None;
            }
            let started = std::time::Instant::now();
            let title = run(command, request).await;
            tracing::info!(
                event = "chat_title",
                harness,
                model = "custom",
                ms = started.elapsed().as_millis() as u64,
                input_bytes = request.len(),
                output_words = title.as_deref().map_or(0, |t| t.split_whitespace().count()),
                estimated_input_tokens = request.len().div_ceil(4),
                estimated_output_tokens = title.as_deref().map_or(0, |t| t.len().div_ceil(4)),
                "chat title completion"
            );
            return title;
        }
        let mut params = json!({"prompt": request, "harness": harness, "maxTokens": 16});
        if let Some(model) = model {
            params["model"] = json!(model);
        }
        if session.meta.lock().unwrap_or_else(|e| e.into_inner()).title_source.as_deref()
            != Some(ASKED)
        {
            return None;
        }
        let started = std::time::Instant::now();
        let result = self.complete(crate::server::Origin::Local, &params).await.ok()?;
        let title = result.get("text").and_then(Value::as_str).and_then(clean);
        tracing::info!(
            event = "chat_title",
            harness,
            model = result.get("model").and_then(serde_json::Value::as_str).unwrap_or("default"),
            ms = started.elapsed().as_millis() as u64,
            input_bytes = request.len(),
            output_words = title.as_deref().map_or(0, |t| t.split_whitespace().count()),
            estimated_input_tokens = request.len().div_ceil(4),
            estimated_output_tokens = title.as_deref().map_or(0, |t| t.len().div_ceil(4)),
            "chat title completion"
        );
        title
    }

    fn apply_generated_title(self: &Arc<Self>, session: &Arc<Session>, title: Option<String>) {
        let (title, retry) = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            m.title_asking = false;
            match title {
                // An empty answer: a thin first prompt may get one refresh after its turn.
                None => {
                    m.title_failures = m.title_failures.saturating_add(1);
                    let completed = m
                        .last_turn
                        .as_ref()
                        .and_then(|turn| turn.get("status"))
                        .and_then(Value::as_str)
                        == Some("completed");
                    (None, m.title_thin && completed && m.title_failures == 1)
                }
                Some(title) => {
                    // A harness title that came meanwhile wins.
                    if m.title_source.as_deref() != Some(ASKED) {
                        return;
                    }
                    m.title = Some(title.clone());
                    m.title_source = Some(GENERATED.to_owned());
                    (Some(title), false)
                }
            }
        };
        if retry {
            self.title_after_turn(session);
            return;
        }
        let Some(title) = title else { return };
        self.append(session, "mux", "titled", json!({"title": title}));
        self.save_meta(session);
    }
}

fn request(prompt: &str, reply: &str, first: bool) -> String {
    let which = if first { "first" } else { "latest" };
    let mut text = format!("{SYSTEM}\n\nThe person's {which} message:\n{prompt}\n");
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

/// A short acknowledgement or control word is not enough context for a stable title. Such a
/// first prompt gets one optional refresh after its first agent turn; ordinary prompts are never
/// retitled.
fn is_thin_prompt(prompt: &str) -> bool {
    let words: Vec<_> = prompt.split_whitespace().collect();
    words.is_empty()
        || words.len() <= 1
        || (words.len() <= 2 && words[0].trim_matches(|c: char| !c.is_alphanumeric()).len() <= 12)
        || words.iter().any(|word| {
            matches!(
                word.trim_matches(|c: char| !c.is_alphanumeric()).to_ascii_lowercase().as_str(),
                "hi" | "hello" | "hey" | "ok" | "okay" | "continue" | "thanks" | "thankyou"
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_thin_first_messages_are_eligible_for_a_refresh() {
        for prompt in ["hi", "continue", "OK", "thanks"] {
            assert!(is_thin_prompt(prompt), "{prompt}");
        }
        for prompt in ["Plan a three-dish picnic menu", "Fix the sidebar spinner"] {
            assert!(!is_thin_prompt(prompt), "{prompt}");
        }
    }

    #[test]
    fn a_rename_after_an_empty_title_request_stops_title_requests() {
        for unsettled in [None, Some(PROMPT), Some(ASKED)] {
            let mut source = unsettled.map(str::to_owned);
            assert!(renamed_source(&mut source));
            assert_eq!(source.as_deref(), Some(NAMED), "{unsettled:?} renamed title is final");
        }
        for done in [GENERATED, HARNESS, ADOPTED] {
            let mut source = Some(done.to_owned());
            assert!(!renamed_source(&mut source));
            assert_eq!(source.as_deref(), Some(done));
        }
    }

    #[test]
    fn a_retried_title_reads_the_latest_prompt() {
        assert!(
            request("Reply with only: OK", "", true)
                .contains("first message:\nReply with only: OK")
        );
        assert!(
            request("Fix the sidebar spinner", "", false)
                .contains("latest message:\nFix the sidebar spinner")
        );
    }

    #[test]
    fn a_named_subsession_is_titled_by_its_name_not_its_prompt() {
        // The session name made it NAMED (`lifecycle.rs`); the requested name titles it.
        let (mut title, mut source) = (None, Some(NAMED.to_owned()));
        subsession_title_fields(&mut title, &mut source, Some("  sidebar-cleanup "));
        assert_eq!(title.as_deref(), Some("sidebar-cleanup"));
        assert_eq!(source.as_deref(), Some(NAMED));
    }

    #[test]
    fn an_unnamed_subsession_gets_a_generated_title() {
        // Not NAMED: the first prompt's line is only the fallback, and a title is generated after it.
        let (mut title, mut source) = (None, Some(NAMED.to_owned()));
        subsession_title_fields(&mut title, &mut source, Some(" "));
        assert_eq!((title, source), (None, None));
    }

    #[test]
    fn a_probe_titles_no_chat_and_the_first_real_message_does() {
        let (mut title, mut source, mut prompt) = (None, None, None);
        fallback_title_fields(&mut title, &mut source, &mut prompt, "Reply with only: OK");
        assert_eq!((title.as_deref(), source.as_deref()), (None, None), "a probe titles nothing");
        fallback_title_fields(&mut title, &mut source, &mut prompt, "Fix the sidebar spinner");
        assert_eq!(title.as_deref(), Some("Fix the sidebar spinner"));
        assert_eq!(source.as_deref(), Some(PROMPT));
        assert_eq!(
            prompt.as_deref(),
            Some("Fix the sidebar spinner"),
            "the title request reads it"
        );
        fallback_title_fields(&mut title, &mut source, &mut prompt, "Now add a test");
        assert_eq!(title.as_deref(), Some("Fix the sidebar spinner"), "a later message keeps it");
    }

    #[test]
    fn a_chat_a_probe_titled_before_takes_the_first_real_message() {
        let mut title = Some("Reply with only: OK".to_owned());
        let mut source = Some(PROMPT.to_owned());
        let mut prompt = None;
        fallback_title_fields(&mut title, &mut source, &mut prompt, "Fix the sidebar spinner");
        assert_eq!(title.as_deref(), Some("Fix the sidebar spinner"));
        assert_eq!(prompt.as_deref(), Some("Fix the sidebar spinner"));
        // A title the person or a model gave stays, even one that reads like a probe.
        for kept in [NAMED, GENERATED, HARNESS] {
            let mut title = Some("Reply with only: OK".to_owned());
            let mut source = Some(kept.to_owned());
            fallback_title_fields(&mut title, &mut source, &mut None, "Fix the sidebar spinner");
            assert_eq!(title.as_deref(), Some("Reply with only: OK"), "{kept}");
        }
    }

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
