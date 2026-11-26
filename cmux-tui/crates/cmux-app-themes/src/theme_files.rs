//! Swift `GhosttyThemeFiles` (cx-wqn5.1): Save as Ghostty Theme writes a theme
//! with the user's edits into the user's Ghostty themes folder, and Import
//! Theme File copies one in. A theme file is Ghostty config, so only color keys
//! are written or copied: an imported `command =` or `config-file =` never
//! reaches Ghostty. The app does the file I/O and the stats; these build the
//! text and decide the refusals.

use serde::Serialize;

use crate::theme_spec::ThemeSpec;
use crate::trim_spaces;

/// The keys a theme file may set: colors only.
pub const COLOR_KEYS: [&str; 8] = [
    "palette",
    "background",
    "foreground",
    "cursor-color",
    "cursor-text",
    "selection-background",
    "selection-foreground",
    "bold-color",
];

/// Swift `ThemeCatalog.maximumThemeFileBytes`: a larger file is no theme.
pub const MAXIMUM_THEME_FILE_BYTES: usize = 64 * 1024;

/// Why a save or an import is refused (Swift `GhosttyThemeFiles.Refusal`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Refusal {
    /// Not one theme name Ghostty and the pickers accept as a file name.
    InvalidName,
    /// A shipped theme has this name; a user file would hide it.
    ShippedName,
    /// A user theme has this name and replacing it was not asked for.
    Exists,
    /// The base theme has no file.
    UnknownBase,
    /// The file has no color a theme sets (or is too large to be a theme).
    NotATheme,
}

/// Whether `name` can be a theme file's name: one theme spec name exactly (no
/// pair, no `#`, `=`, `"` or control characters), no `/`, no leading dot, no
/// surrounding spaces, at most 255 bytes (the file-name limit).
pub fn is_valid_name(name: &str) -> bool {
    if name.is_empty()
        || name.len() > 255
        || trim_spaces(name) != name
        || name.starts_with('.')
        || name.contains('/')
    {
        return false;
    }
    ThemeSpec::parse(name).is_some_and(|spec| spec.light == name && spec.dark == name)
}

/// The refusal for writing user theme `name`, from what the app found on disk:
/// a shipped theme of that name, a user theme of that name. None: write it.
pub fn destination_refusal(
    name: &str,
    shipped: bool,
    exists: bool,
    replace: bool,
) -> Option<Refusal> {
    if !is_valid_name(name) {
        Some(Refusal::InvalidName)
    } else if shipped {
        Some(Refusal::ShippedName)
    } else if !replace && exists {
        Some(Refusal::Exists)
    } else {
        None
    }
}

/// Swift `Character.isNewline`'s scalars.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `# cmux-accent = #rrggbb`.
pub fn accent_line(color: &str) -> String {
    format!("# {} = {color}", cmux_theme_tokens::THEME_ACCENT_KEY)
}

/// The `#rrggbb` (lowercase) of a `# cmux-accent = #rrggbb` line (`#` optional
/// before the digits); None for any other line (Swift `ThemeFileColors.accent`).
pub fn accent(line: &str) -> Option<String> {
    let body = trim_spaces(line.strip_prefix('#')?);
    let (key, value) = body.split_once('=')?;
    if trim_spaces(key) != cmux_theme_tokens::THEME_ACCENT_KEY {
        return None;
    }
    let value = trim_spaces(value);
    let digits = value.strip_prefix('#').unwrap_or(value);
    (digits.chars().count() == 6 && digits.bytes().all(|b| b.is_ascii_hexdigit()))
        .then(|| format!("#{}", digits.to_ascii_lowercase()))
}

/// The color lines of a theme file as `key = value`, and its `# cmux-accent`
/// line, in order; everything else is dropped.
pub fn color_lines(text: &str) -> Vec<String> {
    text.split(is_newline)
        .filter(|raw| !raw.is_empty())
        .filter_map(|raw| {
            let line = trim_spaces(raw);
            if let Some(color) = accent(line) {
                return Some(accent_line(&color));
            }
            if line.starts_with('#') {
                return None;
            }
            let (key, value) = line.split_once('=')?;
            let (key, value) = (trim_spaces(key), trim_spaces(value));
            (COLOR_KEYS.contains(&key) && !value.is_empty() && !value.contains(is_newline))
                .then(|| format!("{key} = {value}"))
        })
        .collect()
}

/// Swift `line.split(separator: "=", maxSplits: 2)`: empty pieces are
/// omitted, and after two pieces the rest is one piece.
fn split_equals(line: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut rest = line;
    while parts.len() < 2 {
        let Some(at) = rest.find('=') else { break };
        if at > 0 {
            parts.push(&rest[..at]);
        }
        rest = &rest[at + 1..];
    }
    if !rest.is_empty() {
        parts.push(rest);
    }
    parts
}

/// What a line sets: its key, and for `palette` its index (`palette 4`).
pub fn slot(line: &str) -> String {
    let parts: Vec<&str> = split_equals(line).into_iter().map(trim_spaces).collect();
    match parts.as_slice() {
        ["palette", index, ..] => format!("palette {index}"),
        [first, ..] => (*first).to_owned(),
        [] => line.to_owned(),
    }
}

/// `base` with each of `edits` replacing the line it sets (a palette edit,
/// that index's line); an edit the base does not set is added at the end.
pub fn merge(base: &[String], edits: &[String]) -> Vec<String> {
    let mut lines = base.to_vec();
    for edit in edits {
        let edit_slot = slot(edit);
        if let Some(index) = lines.iter().position(|line| slot(line) == edit_slot) {
            lines[index] = edit.clone();
            lines.retain(|line| line == edit || slot(line) != edit_slot);
        } else {
            lines.push(edit.clone());
        }
    }
    lines
}

/// The text of a file: each line, then a newline.
fn file_text(lines: &[String]) -> String {
    let mut text = lines.join("\n");
    text.push('\n');
    text
}

/// The file Save as Ghostty Theme writes for `name`: `base_text`'s colors with
/// `edits` (`ThemeEdits.configLines`, `key = value`) and the edited accent
/// (`#rrggbb`) over them, under a header line.
pub fn saved_theme(
    name: &str,
    base: &str,
    base_text: &str,
    edits: &[String],
    accent: Option<&str>,
) -> String {
    let mut edited = edits.to_vec();
    edited.extend(accent.map(accent_line));
    let mut lines = vec![format!("# {name}: {base} with edits, saved by cmux")];
    lines.extend(merge(&color_lines(base_text), &edited));
    file_text(&lines)
}

/// The theme name of an imported file: its name without a `.conf` or `.theme`
/// extension (any case).
pub fn import_name(file_name: &str) -> String {
    match file_name.rsplit_once('.') {
        Some((stem, extension))
            if !stem.is_empty()
                && ["conf", "theme"].contains(&extension.to_ascii_lowercase().as_str()) =>
        {
            stem.to_owned()
        }
        _ => file_name.to_owned(),
    }
}

/// An import: the theme name and the file text, colors only.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Imported {
    pub name: String,
    pub text: String,
}

/// The theme file Import Theme File writes from `text` (the file `file_name`,
/// `size` bytes), or `NotATheme` for a file over the size limit or with no
/// color line.
pub fn imported_theme(file_name: &str, text: &str, size: usize) -> Result<Imported, Refusal> {
    if size > MAXIMUM_THEME_FILE_BYTES {
        return Err(Refusal::NotATheme);
    }
    let colors = color_lines(text);
    if !colors.iter().any(|line| !line.starts_with('#')) {
        return Err(Refusal::NotATheme);
    }
    let name = import_name(file_name);
    let mut lines = vec![format!("# {name}: imported by cmux from {file_name}")];
    lines.extend(colors);
    Ok(Imported { name, text: file_text(&lines) })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROSE_PINE: &str = "palette = 0=#26233a\npalette = 4=#31748f\nbackground = #191724\nforeground = #e0def4\n\
        cursor-color = #555169\nselection-background = #403d52\nselection-foreground = #e0def4";

    fn strings(lines: &[&str]) -> Vec<String> {
        lines.iter().map(|line| (*line).to_owned()).collect()
    }

    // ThemeFileSaveTests.aSaveRefusesABadNameAShippedNameAndAnExistingThemeUnlessReplacing
    #[test]
    fn bad_names_are_refused() {
        for name in [
            "",
            " ",
            ".hidden",
            "a/b",
            "x=y",
            "#1",
            "quote\"d",
            "light:a,dark:b",
            " lead",
            "trail ",
            "a,b",
        ] {
            assert!(!is_valid_name(name), "{name:?}");
            assert_eq!(destination_refusal(name, false, false, false), Some(Refusal::InvalidName));
        }
        assert!(!is_valid_name(&"x".repeat(256)));
        assert!(is_valid_name("Rose Pine Ink"));
        assert!(is_valid_name("Mine"));
    }

    #[test]
    fn a_shipped_name_and_an_existing_theme_refuse_unless_replacing() {
        assert_eq!(destination_refusal("Rose Pine", true, false, true), Some(Refusal::ShippedName));
        assert_eq!(destination_refusal("Mine", false, true, false), Some(Refusal::Exists));
        assert_eq!(destination_refusal("Mine", false, true, true), None);
        assert_eq!(destination_refusal("Mine", false, false, false), None);
    }

    // ThemeFileSaveTests.aSavedThemeIsTheBaseWithItsEditsAndEveryPickerListsIt
    #[test]
    fn a_saved_theme_is_the_base_with_its_edits() {
        let edits =
            strings(&["background = #101010", "palette = 4=#88c0d0", "cursor-color = #ffffff"]);
        let text = saved_theme("Rose Pine Ink", "Rose Pine", ROSE_PINE, &edits, None);
        assert_eq!(
            text,
            "# Rose Pine Ink: Rose Pine with edits, saved by cmux\npalette = 0=#26233a\npalette = 4=#88c0d0\n\
             background = #101010\nforeground = #e0def4\ncursor-color = #ffffff\nselection-background = #403d52\n\
             selection-foreground = #e0def4\n"
        );
    }

    // ThemeAccentEditTests: the accent edit is a comment line Ghostty skips.
    #[test]
    fn an_accent_edit_replaces_the_base_accent_line() {
        let base = "background = #000000\n# cmux-accent = #112233\n";
        let text = saved_theme("A", "B", base, &[], Some("#abcdef"));
        assert_eq!(
            text,
            "# A: B with edits, saved by cmux\nbackground = #000000\n# cmux-accent = #abcdef\n"
        );
        let added = saved_theme("A", "B", "background = #000000", &[], Some("#abcdef"));
        assert!(added.ends_with("background = #000000\n# cmux-accent = #abcdef\n"));
    }

    // ThemeFileSaveTests.anImportedFileKeepsOnlyItsColors
    #[test]
    fn an_imported_file_keeps_only_its_colors() {
        let text = "# Night Owl\nbackground = #011627\nforeground = #d6deeb\npalette = 1=#ef5350\n\
            command = /bin/sh -c 'curl evil'\nconfig-file = /tmp/other\n";
        let imported = imported_theme("Night Owl", text, text.len()).unwrap();
        assert_eq!(imported.name, "Night Owl");
        assert_eq!(
            imported.text,
            "# Night Owl: imported by cmux from Night Owl\nbackground = #011627\nforeground = #d6deeb\npalette = 1=#ef5350\n"
        );
        assert_eq!(imported_theme("Fonts", "font-size = 14\n", 15), Err(Refusal::NotATheme));
        // An accent line alone is no theme.
        assert_eq!(imported_theme("A", "# cmux-accent = #112233\n", 24), Err(Refusal::NotATheme));
        assert_eq!(
            imported_theme("Big", "background = #000000", MAXIMUM_THEME_FILE_BYTES + 1),
            Err(Refusal::NotATheme)
        );
        assert!(imported_theme("Edge", "background = #000000", MAXIMUM_THEME_FILE_BYTES).is_ok());
    }

    #[test]
    fn an_import_name_drops_a_conf_or_theme_extension() {
        assert_eq!(import_name("Nord.conf"), "Nord");
        assert_eq!(import_name("Nord.THEME"), "Nord");
        assert_eq!(import_name("Nord.txt"), "Nord.txt");
        assert_eq!(import_name("Night Owl"), "Night Owl");
        assert_eq!(import_name(".conf"), ".conf");
        assert_eq!(import_name("a.b.conf"), "a.b");
    }

    #[test]
    fn color_lines_keep_color_keys_and_the_accent() {
        let text = "  background=#000000  \r\n\r\nfont-size = 14\n# comment = x\nforeground =\nnoequals\n\
            #cmux-accent=ABCDEF\n# cmux-accent = #12345\nbold-color = #ffffff\u{2028}cursor-text = #010101";
        assert_eq!(
            color_lines(text),
            strings(&[
                "background = #000000",
                "# cmux-accent = #abcdef",
                "bold-color = #ffffff",
                "cursor-text = #010101"
            ])
        );
    }

    #[test]
    fn accent_reads_only_the_accent_key_with_six_digits() {
        assert_eq!(accent("# cmux-accent = #A0b1C2").as_deref(), Some("#a0b1c2"));
        assert_eq!(accent("#cmux-accent=a0b1c2").as_deref(), Some("#a0b1c2"));
        assert_eq!(accent("# cmux-accent = #a0b1c"), None);
        assert_eq!(accent("# cmux-accent = #a0b1cg"), None);
        assert_eq!(accent("# other = #a0b1c2"), None);
        assert_eq!(accent("cmux-accent = #a0b1c2"), None);
        assert_eq!(accent("# cmux-accent"), None);
    }

    #[test]
    fn a_slot_is_the_key_and_a_palette_index() {
        assert_eq!(slot("palette = 4=#31748f"), "palette 4");
        assert_eq!(slot("background = #000000"), "background");
        assert_eq!(slot("palette"), "palette");
        assert_eq!(slot("=x"), "x");
        assert_eq!(slot(""), "");
        assert_eq!(slot("# cmux-accent = #abcdef"), "# cmux-accent");
    }

    #[test]
    fn merge_replaces_the_first_slot_line_drops_the_rest_and_appends_new_slots() {
        let base = strings(&[
            "background = #111111",
            "palette = 1=#aaaaaa",
            "background = #222222",
            "palette = 2=#bbbbbb",
        ]);
        let edits =
            strings(&["background = #333333", "palette = 2=#cccccc", "foreground = #ffffff"]);
        assert_eq!(
            merge(&base, &edits),
            strings(&[
                "background = #333333",
                "palette = 1=#aaaaaa",
                "palette = 2=#cccccc",
                "foreground = #ffffff"
            ])
        );
        // A line equal to the edit stays, like Swift's `$0 != edit` filter.
        let twice = strings(&["background = #333333", "background = #333333"]);
        assert_eq!(merge(&twice, &strings(&["background = #333333"])), twice);
    }
}
