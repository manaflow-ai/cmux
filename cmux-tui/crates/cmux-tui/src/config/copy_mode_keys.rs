//! Copy-mode key table: every copy-mode command, its config name and default
//! chords, and the `keys.copy_mode` overrides that replace them.

use super::*;

/// One command of keyboard copy mode. Copy mode owns these keys while it is
/// active; the prefix key still arms prefix commands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CopyModeAction {
    CursorLeft,
    CursorRight,
    CursorUp,
    CursorDown,
    WordNext,
    WordPrev,
    WordEnd,
    BigWordNext,
    BigWordPrev,
    BigWordEnd,
    LineStart,
    LineFirstNonBlank,
    LineEnd,
    HistoryTop,
    HistoryBottom,
    ViewTop,
    ViewMiddle,
    ViewBottom,
    HalfPageUp,
    HalfPageDown,
    PageUp,
    PageDown,
    ScrollLineUp,
    ScrollLineDown,
    SelectChar,
    SelectLine,
    SelectBlock,
    SwapSelectionEnd,
    Yank,
    YankLine,
    SearchForward,
    SearchBackward,
    SearchNext,
    SearchPrev,
    Cancel,
    Exit,
}

/// A copy-mode command's config name and default chords.
struct CopyModeBinding {
    action: CopyModeAction,
    config_key: &'static str,
    defaults: &'static [&'static str],
}

const fn binding(
    action: CopyModeAction,
    config_key: &'static str,
    defaults: &'static [&'static str],
) -> CopyModeBinding {
    CopyModeBinding { action, config_key, defaults }
}

/// The copy-mode catalog in documentation order. Default chords use the
/// `keys` chord grammar; `ctrl+b` is left out because it is the default prefix.
static COPY_MODE_BINDINGS: [CopyModeBinding; 36] = [
    binding(CopyModeAction::CursorLeft, "cursor-left", &["h", "left"]),
    binding(CopyModeAction::CursorRight, "cursor-right", &["l", "right"]),
    binding(CopyModeAction::CursorUp, "cursor-up", &["k", "up"]),
    binding(CopyModeAction::CursorDown, "cursor-down", &["j", "down"]),
    binding(CopyModeAction::WordNext, "word-next", &["w"]),
    binding(CopyModeAction::WordPrev, "word-prev", &["b"]),
    binding(CopyModeAction::WordEnd, "word-end", &["e"]),
    binding(CopyModeAction::BigWordNext, "bigword-next", &["W"]),
    binding(CopyModeAction::BigWordPrev, "bigword-prev", &["B"]),
    binding(CopyModeAction::BigWordEnd, "bigword-end", &["E"]),
    binding(CopyModeAction::LineStart, "line-start", &["0", "home"]),
    binding(CopyModeAction::LineFirstNonBlank, "line-first-non-blank", &["^"]),
    binding(CopyModeAction::LineEnd, "line-end", &["$", "end"]),
    binding(CopyModeAction::HistoryTop, "history-top", &["g"]),
    binding(CopyModeAction::HistoryBottom, "history-bottom", &["G"]),
    binding(CopyModeAction::ViewTop, "view-top", &["H"]),
    binding(CopyModeAction::ViewMiddle, "view-middle", &["M"]),
    binding(CopyModeAction::ViewBottom, "view-bottom", &["L"]),
    binding(CopyModeAction::HalfPageUp, "half-page-up", &["ctrl+u"]),
    binding(CopyModeAction::HalfPageDown, "half-page-down", &["ctrl+d"]),
    binding(CopyModeAction::PageUp, "page-up", &["pageup"]),
    binding(CopyModeAction::PageDown, "page-down", &["pagedown", "ctrl+f"]),
    binding(CopyModeAction::ScrollLineUp, "scroll-line-up", &["ctrl+y"]),
    binding(CopyModeAction::ScrollLineDown, "scroll-line-down", &["ctrl+e"]),
    binding(CopyModeAction::SelectChar, "select-char", &["v", "space"]),
    binding(CopyModeAction::SelectLine, "select-line", &["V"]),
    binding(CopyModeAction::SelectBlock, "select-block", &["ctrl+v"]),
    binding(CopyModeAction::SwapSelectionEnd, "swap-selection-end", &["o"]),
    binding(CopyModeAction::Yank, "yank", &["y", "enter"]),
    binding(CopyModeAction::YankLine, "yank-line", &["Y"]),
    binding(CopyModeAction::SearchForward, "search-forward", &["/"]),
    binding(CopyModeAction::SearchBackward, "search-backward", &["?"]),
    binding(CopyModeAction::SearchNext, "search-next", &["n"]),
    binding(CopyModeAction::SearchPrev, "search-prev", &["N"]),
    binding(CopyModeAction::Cancel, "cancel", &["esc"]),
    binding(CopyModeAction::Exit, "exit", &["q", "ctrl+c"]),
];

/// Resolved copy-mode chords: the defaults with `keys.copy_mode` applied.
#[derive(Debug, Clone)]
pub struct CopyModeKeys {
    bindings: Vec<(Chord, CopyModeAction)>,
    by_chord: HashMap<Chord, CopyModeAction>,
}

impl Default for CopyModeKeys {
    fn default() -> Self {
        let bindings = COPY_MODE_BINDINGS
            .iter()
            .flat_map(|binding| {
                binding
                    .defaults
                    .iter()
                    .filter_map(|raw| parse_chord(raw))
                    .map(|chord| (chord, binding.action))
            })
            .collect();
        let mut keys = CopyModeKeys { bindings, by_chord: HashMap::new() };
        keys.rebuild();
        keys
    }
}

impl CopyModeKeys {
    fn rebuild(&mut self) {
        self.by_chord.clear();
        for &(chord, action) in &self.bindings {
            self.by_chord.entry(canonical_chord(chord)).or_insert(action);
        }
    }

    /// The copy-mode command bound to a key event.
    pub fn action_for(&self, key: &KeyEvent) -> Option<CopyModeAction> {
        self.by_chord.get(&canonical_chord(Chord { code: key.code, mods: key.modifiers })).copied()
    }

    /// The first chord bound to a command, for the copy-mode hint line.
    pub fn label(&self, action: CopyModeAction) -> Option<String> {
        self.bindings
            .iter()
            .find(|(_, bound)| *bound == action)
            .and_then(|(chord, _)| chord.display_label())
    }

    /// Apply a `keys.copy_mode` object. Each named command replaces all of
    /// its default chords; `"none"` leaves it unbound. A chord equal to the
    /// prefix is ignored, because the prefix keeps working in copy mode.
    pub(super) fn apply(&mut self, value: &Value, prefix: Chord) {
        let Some(object) = value.as_object() else {
            crate::client_log::stderr_log!(
                "config",
                "cmux-tui: ignoring non-object keys.copy_mode {value:?}"
            );
            return;
        };
        for (name, value) in object {
            let Some(binding) =
                COPY_MODE_BINDINGS.iter().find(|binding| binding.config_key == name)
            else {
                crate::client_log::stderr_log!(
                    "config",
                    "cmux-tui: ignoring unknown copy-mode action {name:?}"
                );
                continue;
            };
            self.bindings.retain(|(_, action)| *action != binding.action);
            for raw_chord in key_values(value) {
                if raw_chord.eq_ignore_ascii_case("none") {
                    continue;
                }
                let Some(chord) = parse_chord(raw_chord) else {
                    crate::client_log::stderr_log!(
                        "config",
                        "cmux-tui: ignoring unparseable copy-mode binding {name} = {raw_chord:?}"
                    );
                    continue;
                };
                if canonical_chord(chord) == canonical_chord(prefix) {
                    crate::client_log::stderr_log!(
                        "config",
                        "cmux-tui: ignoring copy-mode binding {name} = {raw_chord:?} because it conflicts with the prefix"
                    );
                    continue;
                }
                self.bindings
                    .retain(|(existing, _)| canonical_chord(*existing) != canonical_chord(chord));
                self.bindings.push((chord, binding.action));
            }
        }
        self.rebuild();
    }
}
