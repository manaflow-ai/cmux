//! The descriptor types. Every value is `const`, so the catalog is static data with no
//! parse at launch.

/// A string the app shows, in English, with the string-table key its translations are filed
/// under (`strings::lookup`). An empty key is text that is never translated (a symbol name, a
/// product name). `arg` fills the one `%@` or `%lld` of a format string. `strip` is a
/// translated prefix taken out of the resolved text (a density's name without "Density: ").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Text {
    pub table: &'static str,
    pub key: &'static str,
    pub en: &'static str,
    pub arg: Option<&'static str>,
    /// The prefix's table, key and English.
    pub strip: Option<(&'static str, &'static str, &'static str)>,
}

impl Text {
    /// Text that is the same in every language.
    pub const fn raw(en: &'static str) -> Self {
        Text { table: "", key: "", en, arg: None, strip: None }
    }

    /// This text with a translated prefix removed.
    pub const fn without(
        mut self,
        table: &'static str,
        key: &'static str,
        en: &'static str,
    ) -> Self {
        self.strip = Some((table, key, en));
        self
    }
}

/// Modifier bits of a [`Shortcut`], in the export's order ctrl, opt, shift, cmd.
pub const CTRL: u8 = 1;
pub const OPT: u8 = 2;
pub const SHIFT: u8 = 4;
pub const CMD: u8 = 8;

/// A key with its modifiers. `key` is the character as typed, lowercased; arrows and the other
/// function keys are their AppKit private-use characters (U+F700 and up).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Shortcut {
    pub key: &'static str,
    pub modifiers: u8,
}

/// A two-key default: the leader, then a key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Chord {
    pub first: Shortcut,
    pub second: Shortcut,
}

/// Whether a surface offers the action, or the reason it does not (`SurfaceExemption`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Offered,
    Exempt(&'static str),
}

impl Decision {
    /// The export's wire form: `offered` or the exemption's name.
    pub const fn wire(self) -> &'static str {
        match self {
            Decision::Offered => "offered",
            Decision::Exempt(reason) => reason,
        }
    }
}

/// One right-click placement: the menu, its group, the rank inside it, how it shows
/// (`item`, `choices`, `submenu`), and an optional submenu anchor, folder and label.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Placement {
    pub context: &'static str,
    pub group: &'static str,
    pub rank: i64,
    pub style: &'static str,
    pub parent: Option<&'static str>,
    pub folder: Option<&'static str>,
    pub label: Option<Text>,
}

/// Which surfaces offer the action, with a reason for each that does not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SurfacePlan {
    pub palette: Decision,
    pub cli: Option<Decision>,
    pub context_menus: &'static [Placement],
    pub context_menu_exemption: Option<&'static str>,
    pub mcp_exemption: Option<&'static str>,
}

impl SurfacePlan {
    pub const DEFAULT: SurfacePlan = SurfacePlan {
        palette: Decision::Offered,
        cli: None,
        context_menus: &[],
        context_menu_exemption: None,
        mcp_exemption: None,
    };

    /// The right-click decision: offered when placed, else the exemption.
    pub fn context_menu(&self) -> Option<Decision> {
        if !self.context_menus.is_empty() {
            return Some(Decision::Offered);
        }
        self.context_menu_exemption.map(Decision::Exempt)
    }

    /// The MCP decision: the CLI's, unless the CLI offers it and MCP is exempt.
    pub fn mcp(&self) -> Option<Decision> {
        match self.cli {
            Some(Decision::Offered) => {
                Some(self.mcp_exemption.map_or(Decision::Offered, Decision::Exempt))
            }
            other => other,
        }
    }
}

/// One value of an enumeration argument.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EnumCase {
    pub value: &'static str,
    pub title: Text,
}

/// The type of an argument.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArgKind {
    String,
    /// An integer, optionally limited to `min..=max`.
    Int(Option<(i64, i64)>),
    Bool,
    Enumeration(&'static [EnumCase]),
    /// A reference to an object of this target kind.
    Target(&'static str),
}

/// Known values of a free-text argument, listed by the app from `source`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Suggestions {
    pub source: &'static str,
    pub pinned: &'static [EnumCase],
    pub other_title: Option<Text>,
    pub allows_multiple: bool,
}

/// One typed argument of an action.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Argument {
    pub name: &'static str,
    pub title: Text,
    pub kind: ArgKind,
    pub required: bool,
    pub suggestions: Option<Suggestions>,
    pub is_target_name: bool,
    pub is_target_description: bool,
    pub is_supplied_by_target: bool,
    /// The palette asks for it although it may be omitted (a new worktree's name, Discard Unsaved
    /// Work): an empty answer runs without it. The CLI and MCP keep it optional.
    pub asked_in_palette: bool,
}

impl Argument {
    /// A copy that may be omitted.
    pub const fn optional(self) -> Self {
        let mut copy = self;
        copy.required = false;
        copy
    }

    /// A copy the palette asks for although it may be omitted (`asked_in_palette`).
    pub const fn asked_in_palette(self) -> Self {
        let mut copy = self.optional();
        copy.asked_in_palette = true;
        copy
    }
}

/// Surface bits of [`Action::surfaces`] (`ActionSurfaces`, the old app's inventory legend).
pub const PALETTE: u8 = 1;
pub const KEYBOARD: u8 = 2;
pub const MENU: u8 = 4;
pub const CONTEXT_MENU: u8 = 8;

/// One user-invocable action: the declaration every entrypoint (palette row, key binding,
/// menus, CLI verb, MCP tool) is generated from. Enumerations the app owns (category, target
/// kinds, context facts, menus) are named by their Swift raw values.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Action {
    pub id: &'static str,
    /// The catalog group the action is declared in (the old `Catalog/<Group>.swift`).
    pub group: &'static str,
    pub title: Text,
    /// One line the GUI shows beside the title (the palette row's subtitle while it can run, its
    /// Settings button's tooltip), for an action whose title alone does not say what it does.
    pub hint: Option<Text>,
    /// What the action does, for `action.list`, `action.describe` and MCP. English only.
    pub description: Option<&'static str>,
    pub keywords: &'static [&'static str],
    pub default_shortcut: Option<Shortcut>,
    /// Display text for a shortcut a `Shortcut` cannot express (`g g`).
    pub shortcut_label: Option<&'static str>,
    /// `digits`: the shortcut stands for 1 to 9.
    pub shortcut_family: Option<&'static str>,
    pub default_chord: Option<Chord>,
    pub category: &'static str,
    /// SF Symbol name.
    pub symbol: &'static str,
    pub surfaces: u8,
    pub surface_plan: SurfacePlan,
    /// Context facts that must all hold (`ActionContext` key names).
    pub requires: &'static [&'static str],
    pub arguments: &'static [Argument],
    pub targets: &'static [&'static str],
    pub cli_name: &'static str,
    pub main_menu: Option<&'static str>,
    pub is_debug_only: bool,
    pub is_destructive: bool,
    pub starts_terminal: bool,
    pub waits_for_result: bool,
    pub focuses: bool,
    pub is_person_only: bool,
    pub is_global_hot_key: bool,
    pub waits_for_person: bool,
    pub waits_for_keyed_create: bool,
    pub opens_workspace_content: bool,
}

impl Action {
    /// The defaults every catalog row starts from (`..Action::DEFAULT`).
    pub const DEFAULT: Action = Action {
        id: "",
        group: "",
        title: Text::raw(""),
        hint: None,
        description: None,
        keywords: &[],
        default_shortcut: None,
        shortcut_label: None,
        shortcut_family: None,
        default_chord: None,
        category: "",
        symbol: "command",
        surfaces: PALETTE,
        surface_plan: SurfacePlan::DEFAULT,
        requires: &[],
        arguments: &[],
        targets: &[],
        cli_name: "",
        main_menu: None,
        is_debug_only: false,
        is_destructive: false,
        starts_terminal: false,
        waits_for_result: false,
        focuses: false,
        is_person_only: false,
        is_global_hot_key: false,
        waits_for_person: false,
        waits_for_keyed_create: false,
        opens_workspace_content: false,
    };

    /// Whether the `cmux` CLI offers the action by its `cli_name`.
    pub fn cli(&self) -> bool {
        self.surface_plan.cli == Some(Decision::Offered)
    }

    /// Whether the palette lists the action.
    pub fn is_palette_visible(&self) -> bool {
        self.surface_plan.palette == Decision::Offered
    }
}

/// One default key binding that is not an action's own catalog shortcut: its key sequence,
/// the command, an optional string argument and an optional `when` clause (its text form).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Binding {
    pub keys: &'static [Shortcut],
    pub command: &'static str,
    pub argument: Option<&'static str>,
    pub arguments: &'static [(&'static str, BindingValue)],
    pub when: Option<&'static str>,
    pub source: &'static str,
}

/// A fixed argument value of a default binding.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BindingValue {
    String(&'static str),
    Int(i64),
    Bool(bool),
}

/// A palette category: its section and title.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Category {
    pub id: &'static str,
    pub title: Text,
    pub sort_order: i64,
}

impl Category {
    pub fn palette_section_order(&self) -> i64 {
        self.sort_order.saturating_add(100)
    }
}

/// A right-click menu folder: its title, symbol and the group it sits in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MenuFolder {
    pub id: &'static str,
    pub title: Text,
    pub symbol: &'static str,
    pub group: &'static str,
}

/// A palette family: actions the palette folds into one row (with a title and symbol), or
/// variants listed under a parent action.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PaletteFamily {
    pub id: &'static str,
    pub title: Text,
    pub symbol: &'static str,
    pub parent: Option<&'static str>,
    pub members: &'static [&'static str],
}

impl Placement {
    /// A placement in `context`'s menu, in `group`, at `rank`, shown as an item.
    pub const fn at(context: &'static str, group: &'static str, rank: i64) -> Self {
        Placement { context, group, rank, style: "item", parent: None, folder: None, label: None }
    }

    pub const fn style(mut self, style: &'static str) -> Self {
        self.style = style;
        self
    }

    pub const fn parent(mut self, parent: &'static str) -> Self {
        self.parent = Some(parent);
        self
    }

    pub const fn folder(mut self, folder: &'static str) -> Self {
        self.folder = Some(folder);
        self
    }

    pub const fn label(mut self, label: Text) -> Self {
        self.label = Some(label);
        self
    }
}
