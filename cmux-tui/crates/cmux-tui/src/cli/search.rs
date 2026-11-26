//! `cmux search QUERY`: one search over agent sessions, the sidebar's workspaces and tabs,
//! terminal scrollback and browser history.
//!
//! Leo (2026-11-25): "for acpmux search should we have like... hm. should we have
//! cmux-search?"
//!
//! Each kind keeps its own backend and this file only fans out and merges:
//! - sessions: the acpmux engine's cross-session search (`_acpmux/session_search`, what
//!   `acpmux search` prints), over every session on this machine and its peers;
//! - workspaces: the daemon's sidebar tree (`list-workspaces`), each workspace and tab a row;
//! - terminal: the find bar's engine (`terminal-find`, Cmd-F) over every live terminal's whole
//!   retained scrollback;
//! - browser: the history store's search (`history.entries.list`, `cmux history search`).
//!
//! The rows are ranked by the app's Search page engine (`cmux-palette-ranker`), and the
//! query takes its filter tokens (`in:terminal`, `-in:browser`, `kind:session`) as the page
//! does. A row a content backend found (a transcript line, a scrollback match, a history
//! page) stays even when its text holds the words apart, after the rows the ranker kept.
//! A kind whose backend cannot answer (no daemon, no acpmux) is skipped and named under
//! `incomplete`; the others still print.

use std::io::{BufRead as _, BufReader, Write as _};
use std::time::{Duration, Instant};

use cmux_palette_ranker::{Entry, RankRequest, filter};
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode};

const USAGE: &str = "\
usage: cmux search QUERY [--kind KIND[,KIND]] [--limit N] [--json]

Search agent sessions, sidebar workspaces and tabs, terminal scrollback and
browser history at once, ranked by the app's search engine.

  --kind KIND   session, workspace, terminal or browser (repeat or comma-list)
  --limit N     rows per kind (default 10, at most 200)
  --json        one JSON object: {query, results, incomplete}

Filter tokens work as on the Search page: in:terminal, -in:browser, kind:session.
";

/// The kinds, in the order they print; the index is the ranker's section.
const KINDS: [Kind; 4] = [Kind::Session, Kind::Workspace, Kind::Terminal, Kind::Browser];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Session,
    Workspace,
    Terminal,
    Browser,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::Session => "session",
            Kind::Workspace => "workspace",
            Kind::Terminal => "terminal",
            Kind::Browser => "browser",
        }
    }

    fn heading(self) -> &'static str {
        match self {
            Kind::Session => "Sessions",
            Kind::Workspace => "Workspaces",
            Kind::Terminal => "Terminal",
            Kind::Browser => "Browser",
        }
    }

    fn section(self) -> i64 {
        KINDS.iter().position(|kind| *kind == self).unwrap_or(0) as i64
    }

    /// The words a filter token or `--kind` names this kind by (a prefix of one names it).
    fn words(self) -> &'static [&'static str] {
        match self {
            Kind::Session => &["Sessions", "session", "sessions", "agent", "chat"],
            Kind::Workspace => &["Workspaces", "workspace", "sidebar", "tab", "tabs"],
            Kind::Terminal => &["Terminal", "terminal", "scrollback"],
            Kind::Browser => &["Browser", "browser", "history", "page", "web"],
        }
    }

    fn parse(text: &str) -> Option<Kind> {
        let text = text.trim().to_ascii_lowercase();
        KINDS
            .into_iter()
            .find(|kind| kind.words().iter().any(|word| word.eq_ignore_ascii_case(&text)))
    }
}

fn section_names() -> Vec<Vec<String>> {
    KINDS.iter().map(|kind| kind.words().iter().map(|word| (*word).to_owned()).collect()).collect()
}

/// One result row before ranking. `found`: a content backend matched it (kept even when the
/// ranker drops it); a name row (a workspace or tab) shows only when the ranker keeps it.
#[derive(Debug, Clone)]
struct Row {
    kind: Kind,
    title: String,
    subtitle: String,
    keywords: Vec<String>,
    handles: Vec<String>,
    found: bool,
    /// The backend's own record, for `--json`.
    record: Value,
}

#[derive(Debug, PartialEq, Eq)]
struct Options {
    query: String,
    kinds: Vec<Kind>,
    limit: usize,
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let [verb, rest @ ..] = words.as_slice() else { return None };
    if verb != "search" {
        return None;
    }
    if rest.iter().any(|word| word == "-h" || word == "--help" || word == "help") {
        print!("{USAGE}");
        return Some(0);
    }
    let options = match parse_options(rest) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("cmux search: {message}\n{USAGE}");
            return Some(2);
        }
    };
    let (rows, incomplete) = gather(&global, &options);
    let ranked = rank(&options, rows);
    Some(print(&global, &options, &ranked, &incomplete))
}

fn parse_options(args: &[String]) -> Result<Options, String> {
    let mut words = Vec::new();
    let mut kinds = Vec::new();
    let mut limit = 10usize;
    let mut iter = args.iter();
    let mut literal = false;
    while let Some(arg) = iter.next() {
        if literal {
            words.push(arg.clone());
            continue;
        }
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (arg.as_str(), None),
        };
        match flag {
            "--" => literal = true,
            "--kind" | "--scope" => {
                let value =
                    inline.or_else(|| iter.next().cloned()).ok_or("--kind needs a value")?;
                for name in value.split(',').map(str::trim).filter(|name| !name.is_empty()) {
                    let kind = Kind::parse(name).ok_or_else(|| {
                        format!("--kind {name}: expected session, workspace, terminal or browser")
                    })?;
                    if !kinds.contains(&kind) {
                        kinds.push(kind);
                    }
                }
            }
            "--limit" => {
                let value =
                    inline.or_else(|| iter.next().cloned()).ok_or("--limit needs a value")?;
                limit = value
                    .parse::<usize>()
                    .ok()
                    .filter(|limit| (1..=200).contains(limit))
                    .ok_or_else(|| format!("--limit {value}: expected 1 to 200"))?;
            }
            other if other.starts_with("--") => return Err(format!("unknown option {other}")),
            _ => words.push(arg.clone()),
        }
    }
    let query = words.join(" ");
    // The Search page's filter tokens narrow the kinds as --kind does.
    let parsed = filter::parse(&query, &section_names());
    let mut kinds = if kinds.is_empty() { KINDS.to_vec() } else { kinds };
    kinds.retain(|kind| parsed.allows(kind.section()));
    if parsed.rest.trim().is_empty() {
        return Err("a query is required".into());
    }
    Ok(Options { query: parsed.rest, kinds, limit })
}

/// Every kind's rows, each backend on its own thread, and the kinds that could not answer.
fn gather(global: &GlobalArgs, options: &Options) -> (Vec<Row>, Vec<Value>) {
    let wants = |kind| options.kinds.contains(&kind);
    let query = options.query.as_str();
    let limit = options.limit;
    let (sessions, daemon, browser) = std::thread::scope(|scope| {
        let sessions = wants(Kind::Session).then(|| scope.spawn(|| sessions::search(query, limit)));
        let daemon = (wants(Kind::Workspace) || wants(Kind::Terminal)).then(|| {
            scope.spawn(|| sidebar_and_scrollback(global, query, limit, wants(Kind::Terminal)))
        });
        let browser = wants(Kind::Browser).then(|| scope.spawn(|| browser(global, query, limit)));
        (sessions.map(join), daemon.map(join), browser.map(join))
    });
    let mut rows = Vec::new();
    let mut incomplete = Vec::new();
    let mut skipped = |kinds: &[Kind], reason: String| {
        for kind in kinds {
            incomplete.push(json!({"kind": kind.name(), "reason": reason}));
        }
    };
    match sessions {
        Some(Ok((found, partial))) => {
            rows.extend(found);
            for reason in partial {
                skipped(&[Kind::Session], reason);
            }
        }
        Some(Err(reason)) => skipped(&[Kind::Session], reason),
        None => {}
    }
    match daemon {
        Some(Ok((found, partial))) => {
            rows.extend(found.into_iter().filter(|row| wants(row.kind)));
            for reason in partial {
                skipped(&[Kind::Terminal], reason);
            }
        }
        Some(Err(reason)) => {
            let kinds = [Kind::Workspace, Kind::Terminal];
            skipped(&kinds.into_iter().filter(|kind| wants(*kind)).collect::<Vec<_>>(), reason);
        }
        None => {}
    }
    match browser {
        Some(Ok(found)) => rows.extend(found),
        Some(Err(reason)) => skipped(&[Kind::Browser], reason),
        None => {}
    }
    (rows, incomplete)
}

fn join<T>(handle: std::thread::ScopedJoinHandle<'_, Result<T, String>>) -> Result<T, String> {
    handle.join().unwrap_or_else(|_| Err("the search thread panicked".to_owned()))
}

/// The rows ranked by the Search page's engine, grouped by kind in [`KINDS`] order, at most
/// `limit` per kind. A content hit the ranker dropped follows the kept rows in backend order.
fn rank(options: &Options, rows: Vec<Row>) -> Vec<(Row, Option<i64>)> {
    let entries = rows
        .iter()
        .map(|row| Entry {
            title: row.title.clone(),
            subtitle: (!row.subtitle.is_empty()).then(|| row.subtitle.clone()),
            keywords: row.keywords.clone(),
            handles: row.handles.clone(),
            section_index: Some(row.kind.section()),
            ..Entry::default()
        })
        .collect::<Vec<_>>();
    let request = RankRequest {
        operation: "rank".into(),
        entries: Some(entries),
        query: Some(options.query.clone()),
        ..RankRequest::default()
    };
    let mut scores: Vec<Option<i64>> = vec![None; rows.len()];
    let mut order = Vec::new();
    for section in cmux_palette_ranker::rank_request(&request) {
        for ranked in section.rows {
            if let Some(slot @ None) = scores.get_mut(ranked.index) {
                *slot = Some(ranked.score);
                order.push(ranked.index);
            }
        }
    }
    let mut out = Vec::new();
    let mut rows = rows.into_iter().map(Some).collect::<Vec<_>>();
    for kind in KINDS {
        let kept = order
            .iter()
            .copied()
            .filter(|index| matches!(rows.get(*index), Some(Some(row)) if row.kind == kind));
        let kept = kept.collect::<Vec<_>>();
        let dropped = rows
            .iter()
            .zip(&scores)
            .enumerate()
            .filter(|(_, (row, score))| {
                score.is_none() && row.as_ref().is_some_and(|row| row.kind == kind && row.found)
            })
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        for index in kept.into_iter().chain(dropped).take(options.limit) {
            if let Some(row) = rows.get_mut(index).and_then(Option::take) {
                out.push((row, scores.get(index).copied().flatten()));
            }
        }
    }
    out
}

fn print(
    global: &GlobalArgs,
    options: &Options,
    ranked: &[(Row, Option<i64>)],
    incomplete: &[Value],
) -> i32 {
    if matches!(global.output, OutputMode::Json | OutputMode::JsonLines) {
        let results = ranked
            .iter()
            .map(|(row, score)| {
                json!({
                    "kind": row.kind.name(),
                    "title": row.title,
                    "subtitle": row.subtitle,
                    "score": score,
                    "record": row.record,
                })
            })
            .collect::<Vec<_>>();
        let kinds = options.kinds.iter().map(|kind| kind.name()).collect::<Vec<_>>();
        let value = json!({
            "query": options.query,
            "kinds": kinds,
            "results": results,
            "incomplete": incomplete,
        });
        println!("{value}");
        return 0;
    }
    if matches!(global.output, OutputMode::Quiet) {
        return if ranked.is_empty() { 1 } else { 0 };
    }
    let mut stdout = std::io::stdout().lock();
    if ranked.is_empty() {
        let _ = writeln!(stdout, "No matches for {:?}.", options.query);
    }
    let mut heading = None;
    for (row, _) in ranked {
        if heading != Some(row.kind) {
            if heading.is_some() {
                let _ = writeln!(stdout);
            }
            let _ = writeln!(stdout, "{}", row.kind.heading());
            heading = Some(row.kind);
        }
        let title = one_line(&row.title, 60);
        if row.subtitle.is_empty() {
            let _ = writeln!(stdout, "  {title}");
        } else {
            let _ = writeln!(stdout, "  {title}  {}", one_line(&row.subtitle, 100));
        }
    }
    for skipped in incomplete {
        eprintln!(
            "cmux search: {} incomplete: {}",
            skipped["kind"].as_str().unwrap_or("?"),
            skipped["reason"].as_str().unwrap_or("?")
        );
    }
    0
}

/// `text` on one line, at most `max` characters.
fn one_line(text: &str, max: usize) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= max {
        return flat;
    }
    let mut cut = flat.chars().take(max.saturating_sub(1)).collect::<String>();
    cut.push('…');
    cut
}

fn text(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
}

// ---- sessions ----------------------------------------------------------------------------

#[cfg(unix)]
mod sessions {
    //! The acpmux engine's cross-session search, linked into this binary, at the home `cmux
    //! acp` uses. It never starts the acpmux daemon: with none running there are no sessions
    //! to search.

    use serde_json::{Value, json};

    use super::{Kind, Row, text};

    pub(super) fn search(query: &str, limit: usize) -> Result<(Vec<Row>, Vec<String>), String> {
        crate::acp::configure_home();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| error.to_string())?;
        let answer = runtime.block_on(async {
            let client = acpmux::deliver::connect()
                .await
                .map_err(|error| format!("no agent engine running: {error:#}"))?;
            let params = json!({"allSessions": true, "query": query, "limit": limit * 4});
            let request = client.request(acpmux::rpc::method::MUX_SESSION_SEARCH, params);
            match tokio::time::timeout(super::SESSION_TIMEOUT, request).await {
                Ok(answer) => answer.map_err(|error| format!("{error:#}")),
                Err(_) => Err(format!(
                    "the agent engine did not answer in {}s",
                    super::SESSION_TIMEOUT.as_secs()
                )),
            }
        })?;
        Ok(rows(&answer))
    }

    pub(super) fn rows(answer: &Value) -> (Vec<Row>, Vec<String>) {
        let mut seen = std::collections::HashSet::new();
        let hits = answer.get("hits").and_then(Value::as_array).cloned().unwrap_or_default();
        let rows = hits
            .into_iter()
            // One row per session and turn: a prompt and its reply both matching show once.
            .filter(|hit| seen.insert((text(hit, "session_id"), text(hit, "turn_time"))))
            .map(|hit| {
                let session = text(&hit, "session");
                let host = text(&hit, "host");
                let preview = text(&hit, "preview");
                let mut subtitle = preview.clone();
                if !host.is_empty() {
                    subtitle = format!("{host} · {} · {subtitle}", text(&hit, "turn_time"));
                }
                Row {
                    kind: Kind::Session,
                    title: if session.is_empty() { text(&hit, "session_id") } else { session },
                    subtitle,
                    keywords: vec![preview, host],
                    handles: Vec::new(),
                    found: true,
                    record: hit,
                }
            })
            .collect();
        let incomplete = answer
            .get("incomplete")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|why| why.as_str().map(str::to_owned))
            .collect();
        (rows, incomplete)
    }
}

#[cfg(not(unix))]
mod sessions {
    use super::Row;

    pub(super) fn search(_query: &str, _limit: usize) -> Result<(Vec<Row>, Vec<String>), String> {
        Err("agent sessions are not available on this platform".into())
    }
}

// timeout: a hung agent engine fails the session kind, never the whole search.
const SESSION_TIMEOUT: Duration = Duration::from_secs(10);

// ---- sidebar and scrollback --------------------------------------------------------------

// timeout: a stuck daemon fails these kinds instead of hanging the CLI.
const DAEMON_READ_TIMEOUT: Duration = Duration::from_secs(10);
/// The whole scrollback scan's budget: terminals past it are named under `incomplete`.
// timeout: a scan budget, not a failure; terminals past it are listed under `incomplete`.
const SCROLLBACK_BUDGET: Duration = Duration::from_secs(6);
/// Find-bar pages read per terminal (8192 rows each) before moving on.
const SCROLLBACK_PAGES: usize = 16;
/// Matches kept per terminal.
const MATCHES_PER_TERMINAL: usize = 3;

/// One connection to the session daemon, legacy commands answered in order.
struct Daemon {
    reader: BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>,
    next_id: u64,
}

impl Daemon {
    fn connect(global: &GlobalArgs) -> Result<Self, String> {
        let (socket, derived) = super::wire::resolve_socket_with_origin(global)
            .map_err(|error| super::wire::resolve_failure_message(&error))?;
        let stream = cmux_tui_core::server::connect_session_socket(&socket, derived)
            .map_err(|error| format!("cannot connect to {}: {error}", socket.display()))?;
        let _ = stream.set_read_timeout(Some(DAEMON_READ_TIMEOUT));
        Ok(Self { reader: BufReader::new(stream), next_id: 1 })
    }

    fn call(&mut self, mut request: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        if let Some(object) = request.as_object_mut() {
            object.insert("id".into(), json!(id));
        }
        writeln!(self.reader.get_mut(), "{request}")
            .and_then(|()| self.reader.get_mut().flush())
            .map_err(|error| error.to_string())?;
        let mut line = String::new();
        loop {
            line.clear();
            match self.reader.read_line(&mut line) {
                Ok(0) => return Err("the daemon closed the connection".into()),
                Ok(_) => {}
                Err(error) => return Err(error.to_string()),
            }
            let Ok(response) = serde_json::from_str::<Value>(&line) else { continue };
            if response.get("event").is_some() || response.get("id") != Some(&json!(id)) {
                continue;
            }
            if response.get("ok").and_then(Value::as_bool) == Some(true) {
                return Ok(response.get("data").cloned().unwrap_or(Value::Null));
            }
            return Err(response
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("request rejected")
                .to_owned());
        }
    }
}

/// The sidebar's workspace and tab rows and, with `scrollback`, every live terminal's
/// find-bar matches, from one daemon connection.
fn sidebar_and_scrollback(
    global: &GlobalArgs,
    query: &str,
    limit: usize,
    scrollback: bool,
) -> Result<(Vec<Row>, Vec<String>), String> {
    let mut daemon = Daemon::connect(global)?;
    let tree = daemon.call(json!({"cmd": "list-workspaces"}))?;
    let (mut rows, terminals) = sidebar_rows(&tree);
    let mut incomplete = Vec::new();
    if !scrollback {
        return Ok((rows, incomplete));
    }
    let deadline = Instant::now() + SCROLLBACK_BUDGET;
    let mut found = 0usize;
    let mut skipped = 0usize;
    for terminal in &terminals {
        if Instant::now() >= deadline || found >= limit * 4 {
            skipped += 1;
            continue;
        }
        let matches = match terminal_matches(&mut daemon, terminal.surface, query, deadline) {
            Ok(matches) => matches,
            // A terminal that closed or is not a PTY since the tree was read: skip it.
            Err(_) => continue,
        };
        for hit in matches {
            found += 1;
            let snippet = text(&hit, "snippet");
            rows.push(Row {
                kind: Kind::Terminal,
                title: snippet.trim().to_owned(),
                subtitle: format!("{} › {}", terminal.workspace, terminal.title),
                keywords: vec![terminal.title.clone(), terminal.workspace.clone()],
                handles: Vec::new(),
                found: true,
                record: json!({
                    "surface": terminal.surface,
                    "terminal_id": terminal.terminal_id,
                    "workspace": terminal.workspace,
                    "tab": terminal.title,
                    "match": hit,
                }),
            });
        }
    }
    if skipped > 0 {
        incomplete.push(format!("{skipped} terminal(s) not searched within the time budget"));
    }
    Ok((rows, incomplete))
}

#[derive(Debug, Clone, PartialEq)]
struct TerminalRef {
    surface: u64,
    terminal_id: String,
    title: String,
    workspace: String,
}

/// A row per workspace and per tab of the `list-workspaces` tree, and the live terminals
/// (active workspace first, so its scrollback is searched before the budget runs out).
fn sidebar_rows(tree: &Value) -> (Vec<Row>, Vec<TerminalRef>) {
    let mut rows = Vec::new();
    let mut terminals = Vec::new();
    let workspaces = tree.get("workspaces").and_then(Value::as_array).cloned().unwrap_or_default();
    for workspace in &workspaces {
        let name = first_text(workspace, &["title", "name", "key", "id"]);
        let group = text(workspace, "group");
        let mut handles = Vec::new();
        for key in ["short_id", "id", "resource_id", "key"] {
            if let Some(handle) = workspace.get(key).and_then(value_text) {
                handles.push(handle);
            }
        }
        let mut record = Map::new();
        for key in ["id", "resource_id", "key", "short_id", "name", "title", "group", "active"] {
            if let Some(value) = workspace.get(key) {
                record.insert(key.into(), value.clone());
            }
        }
        record.insert("type".into(), json!("workspace"));
        let mut tabs = Vec::new();
        collect_tabs(workspace, &mut tabs);
        let tab_titles = tabs.iter().map(tab_title).collect::<Vec<_>>();
        rows.push(Row {
            kind: Kind::Workspace,
            title: name.clone(),
            subtitle: if group.is_empty() {
                format!("{} tab(s)", tabs.len())
            } else {
                format!("{group} · {} tab(s)", tabs.len())
            },
            keywords: [vec![group, text(workspace, "name")], tab_titles].concat(),
            handles,
            found: false,
            record: Value::Object(record),
        });
        let active = workspace.get("active").and_then(Value::as_bool) == Some(true);
        for tab in &tabs {
            let title = tab_title(tab);
            let cwd = text(tab, "cwd");
            let branch = text(tab, "git_branch");
            let url = first_text(tab, &["url", "pinned_url"]);
            let detail = [url.as_str(), cwd.as_str(), branch.as_str()]
                .into_iter()
                .filter(|part| !part.is_empty())
                .collect::<Vec<_>>()
                .join(" · ");
            let mut handles = Vec::new();
            for key in ["short_id", "tab_resource_id", "terminal_id"] {
                if let Some(handle) = tab.get(key).and_then(value_text) {
                    handles.push(handle);
                }
            }
            let mut record = Map::new();
            for key in [
                "surface",
                "tab_resource_id",
                "terminal_id",
                "short_id",
                "name",
                "title",
                "cwd",
                "git_branch",
                "url",
            ] {
                if let Some(value) = tab.get(key).filter(|value| !value.is_null()) {
                    record.insert(key.into(), value.clone());
                }
            }
            record.insert("type".into(), json!("tab"));
            record.insert("workspace".into(), json!(name));
            rows.push(Row {
                kind: Kind::Workspace,
                title: title.clone(),
                subtitle: if detail.is_empty() {
                    format!("tab in {name}")
                } else {
                    format!("tab in {name} · {detail}")
                },
                keywords: vec![cwd, branch, url, name.clone()],
                handles,
                found: false,
                record: Value::Object(record),
            });
            let live = tab.get("dead").and_then(Value::as_bool) != Some(true);
            if let (Some(surface), Some(terminal_id), true) = (
                tab.get("surface").and_then(Value::as_u64),
                tab.get("terminal_id").and_then(Value::as_str),
                live,
            ) {
                let terminal = TerminalRef {
                    surface,
                    terminal_id: terminal_id.to_owned(),
                    title,
                    workspace: name.clone(),
                };
                if active { terminals.insert(0, terminal) } else { terminals.push(terminal) }
            }
        }
    }
    (rows, terminals)
}

/// Every tab under `node` (screens, panes and tab lists): an object with a numeric `surface`.
fn collect_tabs(node: &Value, tabs: &mut Vec<Value>) {
    match node {
        Value::Object(object) => {
            if object.get("surface").is_some_and(Value::is_u64) {
                tabs.push(node.clone());
                return;
            }
            for (key, child) in object {
                // A layout node names panes by id only; the panes list carries the tabs.
                if key != "layout" {
                    collect_tabs(child, tabs);
                }
            }
        }
        Value::Array(items) => items.iter().for_each(|item| collect_tabs(item, tabs)),
        _ => {}
    }
}

fn tab_title(tab: &Value) -> String {
    let title = first_text(tab, &["name", "title", "cwd"]);
    if title.is_empty() {
        format!("tab {}", tab.get("surface").and_then(Value::as_u64).unwrap_or(0))
    } else {
        title
    }
}

fn first_text(value: &Value, keys: &[&str]) -> String {
    keys.iter()
        .filter_map(|key| value.get(*key).and_then(Value::as_str))
        .find(|text| !text.trim().is_empty())
        .unwrap_or_default()
        .to_owned()
}

fn value_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

/// The newest find-bar matches in one terminal's whole retained scrollback, a page at a time.
fn terminal_matches(
    daemon: &mut Daemon,
    surface: u64,
    query: &str,
    deadline: Instant,
) -> Result<Vec<Value>, String> {
    let mut matches = Vec::new();
    let mut before = Value::Null;
    let mut epoch = Value::Null;
    for _ in 0..SCROLLBACK_PAGES {
        let mut request = json!({
            "cmd": "terminal-find",
            "surface": surface,
            "query": query,
            "max_matches": MATCHES_PER_TERMINAL,
        });
        if let (false, Some(object)) = (before.is_null(), request.as_object_mut()) {
            object.insert("before".into(), before.clone());
            object.insert("epoch".into(), epoch.clone());
        }
        let page = daemon.call(request)?;
        matches.extend(page.get("matches").and_then(Value::as_array).cloned().unwrap_or_default());
        let complete = page.get("complete").and_then(Value::as_bool) != Some(false);
        before = page.get("next_before").cloned().unwrap_or(Value::Null);
        epoch = page.get("epoch").cloned().unwrap_or(Value::Null);
        if complete
            || before.is_null()
            || matches.len() >= MATCHES_PER_TERMINAL
            || Instant::now() >= deadline
        {
            break;
        }
    }
    matches.truncate(MATCHES_PER_TERMINAL);
    Ok(matches)
}

// ---- browser history ---------------------------------------------------------------------

/// The history store's page visits whose text has every word (`cmux history search`).
fn browser(global: &GlobalArgs, query: &str, limit: usize) -> Result<Vec<Row>, String> {
    let (socket, derived) = super::wire::resolve_socket_with_origin(global)
        .map_err(|error| super::wire::resolve_failure_message(&error))?;
    let stream = cmux_tui_core::server::connect_session_socket(&socket, derived)
        .map_err(|error| format!("cannot connect to {}: {error}", socket.display()))?;
    let _ = stream.set_read_timeout(Some(DAEMON_READ_TIMEOUT));
    let mut reader = BufReader::new(stream);
    let mut params = Map::new();
    params.insert("machine".into(), json!("current"));
    params.insert("session".into(), json!("current"));
    params.insert("text".into(), json!(query));
    params.insert("kinds".into(), json!(["page"]));
    params.insert("limit".into(), json!(limit * 4));
    let answer = super::resolve::read(&mut reader, ResourceOperation::HistoryEntriesList, params)
        .map_err(failure_message)?;
    Ok(browser_rows(&answer))
}

fn failure_message(failure: super::resolve::Failure) -> String {
    use super::resolve::Failure;
    match failure {
        Failure::Resource(error) | Failure::Local { error, .. } => {
            error.get("message").and_then(Value::as_str).unwrap_or("request failed").to_owned()
        }
        Failure::Transport(message) => message,
        Failure::Refused => "the daemon refused the connection".to_owned(),
        Failure::AppAction { action, .. } => format!("{action} needs the cmux app"),
    }
}

fn browser_rows(answer: &Value) -> Vec<Row> {
    let entries = answer.get("entries").and_then(Value::as_array).cloned().unwrap_or_default();
    entries
        .into_iter()
        .map(|entry| {
            let url = first_text(&entry, &["url", "subtitle", "detail"]);
            let title = first_text(&entry, &["title", "url"]);
            Row {
                kind: Kind::Browser,
                title: if title.is_empty() { url.clone() } else { title },
                subtitle: url.clone(),
                keywords: vec![url],
                handles: Vec::new(),
                found: true,
                record: entry,
            }
        })
        .collect()
}

#[cfg(test)]
#[path = "search_tests.rs"]
mod tests;
