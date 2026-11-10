//! The brief an agent works from. One text for every door (the CLI's
//! `cmux customize "…"`, the `/customize` chat command, the `customize_ask`
//! MCP tool), so an agent is told the same thing however it was asked.

use crate::tree::Part;
use crate::{Roots, Status};

/// What to do for `ask`, given where things live and what is live now.
/// Short on purpose: the smallest model should get it right, and the
/// recipes stay in the `cmux-customization` skill.
pub fn brief(ask: &str, roots: &Roots, status: &Status) -> String {
    let config = roots.config_dir.display();
    let mut text = String::new();
    text.push_str("Customize this cmux for the person. They asked:\n\n");
    for line in ask.trim().lines() {
        text.push_str(&format!("> {line}\n"));
    }
    text.push_str(&format!(
        "\n\
How this works: you edit the files below and cmux reloads each one as you save it, with no \
restart, so the person watches the real window change. That is the preview. You never need a \
backup copy: what was there is generation {current}, and they can go back to it in one step.\n\
\n\
Where things are:\n\
- {settings}: {settings_file} (`cmux settings list` shows every key; `cmux settings set KEY VALUE` writes one)\n\
- {keys}: {config}/keybindings.json\n\
- {themes}: {config}/themes/NAME.json\n\
- {views}: {views_dir}/ (place a section with `cmux apps place 'local/customize#cmux.section/1'`)\n\
- {styles}: {config}/agent-pane/theme.css\n\
- {automations}: make and change them with `cmux automation create|update …` (`cmux automation --help`)\n\
\n\
Recipes and working templates are in the cmux-customization skill; read the one that fits before you write.\n\
\n\
Do this:\n\
1. Make the smallest change that does what they asked. Change only what the ask needs.\n\
2. After each save, check it: run `cmux customize status --json` (or the customize_status tool). \
Fix every entry in `problems` (each names a file and a line) until there are none.\n\
3. Stop there. Do not apply and do not discard: that is the person's call. End with two sentences: \
what changed on screen, and that it is a preview they can Apply, keep refining by asking again, or Discard.\n",
        current = status.current.as_ref().map_or_else(|| "1".to_owned(), |generation| generation.n.to_string()),
        settings = Part::Settings.about(),
        settings_file = roots.settings_file.display(),
        keys = Part::Keybindings.about(),
        themes = Part::Themes.about(),
        views = Part::Views.about(),
        views_dir = roots.customize_dir.display(),
        styles = Part::Styles.about(),
        automations = Part::Automations.about(),
    ));
    let by_hand: Vec<&str> = status
        .changes
        .iter()
        .filter(|change| change.by_hand)
        .map(|change| change.path.as_str())
        .collect();
    if !by_hand.is_empty() {
        text.push_str(
            "\nThe person edited these by hand since your last turn. Read each one again before you \
write to it, and keep their edits:\n",
        );
        for path in by_hand {
            text.push_str(&format!("- {path}\n"));
        }
    }
    let earlier: Vec<&str> = status
        .draft
        .iter()
        .flat_map(|draft| draft.asks.iter())
        .map(|ask| ask.text.as_str())
        .filter(|text| *text != ask.trim())
        .collect();
    if !earlier.is_empty() {
        text.push_str("\nThis refines a preview that is already live. Earlier in the same draft they asked:\n");
        for ask in earlier {
            text.push_str(&format!("- {}\n", ask.lines().next().unwrap_or_default()));
        }
    }
    if !status.problems.is_empty() {
        text.push_str("\nThe live files have problems right now; fix these too:\n");
        for problem in &status.problems {
            text.push_str(&format!("- {}\n", problem.line()));
        }
    }
    text
}
