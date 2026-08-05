use std::io::{self, IsTerminal, Write};

use crossterm::{
    cursor,
    event::{self, Event, KeyCode, KeyEventKind},
    execute,
    style::{Attribute, Color, Print, ResetColor, SetAttribute, SetForegroundColor},
    terminal::{self, ClearType, EnterAlternateScreen, LeaveAlternateScreen},
};

use crate::cli::Error;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AddChoice {
    NewLogin,
    ImportLocal,
    Cancel,
}

const ITEMS: &[(AddChoice, &str, &str)] = &[
    (
        AddChoice::NewLogin,
        "Sign in to a new Codex subscription",
        "Opens the official Codex OAuth flow in an isolated profile.",
    ),
    (
        AddChoice::ImportLocal,
        "Import local Codex credentials",
        "Reviews and uploads Codex accounts already present on this machine.",
    ),
    (AddChoice::Cancel, "Cancel", "Make no changes."),
];

pub fn choose_add_action() -> Result<AddChoice, Error> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(Error::Usage(
            "`cr add` needs an interactive terminal; use `cr add login` or `cr add import`".into(),
        ));
    }
    let mut screen = Screen::enter()?;
    let mut selected = 0_usize;
    loop {
        screen.draw(selected)?;
        let Event::Key(key) = event::read()? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                selected = selected.checked_sub(1).unwrap_or(ITEMS.len() - 1);
            }
            KeyCode::Down | KeyCode::Char('j') => {
                selected = (selected + 1) % ITEMS.len();
            }
            KeyCode::Char('1') => return Ok(AddChoice::NewLogin),
            KeyCode::Char('2') => return Ok(AddChoice::ImportLocal),
            KeyCode::Enter => return Ok(ITEMS[selected].0),
            KeyCode::Esc | KeyCode::Char('q') => return Ok(AddChoice::Cancel),
            _ => {}
        }
    }
}

struct Screen {
    stdout: io::Stdout,
}

impl Screen {
    fn enter() -> Result<Self, Error> {
        terminal::enable_raw_mode()?;
        let mut stdout = io::stdout();
        execute!(stdout, EnterAlternateScreen, cursor::Hide)?;
        Ok(Self { stdout })
    }

    fn draw(&mut self, selected: usize) -> Result<(), Error> {
        execute!(
            self.stdout,
            cursor::MoveTo(0, 0),
            terminal::Clear(ClearType::All),
            SetAttribute(Attribute::Bold),
            Print("Add a Codex subscription\n\n"),
            SetAttribute(Attribute::Reset),
            SetForegroundColor(Color::DarkGrey),
            Print("Credentials are uploaded to your selected CodeRouter team vault.\n"),
            Print("Your normal ~/.codex/auth.json is never modified.\n\n"),
            ResetColor
        )?;
        for (index, (_, title, description)) in ITEMS.iter().enumerate() {
            if index == selected {
                execute!(
                    self.stdout,
                    SetForegroundColor(Color::Cyan),
                    SetAttribute(Attribute::Bold),
                    Print(format!("› {}. {title}\n", index + 1)),
                    SetAttribute(Attribute::Reset),
                    SetForegroundColor(Color::DarkGrey),
                    Print(format!("    {description}\n\n")),
                    ResetColor
                )?;
            } else {
                execute!(
                    self.stdout,
                    Print(format!("  {}. {title}\n", index + 1)),
                    SetForegroundColor(Color::DarkGrey),
                    Print(format!("    {description}\n\n")),
                    ResetColor
                )?;
            }
        }
        execute!(
            self.stdout,
            SetForegroundColor(Color::DarkGrey),
            Print("↑/↓ move  enter select  esc cancel"),
            ResetColor
        )?;
        self.stdout.flush()?;
        Ok(())
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        let _ = execute!(self.stdout, LeaveAlternateScreen, cursor::Show);
        let _ = terminal::disable_raw_mode();
    }
}
