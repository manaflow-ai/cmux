//! `cmux-autocloud`: cmux stripped to the essentials (RFD 0139). One binary that signs in, opens
//! an agent chat on a machine (AutoCloud, an SSH box, this one), shows readiness 0-100, streams
//! the agent, and keeps the chat through a bad link: on a drop it dials again, re-attaches,
//! replays by seq and resends unconfirmed prompts under their promptId, so nothing is lost or
//! doubled.

mod link;
mod login;
mod readiness;
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
    /// An AutoCloud machine, over the Cloud carrier (needs `login`).
    #[arg(long, conflicts_with_all = ["host", "via"])]
    machine: Option<String>,
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

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
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
    Connected { generation: u64, link: Arc<Link>, session: String, history: Vec<Value> },
    Failed(u64, String),
    Redial(u64),
    Key(Event),
    Line(Option<String>),
    Tick,
}

pub struct App {
    pub spec: Spec,
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
            link.fire(
                "session/prompt",
                json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
                       "_meta": {"acpmux": {"promptId": id, "resend": resend}}}),
            );
        }
        // No link: the prompt stays unconfirmed and goes out on the next connect.
    }

    fn live(&self) -> bool {
        self.readiness.phase == Phase::Replayed
    }
}

async fn chat(args: ChatArgs) -> Result<()> {
    let spec = args.spec();
    let token = if spec.needs_sign_in() {
        match login::load() {
            Some(s) => Some(s.access_token),
            None => bail!("not signed in: run `cmux-autocloud login` first"),
        }
    } else {
        None
    };
    let plain = args.plain || !std::io::stdout().is_terminal();
    let first = args.prompt.join(" ");
    let mut app = App {
        spec: spec.clone(),
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
            }
            AppEvent::Redial(g) if g == app.generation => dial(app, ctx),
            AppEvent::Key(Event::Key(k)) if k.kind != KeyEventKind::Release => {
                let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
                match k.code {
                    KeyCode::Char('c' | 'd') if ctrl => break,
                    KeyCode::Enter if !app.input.trim().is_empty() => {
                        let text = std::mem::take(&mut app.input);
                        app.send_prompt(text);
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
        None => {
            let mut meta = serde_json::Map::new();
            meta.insert("name".to_owned(), json!(args.name));
            if let Some(m) = &args.model {
                meta.insert("harness".to_owned(), json!(m));
            }
            let meta = Value::Object(meta);
            let cwd = args.cwd.clone().unwrap_or_else(|| {
                match &args.machine.as_ref().or(args.host.as_ref()) {
                    Some(_) => "~".to_owned(),
                    None => std::env::current_dir()
                        .map(|d| d.display().to_string())
                        .unwrap_or_else(|_| "/".to_owned()),
                }
            });
            let r = tokio::time::timeout(
                deadline,
                link.request(
                    "session/new",
                    json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": meta}}),
                ),
            )
            .await??;
            match r.get("sessionId").and_then(Value::as_str) {
                Some(s) => s.to_owned(),
                None => bail!("session/new answered without a sessionId"),
            }
        }
    };
    let _ = tx.send(AppEvent::Phase(g, Phase::ChatOpen));
    let r = tokio::time::timeout(
        deadline,
        link.request(
            "_acpmux/attach",
            json!({"sessionId": session, "limit": 400, "visible": true}),
        ),
    )
    .await??;
    let history = r.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
    Ok((session, history))
}
