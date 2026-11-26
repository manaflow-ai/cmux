//! The contrast check (`contrast.rs`): every theme file cmux ships or shows as an example passes
//! it, a look that paints light on light fails with the exact pair, and the chat shares it models
//! are still the webviews' own.

use std::path::{Path, PathBuf};

use cmux_theme_tokens::{Rgb, Scheme, ThemeInput};
use serde_json::{Value, json};

use super::contrast::{TEXT, UI, chat};
use super::*;
use crate::schema::Schema;

// affected-reads: Resources/cmux-themes Resources/ghostty/themes examples webviews/src/agent-session webviews/src/pages/shared/desktop.css
fn repo() -> PathBuf {
    // affected-reads: Resources/cmux-themes Resources/ghostty/themes examples webviews/src/agent-session/shared/styles.css webviews/src/agent-session/acpmux/conversation/conversation.css webviews/src/pages/shared/desktop.css
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn read(name: &str, text: &str) -> ThemeFile {
    ThemeFile::read(name, Some(Ok(text)), &json!({}), None, Schema::embedded(), &Domains::default())
}

/// A terminal theme the app bundles (`Resources/cmux-themes`, then Ghostty's
/// `Resources/ghostty/themes`), as the app reads it: its palette and its selection ink count.
fn bundled(name: &str) -> Option<ThemeInput> {
    ["Resources/cmux-themes", "Resources/ghostty/themes"].iter().find_map(|dir| {
        let text = std::fs::read_to_string(repo().join(dir).join(name)).ok()?;
        Scheme::parse(&text, name, None).ok().map(|scheme| scheme.theme_input())
    })
}

fn failures(name: &str, text: &str) -> Vec<String> {
    let file = read(name, text);
    file.contrast(&json!({}), &bundled).iter().map(|f| f.display()).collect()
}

#[test]
fn the_bundled_themes_are_found() {
    for name in ["Builtin Dark", "Claude Light", "Soft Blue"] {
        assert!(bundled(name).is_some(), "{name} not under Resources");
    }
}

/// Every theme file under `examples/` (`**/themes/*.json`).
fn example_theme_files() -> Vec<PathBuf> {
    fn walk(dir: &Path, found: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, found);
            } else if path.extension().is_some_and(|e| e == "json")
                && path.parent().and_then(Path::file_name).is_some_and(|d| d == "themes")
            {
                found.push(path);
            }
        }
    }
    let mut found = Vec::new();
    walk(&repo().join("examples"), &mut found);
    found.sort();
    found
}

/// Pairs no theme file value can fix: the app fits its text inks to the theme's own background,
/// not to a surface the look paints darker (`appearance.surfaces.sidebar.color`, the tab bar's),
/// so a muted caption on a selected row of a beige or gray sidebar stays under 4.5:1 whatever the
/// file says. The app's fix (inks fitted to the surface they sit on) takes these out; a pair here
/// that passes fails the test, so the list only shrinks.
const KNOWN: [(&str, &str); 28] = [
    ("astrolabe-dawn", "sidebar selected row muted text"),
    ("classic-desktop", "sidebar dim text"),
    ("classic-desktop", "sidebar muted text"),
    ("classic-desktop", "sidebar selected row muted text"),
    ("classic-desktop", "tab title (inactive)"),
    ("claude-desktop", "sidebar selected row muted text"),
    ("halo", "sidebar selected row muted text"),
    ("hearth", "sidebar selected row muted text"),
    ("lamina", "sidebar selected row muted text"),
    ("lamina-light", "sidebar selected row muted text"),
    ("lamina-mist", "sidebar selected row muted text"),
    ("lamina-mist-light", "sidebar selected row muted text"),
    ("lamina-slate", "sidebar selected row muted text"),
    ("lamina-slate-light", "sidebar selected row muted text"),
    ("lamina-tide", "sidebar selected row muted text"),
    ("lamina-tide-light", "sidebar selected row muted text"),
    ("leo-daylight", "sidebar selected row muted text"),
    ("overdrive-daylight", "sidebar selected row muted text"),
    ("plush", "sidebar selected row muted text"),
    ("plush-clay", "sidebar selected row muted text"),
    ("plush-dusk", "sidebar selected row muted text"),
    ("tonal", "sidebar selected row muted text"),
    ("tonal-clay", "sidebar selected row muted text"),
    ("tonal-clay-dark", "sidebar selected row muted text"),
    ("tonal-dark", "sidebar selected row muted text"),
    ("tonal-ink", "sidebar selected row muted text"),
    ("tonal-ink-dark", "sidebar selected row muted text"),
    ("workbench-light", "sidebar selected row muted text"),
];

/// Every failure of the files `(name, shown, text)`, less the [`KNOWN`] ones; a known pair that
/// passes is a failure too.
fn check_all(files: Vec<(String, String, String)>) {
    let mut problems = Vec::new();
    let mut seen = Vec::new();
    for (name, shown, text) in &files {
        for failure in read(name, text).contrast(&json!({}), &bundled) {
            if KNOWN.contains(&(name.as_str(), failure.element.as_str())) {
                seen.push((name.clone(), failure.element.clone()));
            } else {
                problems.push(format!("{shown}: {}", failure.display()));
            }
        }
    }
    for (name, element) in KNOWN {
        if files.iter().any(|(n, ..)| n == name)
            && !seen.contains(&(name.to_string(), element.to_string()))
        {
            problems.push(format!("{name}: {element} passes now: take it out of KNOWN"));
        }
    }
    assert!(problems.is_empty(), "light on light or dark on dark:\n{}", problems.join("\n"));
}

#[test]
fn every_shipped_theme_file_passes_the_contrast_check() {
    check_all(
        SHIPPED
            .iter()
            .map(|(name, text)| (name.to_string(), format!("themes/{name}.json"), text.to_string()))
            .collect(),
    );
}

#[test]
fn every_example_theme_file_passes_the_contrast_check() {
    let files = example_theme_files();
    assert!(!files.is_empty(), "no theme files under {}", repo().join("examples").display());
    check_all(
        files
            .into_iter()
            .map(|path| {
                let text = std::fs::read_to_string(&path).expect("example theme file");
                let name =
                    path.file_stem().and_then(|s| s.to_str()).unwrap_or_default().to_string();
                let shown = path.strip_prefix(repo()).unwrap_or(&path).display().to_string();
                (name, shown, text)
            })
            .collect(),
    );
}

#[test]
fn a_light_sidebar_on_a_dark_theme_fails_with_the_pair() {
    let found = failures(
        "mixed",
        r##"{ "appearance.theme": "Builtin Dark",
              "colors": { "background": "#1e1e1e", "foreground": "#eeeeee" },
              "appearance.surfaces.sidebar.color": "#f4f4f4",
              "appearance.surfaces.sidebar.opacity": 1 }"##,
    );
    let sidebar = found
        .iter()
        .find(|line| line.starts_with("Builtin Dark: sidebar text "))
        .unwrap_or_else(|| panic!("no sidebar text failure in {found:#?}"));
    assert!(sidebar.contains(" on #f4f4f4 is "), "{sidebar}");
    assert!(sidebar.ends_with("needs 4.5:1"), "{sidebar}");
    // The chat and the tab strip keep the dark page, so they read.
    assert!(!found.iter().any(|line| line.contains("chat text ")), "{found:#?}");
}

#[test]
fn a_selection_that_hides_the_terminal_text_fails() {
    // Builtin Light draws selected text black (`selection-foreground`): a navy selection hides it.
    let found = failures(
        "navy",
        r##"{ "appearance.theme": "Builtin Light",
              "colors": { "background": "#ffffff", "foreground": "#000000", "selection": "#000080" } }"##,
    );
    assert!(
        found.contains(
            &"Builtin Light: terminal selected text #000000 on #000080 is 1.31:1, needs 4.5:1"
                .to_string()
        ),
        "{found:#?}"
    );
    // With no selection ink Ghostty draws the background: a light selection on a light page hides it.
    let found = failures(
        "unnamed",
        r##"{ "appearance.theme": "No Such Theme",
              "colors": { "background": "#faf9f5", "foreground": "#141413", "selection": "#f0eee6" } }"##,
    );
    assert!(
        found
            .iter()
            .any(|f| f.starts_with("No Such Theme: terminal selected text #faf9f5 on #f0eee6")),
        "{found:#?}"
    );
}

#[test]
fn a_translucent_surface_is_read_over_the_window() {
    // White at 10% over a near-black window stays dark: the light text still reads.
    let found = failures(
        "veil",
        r##"{ "appearance.theme": "Builtin Dark",
              "colors": { "background": "#101010", "foreground": "#f0f0f0" },
              "appearance.surfaces.agentPane.color": "#ffffff",
              "appearance.surfaces.agentPane.opacity": 0.1 }"##,
    );
    assert!(found.is_empty(), "{found:#?}");
}

#[test]
fn a_status_color_too_close_to_the_sidebar_fails_as_a_mark() {
    let found = failures(
        "dim-status",
        r##"{ "appearance.theme": "Builtin Dark",
              "colors": { "background": "#1e1e1e", "foreground": "#eeeeee" },
              "appearance.statusIndicator.color": "#2a2a2a" }"##,
    );
    assert!(
        found
            .iter()
            .any(|f| f.contains("sidebar status indicator #2a2a2a") && f.ends_with("needs 3:1")),
        "{found:#?}"
    );
}

#[test]
fn the_thresholds_are_wcag_aa() {
    assert_eq!((TEXT, UI), (4.5, 3.0));
    assert!((Rgb::hex(0x767676).contrast(Rgb::WHITE) - 4.54).abs() < 0.01);
}

/// The shares `contrast::chat` models are the chat's own: a change to the stylesheet's mixes
/// must move the check with it.
#[test]
fn the_chat_shares_match_the_webviews_stylesheets() {
    let base = repo().join("webviews/src/agent-session");
    let styles = std::fs::read_to_string(base.join("shared/styles.css")).expect("styles.css");
    let conversation = std::fs::read_to_string(base.join("acpmux/conversation/conversation.css"))
        .expect("conversation.css");
    let desktop = std::fs::read_to_string(repo().join("webviews/src/pages/shared/desktop.css"))
        .expect("desktop.css");
    let percent = |share: f64| format!("{}%", (share * 1000.0).round() / 10.0);
    for (sheet, needle) in [
        (
            &conversation,
            format!(
                "--cv-bubble: color-mix(in srgb, var(--cv-fg) {}, transparent)",
                percent(chat::BUBBLE)
            ),
        ),
        // Code cards and inline code are the content surface levels: the chat's ink over clear.
        (&conversation, "--cv-fg: var(--agent-text)".to_string()),
        (&styles, "--ds-surface-ink: var(--agent-text)".to_string()),
        (&conversation, "--cv-codeblock-bg: var(--ds-surface-card)".to_string()),
        (
            &desktop,
            format!(
                "--ds-surface-card: color-mix(in srgb, var(--ds-surface-ink) {}, transparent)",
                percent(chat::CODE_CARD)
            ),
        ),
        (
            &conversation,
            format!(
                "--cv-codeblock-text: color-mix(in srgb, var(--cv-fg) {}, transparent)",
                percent(chat::CODE_TEXT)
            ),
        ),
        (&conversation, "--cv-code-bg: var(--ds-surface-inset)".to_string()),
        (
            &desktop,
            format!(
                "--ds-surface-inset: color-mix(in srgb, var(--ds-surface-ink) {}, transparent)",
                percent(chat::INLINE_CODE)
            ),
        ),
        (
            &styles,
            format!(
                "--agent-link-base: light-dark(#{:06x}, #{:06x})",
                chat::LINK_LIGHT,
                chat::LINK_DARK
            ),
        ),
        (
            &styles,
            format!(
                "--agent-link: color-mix(in oklab, var(--agent-link-base) {}, var(--agent-ansi-12",
                percent(chat::LINK_SHARE)
            ),
        ),
    ] {
        assert!(
            sheet.contains(&needle),
            "the chat no longer draws `{needle}`: update contrast::chat"
        );
    }
}

#[test]
fn a_named_theme_reads_its_own_colors() {
    let file = read("named", r#"{ "appearance.theme": "Paper" }"#);
    let paper = |name: &str| {
        (name == "Paper").then(|| ThemeInput {
            background: Rgb::hex(0xffffff),
            foreground: Rgb::hex(0xfafafa),
            ..Default::default()
        })
    };
    let found: Vec<String> =
        file.contrast(&Value::Null, &paper).iter().map(|f| f.display()).collect();
    assert!(
        found.iter().any(|f| f.starts_with("Paper: terminal text #fafafa on #ffffff")),
        "{found:#?}"
    );
}

#[test]
fn the_chrome_follows_a_named_app_theme() {
    // A dark terminal under a light app theme: the chrome's text is dark, so a dark sidebar the
    // file paints fails, while the terminal still reads.
    let file = read(
        "split",
        r##"{ "appearance.theme": "Builtin Dark", "appearance.appTheme": "Builtin Light",
              "appearance.surfaces.sidebar.color": "#202020",
              "appearance.surfaces.sidebar.opacity": 1 }"##,
    );
    let found: Vec<String> =
        file.contrast(&json!({}), &bundled).iter().map(|f| f.display()).collect();
    assert!(
        found
            .iter()
            .any(|f| f.starts_with("Builtin Dark (app theme Builtin Light): sidebar text ")),
        "{found:#?}"
    );
    assert!(!found.iter().any(|f| f.contains("terminal text")), "{found:#?}");
}

#[test]
fn ghostty_swaps_an_ink_only_under_a_minimum_contrast_above_one() {
    use super::contrast::ghostty_ink;
    let (black, gray) = (Rgb::hex(0x000000), Rgb::hex(0x424242));
    // cmux's default (Ghostty's): black stays black on a dark selection, as the Mac draws it.
    assert_eq!(ghostty_ink(black, gray, 1.0), black);
    // Under `minimum-contrast = 3`, the shader draws white there instead.
    assert_eq!(ghostty_ink(black, gray, 3.0), Rgb::WHITE);
    assert_eq!(ghostty_ink(Rgb::WHITE, gray, 3.0), Rgb::WHITE);
    let mut look = contrast::look_colors(
        &json!({}),
        ThemeInput {
            selection_background: Some(gray),
            selection_foreground: Some(black),
            ..Default::default()
        },
        ThemeInput::default(),
    );
    assert!(look.failures("t").iter().any(|f| f.element == "terminal selected text"));
    look.minimum_contrast = 4.5;
    assert!(!look.failures("t").iter().any(|f| f.element == "terminal selected text"));
}
