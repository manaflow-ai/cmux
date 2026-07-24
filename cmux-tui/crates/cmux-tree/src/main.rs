mod app;
mod codex;
mod config;
mod localization;
mod model;
mod trajectory;
mod ui;

use std::io::{self, IsTerminal};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use crossterm::cursor::Show;
use crossterm::event::{DisableMouseCapture, EnableMouseCapture, Event, poll, read};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;

use crate::app::App;
use crate::config::ConfigStore;
use crate::localization::{Catalog, Locale};

const INPUT_POLL_INTERVAL: Duration = Duration::from_millis(50);
const CLOCK_REDRAW_INTERVAL: Duration = Duration::from_secs(1);

fn main() -> ExitCode {
    let catalog = Catalog::new(Locale::detect());
    match run_main(catalog) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{}: {error:#}", catalog.error());
            ExitCode::FAILURE
        }
    }
}

fn run_main(catalog: Catalog) -> Result<()> {
    let Some(config_path) = parse_args(catalog)? else { return Ok(()) };
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        anyhow::bail!(catalog.interactive_terminal_required());
    }

    let mut app = App::load(ConfigStore::new(config_path))?;
    let _session = TerminalSession::enter(catalog)?;
    let backend = CrosstermBackend::new(io::stdout());
    let mut terminal = Terminal::new(backend).context(catalog.create_terminal())?;
    run(&mut terminal, &mut app, catalog)
}

fn parse_args(catalog: Catalog) -> Result<Option<PathBuf>> {
    let mut arguments = std::env::args_os().skip(1);
    let mut config_path = std::env::var_os("CMUX_TREE_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(ConfigStore::default_path);
    while let Some(argument) = arguments.next() {
        match argument.to_str() {
            Some("-h" | "--help") => {
                println!("{}", catalog.help());
                return Ok(None);
            }
            Some("-V" | "--version") => {
                println!("cmux-tree {}", env!("CARGO_PKG_VERSION"));
                return Ok(None);
            }
            Some("--config") => {
                let path = arguments.next().context(catalog.config_path_required())?;
                config_path = PathBuf::from(path);
            }
            Some(value) => anyhow::bail!(catalog.unknown_argument(value)),
            None => anyhow::bail!(catalog.utf8_arguments_required()),
        }
    }
    Ok(Some(config_path))
}

fn run(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    app: &mut App,
    catalog: Catalog,
) -> Result<()> {
    let mut dirty = true;
    let mut last_draw = Instant::now() - CLOCK_REDRAW_INTERVAL;
    loop {
        dirty |= app.process_network_events();
        if dirty || last_draw.elapsed() >= CLOCK_REDRAW_INTERVAL {
            terminal.draw(|frame| ui::draw(app, frame)).context(catalog.draw_terminal())?;
            dirty = false;
            last_draw = Instant::now();
        }
        if !poll(INPUT_POLL_INTERVAL).context(catalog.poll_input())? {
            continue;
        }
        match read().context(catalog.read_input())? {
            Event::Key(key) => {
                if !app.handle_key(key) {
                    return Ok(());
                }
                dirty = true;
            }
            Event::Mouse(mouse) => {
                app.handle_mouse(mouse);
                dirty = true;
            }
            Event::Resize(_, _) => dirty = true,
            Event::FocusGained | Event::FocusLost | Event::Paste(_) => {}
        }
    }
}

struct TerminalSession;

impl TerminalSession {
    fn enter(catalog: Catalog) -> Result<Self> {
        enable_raw_mode().context(catalog.enable_raw_mode())?;
        if let Err(error) = execute!(io::stdout(), EnterAlternateScreen, EnableMouseCapture) {
            let _ = disable_raw_mode();
            return Err(error).context(catalog.enter_alternate_screen());
        }
        Ok(Self)
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen, DisableMouseCapture, Show);
    }
}
