//! `cmux-autocloud`: cmux stripped to the essentials (RFD 0139). One binary that signs in, opens
//! an agent chat on a machine (AutoCloud, an SSH box, this one), shows readiness 0-100, streams
//! the agent, and keeps the chat through a bad link: on a drop it dials again, re-attaches,
//! replays by seq and resends unconfirmed prompts under their promptId, so nothing is lost or
//! doubled.

mod link;
mod login;
mod readiness;
mod start;
mod transcript;
mod ui;

use std::io::IsTerminal;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Result, bail};
use clap::{Args, Parser, Subcommand};
use crossterm::event::{Event, EventStream, KeyCode, KeyEventKind, KeyModifiers};
use futures_util::StreamExt;
use serde_json::{Value, json};
use tokio::io::AsyncBufReadExt;
use tokio::sync::mpsc;

use link::{Inbound, Link, Spec};
use readiness::{Phase, Readiness};
use transcript::Transcript;

#[derive(Parser)]
#[command(
    name = "cmux-autocloud",
    version,
    about = "An agent chat on any machine, in the terminal (RFD 0139)"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Cmd>,
    #[command(flatten)]
    chat: ChatArgs,
}

#[derive(Subcommand)]
enum Cmd {
    /// Sign in to cmux (a link to confirm on any device; no browser needed here).
    Login {
        #[arg(long, default_value = login::DEFAULT_CONFIG_URL)]
        config_url: String,
    },
    /// Forget the saved sign-in.
    Logout,
}

#[derive(Args, Clone)]
struct ChatArgs {
    /// An AutoCloud machine, over the Cloud carrier (needs `login`). Signed in and with no target,
    /// the chat goes to your AutoCloud machine anyway, starting one when there is none.
    #[arg(long, conflicts_with_all = ["host", "via", "new_machine", "local"])]
    machine: Option<String>,
    /// Start a new AutoCloud machine for this chat (needs `login`).
    #[arg(long, conflicts_with_all = ["host", "via", "local"])]
    new_machine: bool,
    /// Chat on this machine even when signed in (also `CMUX_AUTOCLOUD_START=0`).
    #[arg(long, conflicts_with_all = ["host", "via"])]
    local: bool,
    /// The Cloud API machines start on: prod, staging, dev or a URL (`CMUX_AUTOCLOUD_API`).
    #[arg(long, env = "CMUX_AUTOCLOUD_API", default_value = "prod")]
    api: String,
    /// The Cloud team to start machines in (default: the account's).
    #[arg(long)]
    team: Option<String>,
    /// A box you can SSH to that runs acpmux.
    #[arg(long, conflicts_with = "via")]
    host: Option<String>,
    /// Any command whose stdio is the agent daemon's JSON-RPC.
    #[arg(long)]
    via: Option<String>,
    /// Continue this chat instead of starting one.
    #[arg(long)]
    session: Option<String>,
    /// A name for a new chat.
    #[arg(long, default_value = "autocloud")]
    name: String,
    /// HARNESS[/MODEL] for a new chat (`claude`, `codex/gpt-5.5`).
    #[arg(short = 'm', long)]
    model: Option<String>,
    /// The new chat's working directory on the machine.
    #[arg(long)]
    cwd: Option<String>,
    /// Line output instead of the full-screen view (also when stdout is not a terminal).
    #[arg(long)]
    plain: bool,
    /// Exit once the agent finishes a turn and nothing is waiting (with a first prompt).
    #[arg(long)]
    until_idle: bool,
    /// Another chat to open beside this one, in its own column (repeat for more; Ctrl-N opens a
    /// new one, Tab moves between them).
    #[arg(long = "beside", value_name = "SESSION")]
    beside: Vec<String>,
    /// A first prompt.
    prompt: Vec<String>,
}

impl ChatArgs {
    fn spec(&self) -> Spec {
        if let Some(m) = &self.machine {
            Spec::Machine(m.clone())
        } else if let Some(h) = &self.host {
            Spec::Ssh(h.clone())
        } else if let Some(v) = &self.via {
            Spec::Via(v.clone())
        } else {
            Spec::Local
        }
    }
}

/// rustls needs a process-wide crypto provider; the workspace builds reqwest without one.
pub fn install_tls() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

/// Runs `cmux-autocloud` with these arguments (the first names the program, as `args_os` gives)
/// and returns its exit code. The `cmux` binary runs it as `cmux autocloud …`, so every cmux
/// install (Leo's NIGHTLY included) carries it; `cmux-autocloud` is the standalone build.
pub fn run(args: Vec<std::ffi::OsString>) -> i32 {
    let cli = match Cli::try_parse_from(args) {
        Ok(cli) => cli,
        Err(error) => {
            let _ = error.print();
            return if error.use_stderr() { 2 } else { 0 };
        }
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("cmux autocloud: cannot start its runtime: {error}");
            return 1;
        }
    };
    match runtime.block_on(main_with(cli)) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("cmux autocloud: {error:#}");
            1
        }
    }
}

async fn main_with(cli: Cli) -> Result<()> {
    match cli.command {
        Some(Cmd::Login { config_url }) => login::run(&config_url).await,
        Some(Cmd::Logout) => {
            let path = login::session_path();
            match std::fs::remove_file(&path) {
                Ok(()) => eprintln!("Signed out ({} removed).", path.display()),
                Err(_) => eprintln!("Not signed in."),
            }
            Ok(())
        }
        None => chat(cli.chat).await,
    }
}

/// Everything the loop reacts to.
pub enum AppEvent {
    Link(u64, Inbound),
    Phase(u64, Phase),
    Connected {
        generation: u64,
        link: Arc<Link>,
        session: String,
        history: Vec<Value>,
    },
    /// A chat beside the first opened (or re-attached) on the link: its session and history.
    SideOpened(u64, String, Vec<Value>),
    /// A side that could not open: said in the first chat, the link stays.
    SideFailed(String),
    Failed(u64, String),
    Redial(u64),
    Key(Event),
    Line(Option<String>),
    Tick,
}

/// A chat beside the first (RFD 0139 "several chats in one view"): on the same link, drawn in its
/// own column, prompted when it has the focus.
pub struct Side {
    pub session: String,
    pub transcript: Transcript,
}

pub struct App {
    pub spec: Spec,
    /// The chats beside the first, in column order.
    pub sides: Vec<Side>,
    /// Which chat takes the prompt: 0 the first, `n` the side `n - 1`.
    pub focus: usize,
    /// Sessions `--beside` asked for, opened on the first connect.
    beside: Vec<String>,
    pub readiness: Readiness,
    pub transcript: Transcript,
    pub session: Option<String>,
    pub link_note: String,
    pub reconnects: u64,
    pub input: String,
    pub scroll: u16,
    pub ticks: u64,
    generation: u64,
    link: Option<Arc<Link>>,
    /// Live records that arrived before the history: applied after it, so seq dedupe keeps order.
    early: Vec<(String, Value)>,
    first_prompt: Option<String>,
    sent_any: bool,
    /// Turns finished when the last prompt went out, so `--until-idle` waits for a new one.
    turns_at_send: u64,
    failures: u32,
    next_prompt: u64,
}

impl App {
    fn prompt_id(&mut self) -> String {
        self.next_prompt = self.next_prompt.saturating_add(1);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        format!("autocloud-{}-{nanos}-{}", std::process::id(), self.next_prompt)
    }

    fn send_prompt(&mut self, text: String) {
        let id = self.prompt_id();
        self.transcript.echo_prompt(&id, &text);
        self.sent_any = true;
        self.turns_at_send = self.transcript.turns_ended;
        self.push_prompt(&id, &text, false);
    }

    fn push_prompt(&self, id: &str, text: &str, resend: bool) {
        if let (Some(link), Some(session)) = (&self.link, &self.session) {
            fire_prompt(link, session, id, text, resend);
        }
        // No link: the prompt stays unconfirmed and goes out on the next connect.
    }

    /// A prompt to the focused chat: the first, or a side.
    fn prompt_focused(&mut self, text: String) {
        let Some(side) = self.focus.checked_sub(1) else {
            self.send_prompt(text);
            return;
        };
        let id = self.prompt_id();
        if let Some(s) = self.sides.get_mut(side) {
            s.transcript.echo_prompt(&id, &text);
            if let Some(link) = &self.link {
                fire_prompt(link, &s.session, &id, &text, false);
            }
        }
    }

    /// The next chat in the view takes the focus (wrapping).
    fn focus_next(&mut self) {
        self.focus = self.focus.saturating_add(1) % self.sides.len().saturating_add(1);
    }

    /// Takes the focused side out of the view (the chat itself goes on on the machine).
    fn close_focused(&mut self) {
        if let Some(side) = self.focus.checked_sub(1)
            && side < self.sides.len()
        {
            self.sides.remove(side);
            self.focus = side.min(self.sides.len());
        }
    }

    /// A side opened or re-attached: added once, its history applied (seq drops a repeat), and
    /// what it never confirmed sent again under the same id.
    fn side_opened(&mut self, session: String, history: &[Value]) {
        let at = match self.sides.iter().position(|s| s.session == session) {
            Some(at) => at,
            None => {
                self.sides.push(Side { session, transcript: Transcript::default() });
                self.focus = self.sides.len();
                self.sides.len().saturating_sub(1)
            }
        };
        let Some(side) = self.sides.get_mut(at) else { return };
        for ev in history {
            side.transcript.apply_event(ev);
        }
        if let Some(link) = &self.link {
            for (id, text) in side.transcript.unconfirmed().to_vec() {
                fire_prompt(link, &side.session, &id, &text, true);
            }
        }
    }

    fn live(&self) -> bool {
        self.readiness.phase == Phase::Replayed
    }
}

fn fire_prompt(link: &Link, session: &str, id: &str, text: &str, resend: bool) {
    link.fire(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
               "_meta": {"acpmux": {"promptId": id, "resend": resend}}}),
    );
}

async fn chat(mut args: ChatArgs) -> Result<()> {
    // Start (or reuse) the person's AutoCloud machine: asked with --new-machine, else on by
    // default for a signed-in chat with no target (start.rs).
    let untargeted = args.machine.is_none()
        && args.host.is_none()
        && args.via.is_none()
        && args.session.is_none()
        && args.beside.is_empty()
        && !args.local;
    let saved = login::load();
    let wants_cloud = args.new_machine
        || (untargeted
            && start::on_by_default(
                std::env::var(start::KILL_SWITCH).ok().as_deref(),
                saved.is_some(),
            ));
    if wants_cloud {
        let Some(session) = &saved else {
            bail!("not signed in: run `cmux-autocloud login` first");
        };
        let id = start::ensure_machine(
            &start::api_base(&args.api),
            &session.access_token,
            args.team.as_deref(),
            &args.name,
            args.new_machine,
            &mut |line| eprintln!("{line}"),
        )
        .await?;
        args.machine = Some(id);
    }
    let spec = args.spec();
    let token = if spec.needs_sign_in() {
        // A saved sign-in wins; a token already in the environment (CI, a
        // scripted run) is the fallback `cmux carrier dial` reads anyway.
        let saved = login::load().map(|s| s.access_token);
        let env = std::env::var("CMUX_CLOUD_ACCESS_TOKEN").ok().filter(|t| !t.trim().is_empty());
        match saved.or(env) {
            Some(token) => Some(token),
            None => bail!(
                "not signed in: run `cmux autocloud login` first (or set CMUX_CLOUD_ACCESS_TOKEN)"
            ),
        }
    } else {
        None
    };
    let plain = args.plain || !std::io::stdout().is_terminal();
    let first = args.prompt.join(" ");
    let mut app = App {
        spec: spec.clone(),
        sides: Vec::new(),
        focus: 0,
        beside: args.beside.clone(),
        readiness: Readiness::default(),
        transcript: Transcript::default(),
        session: args.session.clone(),
        link_note: String::new(),
        reconnects: 0,
        input: String::new(),
        scroll: 0,
        ticks: 0,
        generation: 0,
        link: None,
        early: Vec::new(),
        first_prompt: (!first.trim().is_empty()).then_some(first),
        sent_any: false,
        turns_at_send: 0,
        failures: 0,
        next_prompt: 0,
    };
    app.readiness.advance(Phase::SignedIn);

    let (tx, mut rx) = mpsc::unbounded_channel::<AppEvent>();
    let ctx = Ctx {
        args: args.clone(),
        token,
        tx: tx.clone(),
        scope: cmux_scope::Scope::new("cmux-autocloud chat"),
    };
    dial(&mut app, &ctx);

    // Input: keys in the full-screen view, lines in plain mode.
    let input_tx = tx.clone();
    if plain {
        ctx.scope.spawn_until_cancelled("stdin lines", async move {
            let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
            loop {
                let line = lines.next_line().await.ok().flatten();
                let end = line.is_none();
                if input_tx.send(AppEvent::Line(line)).is_err() || end {
                    break;
                }
            }
        });
    } else {
        ctx.scope.spawn_until_cancelled("terminal keys", async move {
            let mut keys = EventStream::new();
            while let Some(Ok(ev)) = keys.next().await {
                if input_tx.send(AppEvent::Key(ev)).is_err() {
                    break;
                }
            }
        });
    }
    let tick_tx = tx.clone();
    ctx.scope.spawn_until_cancelled("ticks", async move {
        let mut every = tokio::time::interval(Duration::from_millis(200));
        loop {
            every.tick().await;
            if tick_tx.send(AppEvent::Tick).is_err() {
                break;
            }
        }
    });

    let mut term = if plain { None } else { Some(ratatui::init()) };
    let mut printer = ui::Printer::default();
    let result = run_loop(&mut app, &ctx, &mut rx, &mut term, &mut printer, plain).await;
    if term.is_some() {
        ratatui::restore();
    }
    if plain {
        printer.flush(&app);
        printer.finish();
    }
    if let Some(s) = &app.session {
        eprintln!(
            "\nContinue this chat: cmux-autocloud{} --session {s}",
            ui::link_flags(&app.spec)
        );
    }
    result
}

struct Ctx {
    args: ChatArgs,
    token: Option<String>,
    tx: mpsc::UnboundedSender<AppEvent>,
    /// Owns every task the chat starts; they end when the chat does.
    scope: cmux_scope::Scope,
}

async fn run_loop(
    app: &mut App,
    ctx: &Ctx,
    rx: &mut mpsc::UnboundedReceiver<AppEvent>,
    term: &mut Option<ratatui::DefaultTerminal>,
    printer: &mut ui::Printer,
    plain: bool,
) -> Result<()> {
    let mut stdin_done = false;
    while let Some(ev) = rx.recv().await {
        match ev {
            AppEvent::Phase(g, p) if g == app.generation => app.readiness.advance(p),
            AppEvent::Link(g, Inbound::Up) if g == app.generation => {
                app.readiness.advance(Phase::LinkUp);
            }
            AppEvent::Link(g, Inbound::Notification { method, params }) if g == app.generation => {
                if let Some(fill) = params.pointer("/_meta/acpmux/fill").and_then(Value::as_u64) {
                    app.readiness.set_fill(fill);
                }
                for Side { session, transcript } in &mut app.sides {
                    transcript.apply_notification(session, &method, &params);
                }
                match &app.session {
                    Some(s) if app.live() => {
                        let s = s.clone();
                        app.transcript.apply_notification(&s, &method, &params);
                    }
                    _ => app.early.push((method, params)),
                }
            }
            AppEvent::Link(g, Inbound::Closed(why)) | AppEvent::Failed(g, why)
                if g == app.generation =>
            {
                lost(app, ctx, why);
            }
            AppEvent::Connected { generation, link, session, history }
                if generation == app.generation =>
            {
                app.link = Some(link);
                app.session = Some(session.clone());
                for ev in &history {
                    app.transcript.apply_event(ev);
                }
                for (method, params) in std::mem::take(&mut app.early) {
                    app.transcript.apply_notification(&session, &method, &params);
                }
                app.readiness.advance(Phase::Replayed);
                app.failures = 0;
                app.link_note.clear();
                // What was sent but never confirmed goes again under the same id; the daemon drops
                // a repeat, so a prompt that did land is not doubled.
                for (id, text) in app.transcript.unconfirmed().to_vec() {
                    app.push_prompt(&id, &text, true);
                }
                if let Some(p) = app.first_prompt.take() {
                    app.send_prompt(p);
                }
                // The chats beside it: re-attached after a drop, and `--beside` the first time.
                let mut sides: Vec<String> = app.sides.iter().map(|s| s.session.clone()).collect();
                sides.append(&mut app.beside);
                for s in sides {
                    open_side(app, ctx, Some(s));
                }
            }
            AppEvent::SideOpened(g, session, history) if g == app.generation => {
                app.side_opened(session, &history);
            }
            AppEvent::SideFailed(why) => app.transcript.items.push(transcript::Item::Note(why)),
            AppEvent::Redial(g) if g == app.generation => dial(app, ctx),
            AppEvent::Key(Event::Key(k)) if k.kind != KeyEventKind::Release => {
                let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
                match k.code {
                    KeyCode::Char('c' | 'd') if ctrl => break,
                    KeyCode::Char('n') if ctrl => open_side(app, ctx, None),
                    KeyCode::Char('w') if ctrl => app.close_focused(),
                    KeyCode::Tab => app.focus_next(),
                    KeyCode::Enter if !app.input.trim().is_empty() => {
                        let text = std::mem::take(&mut app.input);
                        app.prompt_focused(text);
                        app.scroll = 0;
                    }
                    KeyCode::Backspace => {
                        app.input.pop();
                    }
                    KeyCode::PageUp => app.scroll = app.scroll.saturating_add(10),
                    KeyCode::PageDown => app.scroll = app.scroll.saturating_sub(10),
                    KeyCode::Char(c) if !ctrl => app.input.push(c),
                    _ => {}
                }
            }
            AppEvent::Line(Some(line)) if !line.trim().is_empty() => app.send_prompt(line),
            AppEvent::Line(None) => stdin_done = true,
            AppEvent::Tick => app.ticks = app.ticks.wrapping_add(1),
            _ => {}
        }
        if let Some(t) = term {
            t.draw(|f| ui::draw(f, app))?;
        } else if app.live() {
            printer.flush(app);
        }
        let idle = app.transcript.unconfirmed().is_empty() && app.transcript.status != "running";
        if ctx.args.until_idle
            && app.sent_any
            && app.transcript.turns_ended > app.turns_at_send
            && idle
            && (stdin_done || !plain)
        {
            break;
        }
        // Plain mode with nothing to say: print the history and stop.
        if plain && stdin_done && app.live() && !app.sent_any && app.first_prompt.is_none() {
            break;
        }
    }
    // `--until-idle` is how scripts and the Cloud journey run one turn: a failed turn exits
    // non-zero with the daemon's reason instead of looking like a reply.
    if ctx.args.until_idle
        && let Some(why) = &app.transcript.turn_error
    {
        bail!("the agent's turn failed: {why}");
    }
    Ok(())
}

/// The link dropped or never came up: back to dialing, and dial again with a backoff.
fn lost(app: &mut App, ctx: &Ctx, why: String) {
    app.link = None;
    app.readiness.reset_link();
    app.reconnects = app.reconnects.saturating_add(1);
    app.failures = app.failures.saturating_add(1);
    app.early.clear();
    let wait =
        Duration::from_millis(250u64.checked_shl(app.failures.min(5)).unwrap_or(5_000).min(5_000));
    app.link_note = if why.is_empty() { "link lost".to_owned() } else { why };
    app.link_note.push_str(&format!(", redialing in {:.1}s", wait.as_secs_f32()));
    // Plain mode prints nothing until the chat is live, so a link that never comes up says why here.
    if ctx.args.plain || !std::io::stdout().is_terminal() {
        eprintln!("[{} · {}]", app.spec.describe(), app.link_note);
    }
    app.generation = app.generation.wrapping_add(1);
    let g = app.generation;
    let tx = ctx.tx.clone();
    ctx.scope.spawn_until_cancelled("redial backoff", async move {
        tokio::time::sleep(wait).await;
        let _ = tx.send(AppEvent::Redial(g));
    });
}

/// Start a link and open the chat on it, reporting each step.
fn dial(app: &mut App, ctx: &Ctx) {
    app.generation = app.generation.wrapping_add(1);
    let g = app.generation;
    app.readiness.advance(Phase::Dialing);
    let link_tx = ctx.tx.clone();
    let (inbound, mut inbound_rx) = mpsc::unbounded_channel();
    ctx.scope.spawn_until_cancelled("link inbound", async move {
        while let Some((gen_, ev)) = inbound_rx.recv().await {
            if link_tx.send(AppEvent::Link(gen_, ev)).is_err() {
                break;
            }
        }
    });
    let link =
        match Link::spawn(&app.spec, ctx.args.model.as_deref(), ctx.token.as_deref(), g, inbound) {
            Ok(l) => Arc::new(l),
            Err(e) => {
                let _ = ctx.tx.send(AppEvent::Failed(g, format!("{e:#}")));
                return;
            }
        };
    let tx = ctx.tx.clone();
    let args = ctx.args.clone();
    let session = app.session.clone();
    ctx.scope.spawn_until_cancelled("chat open", async move {
        match open(&link, g, &tx, &args, session).await {
            Ok((session, history)) => {
                let _ = tx.send(AppEvent::Connected { generation: g, link, session, history });
            }
            Err(e) => {
                let _ = tx.send(AppEvent::Failed(g, format!("{e:#}")));
            }
        }
    });
}

/// The folder a new chat names. A remote one (`--machine`, `--host`) names none unless
/// `--cwd` says so: the remote daemon refuses a relative path like `~` from a peer and
/// gives a chat with no `cwd` its own folder (`~/chats/<name>`) instead.
fn new_chat_cwd(args: &ChatArgs) -> Option<String> {
    if let Some(cwd) = &args.cwd {
        return Some(cwd.clone());
    }
    if args.machine.is_some() || args.host.is_some() {
        return None;
    }
    Some(
        std::env::current_dir().map(|d| d.display().to_string()).unwrap_or_else(|_| "/".to_owned()),
    )
}

async fn open(
    link: &Link,
    g: u64,
    tx: &mpsc::UnboundedSender<AppEvent>,
    args: &ChatArgs,
    session: Option<String>,
) -> Result<(String, Vec<Value>)> {
    let deadline = Duration::from_secs(30);
    tokio::time::timeout(
        deadline,
        link.request("initialize", json!({"protocolVersion": 1, "clientCapabilities": {}})),
    )
    .await??;
    let _ = tx.send(AppEvent::Phase(g, Phase::Initialized));
    let session = match session {
        Some(s) => s,
        None => new_session(link, args, &args.name).await?,
    };
    let _ = tx.send(AppEvent::Phase(g, Phase::ChatOpen));
    let history = attach(link, &session).await?;
    Ok((session, history))
}

/// A side chat on the live link: `session` re-attached, or a new chat when `None`. A failure is
/// said in the first chat and leaves the link alone.
fn open_side(app: &App, ctx: &Ctx, session: Option<String>) {
    let Some(link) = app.link.clone() else { return };
    let g = app.generation;
    let tx = ctx.tx.clone();
    let args = ctx.args.clone();
    let name = format!("{} {}", args.name, app.sides.len().saturating_add(2));
    ctx.scope.spawn_until_cancelled("side open", async move {
        let opened = async {
            let session = match session {
                Some(s) => s,
                None => new_session(&link, &args, &name).await?,
            };
            let history = attach(&link, &session).await?;
            anyhow::Ok((session, history))
        };
        let ev = match opened.await {
            Ok((session, history)) => AppEvent::SideOpened(g, session, history),
            Err(e) => AppEvent::SideFailed(format!("another chat did not open: {e:#}")),
        };
        let _ = tx.send(ev);
    });
}

/// `session/new` with the chat's name, harness and folder.
async fn new_session(link: &Link, args: &ChatArgs, name: &str) -> Result<String> {
    let deadline = Duration::from_secs(30);
    let mut meta = serde_json::Map::new();
    meta.insert("name".to_owned(), json!(name));
    if let Some(m) = &args.model {
        meta.insert("harness".to_owned(), json!(m));
    }
    let meta = Value::Object(meta);
    let mut params = serde_json::Map::new();
    params.insert("mcpServers".to_owned(), json!([]));
    params.insert("_meta".to_owned(), json!({"acpmux": meta}));
    if let Some(cwd) = new_chat_cwd(args) {
        params.insert("cwd".to_owned(), json!(cwd));
    }
    let params = Value::Object(params);
    let r = tokio::time::timeout(deadline, link.request("session/new", params)).await??;
    match r.get("sessionId").and_then(Value::as_str) {
        Some(s) => Ok(s.to_owned()),
        None => bail!("session/new answered without a sessionId"),
    }
}

/// `_acpmux/attach`: the chat's history, then its live records on this link.
async fn attach(link: &Link, session: &str) -> Result<Vec<Value>> {
    let deadline = Duration::from_secs(30);
    let r = tokio::time::timeout(
        deadline,
        link.request(
            "_acpmux/attach",
            json!({"sessionId": session, "limit": 400, "visible": true, "fill": true}),
        ),
    )
    .await??;
    Ok(r.get("events").and_then(Value::as_array).cloned().unwrap_or_default())
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
