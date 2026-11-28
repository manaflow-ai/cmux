//! What an agent learns about cmux when its session starts in a cmux-tui
//! terminal: that it runs in cmux, the ids of its session, workspace, screen,
//! pane, tab and terminal, and that `cmux skill show` prints the guide.
//!
//! It goes to the model as the `SessionStart` hook's `additionalContext`.
//! Claude Code gets it from the extra `SessionStart` hook the `claude` shim
//! adds (`cmux-tui agent session-context`, claude_wrapper.rs), which runs the
//! build that spawned the pane, or from the same hook in the pane's Claude
//! Code plugin when Claude skipped the shim (claude_plugin.rs; the wrapper
//! drops that plugin); Codex from the shim's own `SessionStart` hook
//! (`CMUX_TUI_HOOK_ROUTE=launch`). Hooks installed by `agent hook install`
//! add nothing here, so no agent gets it twice.

use super::*;

/// The whole read (six local requests) stays far below the hook timeouts.
const DEADLINE: Duration = Duration::from_millis(1500);

/// The caller's place; a field the session did not report stays `None`.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct Place {
    pub session_name: Option<String>,
    pub session_id: Option<String>,
    pub workspace: Option<String>,
    pub workspace_name: Option<String>,
    pub screen: Option<String>,
    pub pane: Option<String>,
    pub tab: Option<String>,
    pub terminal: String,
}

/// Whether the hook for `source`'s `native_event` carries the context: the
/// Codex shim's own `SessionStart` (the route it names, never an installed
/// hook, whose command echoes its own `{}`).
pub(super) fn applies(
    source: &str,
    native_event: &str,
    getenv: impl Fn(&str) -> Option<std::ffi::OsString>,
) -> bool {
    source == "codex"
        && native_event == "SessionStart"
        && getenv(HOOK_ROUTE_ENV).is_some_and(|value| value == "launch")
}

/// One `cmux.protocol/2` read of the session at `socket`, `None` when it
/// does not answer by `deadline`.
pub(super) fn request(
    socket: &Path,
    operation: &str,
    params: Value,
    deadline: Instant,
) -> Option<Value> {
    let (request_id, _) = random_identifiers().ok()?;
    let mut params = params.as_object().cloned().unwrap_or_default();
    params.entry("machine").or_insert_with(|| json!("current"));
    params.entry("session").or_insert_with(|| json!("current"));
    let request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": request_id,
        "operation": operation,
        "params": params,
    });
    let mut encoded = serde_json::to_vec(&request).ok()?;
    encoded.push(b'\n');
    let mut stream = connect_before(socket, deadline).ok()?;
    stream.set_read_timeout(Some(remaining_before(deadline).ok()?)).ok()?;
    write_before(&mut *stream, &encoded, deadline).ok()?;
    let response: Value = serde_json::from_slice(&read_before(stream, deadline).ok()?).ok()?;
    if response.get("id").and_then(Value::as_str) != Some(request_id.as_str())
        || response.get("ok").and_then(Value::as_bool) != Some(true)
    {
        return None;
    }
    response.get("result").cloned()
}

/// Reads the place of `terminal` from the session at `socket`. Only the
/// terminal is required; the rest is filled as far as the session answers.
pub(crate) fn read(socket: &Path, terminal: &str) -> Place {
    let deadline = Instant::now() + DEADLINE;
    let get = |operation: &str, key: &str, id: &str| {
        request(socket, operation, json!({ key: id }), deadline)
    };
    let text = |record: &Option<Value>, key: &str| {
        record
            .as_ref()
            .and_then(|record| record.get(key))
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    let mut place = Place { terminal: terminal.to_owned(), ..Place::default() };
    let session = request(socket, "session.get", json!({}), deadline);
    place.session_name = text(&session, "name");
    place.session_id = text(&session, "id");
    let terminal_record = get("terminal.get", "terminal", terminal);
    let Some(tab) = text(&terminal_record, "tab_id") else { return place };
    let tab_record = get("tab.get", "tab", &tab);
    place.tab = Some(tab);
    let Some(pane) = text(&tab_record, "pane_id") else { return place };
    let pane_record = get("pane.get", "pane", &pane);
    place.pane = Some(pane);
    let Some(screen) = text(&pane_record, "screen_id") else { return place };
    let screen_record = get("screen.get", "screen", &screen);
    place.screen = Some(screen);
    let Some(workspace) = text(&screen_record, "workspace_id") else { return place };
    let workspace_record = get("workspace.get", "workspace", &workspace);
    place.workspace_name = text(&workspace_record, "name");
    place.workspace = Some(workspace);
    place
}

/// `path` as one shell word: bare when it has no special characters, else
/// single-quoted.
fn shell_word(path: &Path) -> String {
    let path = path.to_string_lossy();
    if !path.is_empty() && path.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+,:@".contains(c))
    {
        return path.into_owned();
    }
    format!("'{}'", path.replace('\'', "'\\''"))
}

/// The context text for `place`. `cli` is this build's executable: the
/// `cmux` on PATH can be another program (the cmux app's CLI), so the text
/// names the exact command when it is known.
pub(crate) fn text(place: &Place, cli: Option<&Path>) -> String {
    let id = |value: &Option<String>| value.as_deref().unwrap_or("unknown").to_owned();
    let session = match (&place.session_name, &place.session_id) {
        (Some(name), Some(id)) => format!("`{name}` ({id})"),
        (Some(name), None) => format!("`{name}`"),
        (None, Some(id)) => id.clone(),
        (None, None) => "unknown".to_owned(),
    };
    let workspace = match &place.workspace_name {
        Some(name) if !name.is_empty() => format!("{} (\"{name}\")", id(&place.workspace)),
        _ => id(&place.workspace),
    };
    let (command, which) = match cli {
        Some(cli) => {
            let command = shell_word(cli);
            let which = format!(
                "This session's CLI is `{command}`; the guide writes it as `cmux`, and a \
                 `cmux` elsewhere on PATH (such as the cmux app's) can be another program."
            );
            (command, which)
        }
        None => (
            "cmux".to_owned(),
            "The cmux-tui CLI (`cmux` from the cmux npm package) controls this session.".to_owned(),
        ),
    };
    format!(
        "cmux: you run in a cmux terminal (a cmux-tui pane). Session {session}; workspace \
         {workspace}; screen {}; pane {}; tab {}; terminal {}. {which} `current` names the \
         session's focused object (the pane the person looks at), not yours: pass your own \
         ids. Run `{command} skill show` for the full agent guide (identity, targeting, \
         `screen wait`, `process wait`, reads, errors, cleanup) and `{command} --json \
         identify` to check where you are. Do not move the person's focus, type into your \
         own terminal, or close panes you did not open.",
        id(&place.screen),
        id(&place.pane),
        id(&place.tab),
        place.terminal,
    )
}

/// The `SessionStart` hook output that adds `text` to the model's context;
/// the empty object without one.
pub(crate) fn output(text: Option<&str>) -> Value {
    match text {
        Some(text) => json!({
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": text,
            }
        }),
        None => json!({}),
    }
}

/// Prints the context for the caller `terminal` of the session at `socket`
/// as the hook's one JSON object (the empty object outside a terminal).
/// `cli` is this build's executable, named in the text.
pub(crate) fn print(socket: Option<&Path>, terminal: Option<&str>, cli: Option<&Path>) {
    let text = socket
        .zip(terminal.filter(|terminal| terminal.starts_with("term_")))
        .map(|(socket, terminal)| text(&read(socket, terminal), cli));
    let mut stdout = io::stdout().lock();
    let _ = writeln!(stdout, "{}", output(text.as_deref()));
    let _ = stdout.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_context_names_every_id_and_the_guide() {
        let place = Place {
            session_name: Some("bench".into()),
            session_id: Some("session_1".into()),
            workspace: Some("ws_1".into()),
            workspace_name: Some("api".into()),
            screen: Some("screen_1".into()),
            pane: Some("pane_1".into()),
            tab: Some("tab_1".into()),
            terminal: "term_1".into(),
        };
        let text = text(&place, Some(Path::new("/opt/cmux tui/cmux-tui")));
        for needle in [
            "cmux-tui",
            "`bench` (session_1)",
            "ws_1 (\"api\")",
            "screen screen_1",
            "pane pane_1",
            "tab tab_1",
            "terminal term_1",
            "This session's CLI is `'/opt/cmux tui/cmux-tui'`",
            "`'/opt/cmux tui/cmux-tui' skill show`",
            "`'/opt/cmux tui/cmux-tui' --json identify`",
            "pass your own ids",
        ] {
            assert!(text.contains(needle), "{needle}: {text}");
        }
        let output = output(Some(&text));
        assert_eq!(output["hookSpecificOutput"]["hookEventName"], "SessionStart");
        assert_eq!(output["hookSpecificOutput"]["additionalContext"], text.as_str());
        assert_eq!(super::output(None), json!({}));
    }

    #[test]
    fn session_context_a_place_the_session_does_not_know_still_names_the_terminal() {
        let text = text(&Place { terminal: "term_9".into(), ..Place::default() }, None);
        assert!(text.contains("terminal term_9"), "{text}");
        assert!(text.contains("pane unknown"), "{text}");
        assert!(text.contains("`cmux skill show`"), "{text}");
    }

    #[test]
    fn session_context_only_the_codex_launch_session_start_carries_it() {
        let launch = |name: &str| (name == HOOK_ROUTE_ENV).then(|| "launch".into());
        let inherited = |_: &str| None;
        assert!(applies("codex", "SessionStart", launch));
        assert!(!applies("codex", "SessionStart", inherited));
        assert!(!applies("codex", "Stop", launch));
        assert!(!applies("claude", "SessionStart", launch));
    }

    #[test]
    fn session_context_quotes_the_cli_only_when_the_shell_needs_it() {
        assert_eq!(shell_word(Path::new("/usr/local/bin/cmux-tui")), "/usr/local/bin/cmux-tui");
        assert_eq!(shell_word(Path::new("/a b/c")), "'/a b/c'");
        assert_eq!(shell_word(Path::new("/it's/c")), "'/it'\\''s/c'");
    }

    /// A session that answers the six reads: the place carries every id and
    /// the workspace name, each read names the id the previous one returned,
    /// and every read routes to the current machine and session.
    #[cfg(unix)]
    #[test]
    fn session_context_reads_the_place_from_a_session_that_answers() {
        use std::os::unix::net::UnixListener;
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("session.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        // The server answers until the test's own `done` connection, so a
        // read that stops early fails the asserts below instead of hanging.
        let server = std::thread::spawn(move || {
            let mut asked = Vec::new();
            loop {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line.trim() == "done" {
                    return asked;
                }
                let request: Value = serde_json::from_str(&line).unwrap();
                let params = &request["params"];
                let result = match request["operation"].as_str().unwrap() {
                    "session.get" => json!({"id": "session_1", "name": "bench"}),
                    "terminal.get" => json!({"id": params["terminal"], "tab_id": "tab_1"}),
                    "tab.get" => json!({"id": params["tab"], "pane_id": "pane_1"}),
                    "pane.get" => json!({"id": params["pane"], "screen_id": "screen_1"}),
                    "screen.get" => json!({"id": params["screen"], "workspace_id": "ws_1"}),
                    "workspace.get" => json!({"id": params["workspace"], "name": "api"}),
                    other => panic!("unexpected {other}"),
                };
                asked.push(request.clone());
                let response = json!({
                    "protocol": "cmux.protocol/2",
                    "type": "response",
                    "id": request["id"],
                    "ok": true,
                    "result": result,
                });
                let mut stream = reader.into_inner();
                writeln!(stream, "{response}").unwrap();
            }
        });
        let place = read(&socket, "term_1");
        writeln!(std::os::unix::net::UnixStream::connect(&socket).unwrap(), "done").unwrap();
        let asked = server.join().unwrap();
        assert_eq!(
            place,
            Place {
                session_name: Some("bench".into()),
                session_id: Some("session_1".into()),
                workspace: Some("ws_1".into()),
                workspace_name: Some("api".into()),
                screen: Some("screen_1".into()),
                pane: Some("pane_1".into()),
                tab: Some("tab_1".into()),
                terminal: "term_1".into(),
            }
        );
        let ids: Vec<_> = asked
            .iter()
            .map(|request| {
                let params = request["params"].as_object().unwrap();
                assert_eq!(params["machine"], "current", "{request}");
                assert_eq!(params["session"], "current", "{request}");
                let key = ["terminal", "tab", "pane", "screen", "workspace"]
                    .into_iter()
                    .find(|key| params.contains_key(*key));
                (
                    request["operation"].as_str().unwrap().to_owned(),
                    key.map(|key| params[key].clone()),
                )
            })
            .collect();
        assert_eq!(
            ids,
            [
                ("session.get".to_owned(), None),
                ("terminal.get".to_owned(), Some(json!("term_1"))),
                ("tab.get".to_owned(), Some(json!("tab_1"))),
                ("pane.get".to_owned(), Some(json!("pane_1"))),
                ("screen.get".to_owned(), Some(json!("screen_1"))),
                ("workspace.get".to_owned(), Some(json!("ws_1"))),
            ]
        );
    }

    /// A session that is not there answers nothing within the deadline: the
    /// place keeps only the terminal.
    #[cfg(unix)]
    #[test]
    fn session_context_an_absent_session_leaves_only_the_terminal() {
        let root = tempfile::tempdir().unwrap();
        let place = read(&root.path().join("absent.sock"), "term_1");
        assert_eq!(place, Place { terminal: "term_1".into(), ..Place::default() });
    }
}
