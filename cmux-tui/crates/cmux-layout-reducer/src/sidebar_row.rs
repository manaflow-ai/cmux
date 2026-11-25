//! A workspace row's lifecycle in the sidebar as an explicit state machine (RFD 0026): the
//! app's `SidebarRowState` (live, stale, placeholder, creating) as an enum whose variants carry
//! their own data, plus `gone` for a row the list no longer holds, and one pure [`step`] from
//! `(Row, Event)` to the next row and the effects to run, or a named [`Refusal`]. Every (state,
//! event) pair is written out: no arm falls through to a default.
//!
//! The rules are the app's (CmuxNextSidebar `SidebarRowState`, `SidebarSeed`,
//! `SidebarSection+Membership`, `SidebarSection+RowContentChanges`, CmuxNextApp
//! `PendingWorkspaceRows`):
//!
//! - A placeholder (a machine still connecting with nothing saved) names no daemon workspace: a
//!   daemon list never turns it into a row, it only gives way once its section has loaded.
//! - A stale row (the app's saved sidebar, or a daemon's launch snapshot before its live tree)
//!   turns live when the live tree lists it and goes when the tree does not.
//! - A creating row (a create this app sent, from the press until the daemon lists it) is drawn
//!   in the final row's look and box, so the live row replaces it in place with nothing on screen
//!   changing. A tree that does not list it yet does not end it: only its create failing or a
//!   close taking it does.
//! - A placeholder or a creating row is pending: never selected, dragged, given a menu or saved.
//!
//! Daemon answers carry the [`Connection`] they came over and a create's end carries its
//! [`Create`] ticket, so a late answer from an older connection, or the end of an older create,
//! is refused and changes nothing.
//!
//! Each state has one render mapping ([`Row::render`]) with a declared layout box, and the
//! table ([`table`], committed as `schemas/sidebar-row/table.json`) is data another language
//! (the app's Swift) can replay. Nothing calls this yet.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The daemon connection an answer came over. Each reconnect of a machine is a newer one; the
/// app's own saved sidebar is `Connection(0)`, older than any daemon's.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Connection(pub u64);

/// The create a creating row stands for, and its end carries back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Create(pub u64);

/// A row's state and the data only that state has.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Row {
    /// A machine still connecting with nothing saved. Untitled it draws a static tonal bar;
    /// titled (a connecting SSH machine's pending row) it draws its title and second line.
    Placeholder { titled: bool },
    /// Saved or launch-snapshot data from `from`: the title and icon as last known, no live
    /// status, activity or unread counts.
    Stale { from: Connection },
    /// A workspace this app is creating under `create`, drawn as its live row will be.
    Creating { create: Create },
    /// Daemon data from `from`: everything the row shows is current.
    Live { from: Connection },
    /// No longer listed. Nothing leaves it.
    Gone,
}

impl Row {
    /// Every state's name, in the table's order. A titled placeholder is its own name: it
    /// draws differently.
    pub const KINDS: [&'static str; 6] =
        ["placeholder", "placeholder_titled", "stale", "creating", "live", "gone"];

    pub fn kind(&self) -> &'static str {
        match self {
            Row::Placeholder { titled: false } => "placeholder",
            Row::Placeholder { titled: true } => "placeholder_titled",
            Row::Stale { .. } => "stale",
            Row::Creating { .. } => "creating",
            Row::Live { .. } => "live",
            Row::Gone => "gone",
        }
    }

    /// The row names no daemon workspace yet (Swift `isPending`): no selection, menu, drag or
    /// save.
    pub fn is_pending(&self) -> bool {
        match self {
            Row::Placeholder { .. } | Row::Creating { .. } => true,
            Row::Stale { .. } | Row::Live { .. } | Row::Gone => false,
        }
    }

    /// How this state draws, or None for a row the list no longer holds.
    pub fn render(&self) -> Option<Render> {
        let render = |look, layout_box, interactive, provisional, live_status| Render {
            look,
            layout_box,
            interactive,
            saved: interactive,
            provisional,
            live_status,
        };
        match self {
            Row::Placeholder { titled: false } => {
                Some(render(Look::Bar, LayoutBox::Bar, false, true, false))
            }
            Row::Placeholder { titled: true } => {
                Some(render(Look::PendingTitle, LayoutBox::Row, false, true, false))
            }
            Row::Stale { .. } => Some(render(Look::LastKnown, LayoutBox::Row, true, true, false)),
            // Drawn as its live row will be: the final look in the final row's box.
            Row::Creating { .. } => Some(render(Look::Final, LayoutBox::Row, false, false, false)),
            Row::Live { .. } => Some(render(Look::Final, LayoutBox::Row, true, false, true)),
            Row::Gone => None,
        }
    }
}

/// What a row draws.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Look {
    /// A static tonal bar, a fraction of the row's width.
    Bar,
    /// A pending row's title and second line.
    PendingTitle,
    /// The title and icon as last known.
    LastKnown,
    /// The workspace's own title, folder line and kind: the live row's look.
    Final,
}

/// The box a row is laid out in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LayoutBox {
    /// A row's box with only the tonal bar in it.
    Bar,
    /// A workspace row's box, as a live row has it.
    Row,
}

/// One state's render mapping.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Render {
    pub look: Look,
    pub layout_box: LayoutBox,
    /// Selection, the context menu and drag reach it.
    pub interactive: bool,
    /// Written to the app's saved sidebar.
    pub saved: bool,
    /// Counts as not yet live daemon data (Swift `hasProvisionalRows`).
    pub provisional: bool,
    /// Shows live status, activity and unread counts.
    pub live_status: bool,
}

/// An answer from a daemon or a create, carrying what it was issued under, or an intent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Event {
    /// The daemon's launch snapshot over `connection`, before its live tree, lists the row.
    LaunchSnapshot { connection: Connection },
    /// The daemon's live tree over `connection` lists the row.
    Listed { connection: Connection },
    /// The row's section has loaded over `connection` and its live tree does not list the row.
    Unlisted { connection: Connection },
    /// The create issued under `create` failed.
    CreateFailed { create: Create },
    /// A close took the create issued under `create` before the daemon listed it.
    CreateClosed { create: Create },
    /// A selection, context menu or drag reaches the row.
    Interact,
}

impl Event {
    /// Every event's name, in the table's order.
    pub const KINDS: [&'static str; 6] =
        ["launch_snapshot", "listed", "unlisted", "create_failed", "create_closed", "interact"];

    pub fn kind(&self) -> &'static str {
        match self {
            Event::LaunchSnapshot { .. } => "launch_snapshot",
            Event::Listed { .. } => "listed",
            Event::Unlisted { .. } => "unlisted",
            Event::CreateFailed { .. } => "create_failed",
            Event::CreateClosed { .. } => "create_closed",
            Event::Interact => "interact",
        }
    }

    /// The generation the event carries (a connection or a create), None for an intent.
    pub fn generation(&self) -> Option<u64> {
        match self {
            Event::LaunchSnapshot { connection }
            | Event::Listed { connection }
            | Event::Unlisted { connection } => Some(connection.0),
            Event::CreateFailed { create } | Event::CreateClosed { create } => Some(create.0),
            Event::Interact => None,
        }
    }
}

/// What the caller runs after a transition, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum Effect {
    /// The row changes in its place: the list keeps its layout (Swift `keepsPlace`).
    PatchInPlace,
    /// The list is laid out again: the row changed state other than a create turning live, or
    /// it left the list.
    Relayout,
    /// The create's reserved name is released: the daemon lists it now, or the create ended.
    ReleaseName,
    /// The interaction runs.
    Allow,
}

impl Effect {
    pub fn kind(&self) -> &'static str {
        match self {
            Effect::PatchInPlace => "patch_in_place",
            Effect::Relayout => "relayout",
            Effect::ReleaseName => "release_name",
            Effect::Allow => "allow",
        }
    }
}

/// Why an event was refused. The row is unchanged.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Refusal {
    /// The row left the list; nothing leaves `gone`.
    RowGone,
    /// A placeholder names no daemon workspace, so no daemon list names it.
    NamesNoWorkspace,
    /// A creating row only gives way to its live row or to its create's end.
    AwaitsLiveList,
    /// A create's end for a row that is not creating.
    NotCreating,
    /// The end of another (older) create than the one the row stands for.
    StaleCreate,
    /// An answer over an older connection than the one the row's data came over.
    StaleConnection,
    /// The answer says what the row says already.
    Unchanged,
    /// The row is pending: no selection, menu or drag.
    Pending,
}

impl Refusal {
    pub const ALL: [Refusal; 8] = [
        Refusal::RowGone,
        Refusal::NamesNoWorkspace,
        Refusal::AwaitsLiveList,
        Refusal::NotCreating,
        Refusal::StaleCreate,
        Refusal::StaleConnection,
        Refusal::Unchanged,
        Refusal::Pending,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::RowGone => "row_gone",
            Refusal::NamesNoWorkspace => "names_no_workspace",
            Refusal::AwaitsLiveList => "awaits_live_list",
            Refusal::NotCreating => "not_creating",
            Refusal::StaleCreate => "stale_create",
            Refusal::StaleConnection => "stale_connection",
            Refusal::Unchanged => "unchanged",
            Refusal::Pending => "pending",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::error::Error for Refusal {}

pub type Step = Result<(Row, Vec<Effect>), Refusal>;

/// Whether a row moving from `from` to `to` keeps its place (Swift `keepsPlace`): the same
/// state, or its create's stand-in turned live.
pub fn keeps_place(from: Row, to: Row) -> bool {
    match (from, to) {
        (Row::Creating { .. }, Row::Live { .. }) => true,
        (from, to) => from.kind() == to.kind(),
    }
}

/// The row after `event`, and the effects to run; or why `event` is refused.
pub fn step(row: Row, event: Event) -> Step {
    match event {
        Event::LaunchSnapshot { connection } => match row {
            Row::Placeholder { .. } => Err(Refusal::NamesNoWorkspace),
            Row::Stale { from } => newer(from, connection)
                .map(|()| (Row::Stale { from: connection }, vec![Effect::PatchInPlace])),
            Row::Creating { .. } => Err(Refusal::AwaitsLiveList),
            // A reconnect's launch snapshot marks a live row stale until its live tree.
            Row::Live { from } => {
                if connection > from {
                    Ok((Row::Stale { from: connection }, vec![Effect::Relayout]))
                } else {
                    Err(Refusal::StaleConnection)
                }
            }
            Row::Gone => Err(Refusal::RowGone),
        },
        Event::Listed { connection } => match row {
            Row::Placeholder { .. } => Err(Refusal::NamesNoWorkspace),
            Row::Stale { from } => {
                at_least(from, connection)?;
                Ok((Row::Live { from: connection }, vec![Effect::Relayout]))
            }
            // The live row replaces its stand-in in place.
            Row::Creating { .. } => Ok((
                Row::Live { from: connection },
                vec![Effect::PatchInPlace, Effect::ReleaseName],
            )),
            Row::Live { from } => newer(from, connection)
                .map(|()| (Row::Live { from: connection }, vec![Effect::PatchInPlace])),
            Row::Gone => Err(Refusal::RowGone),
        },
        Event::Unlisted { connection } => match row {
            // Placeholders give way once their section loads, whatever it lists.
            Row::Placeholder { .. } => Ok((Row::Gone, vec![Effect::Relayout])),
            Row::Stale { from } | Row::Live { from } => {
                at_least(from, connection)?;
                Ok((Row::Gone, vec![Effect::Relayout]))
            }
            // The daemon lists a new workspace a moment after it answers the create.
            Row::Creating { .. } => Err(Refusal::AwaitsLiveList),
            Row::Gone => Err(Refusal::RowGone),
        },
        Event::CreateFailed { create: ended } | Event::CreateClosed { create: ended } => {
            match row {
                Row::Creating { create } => {
                    if create == ended {
                        Ok((Row::Gone, vec![Effect::Relayout, Effect::ReleaseName]))
                    } else {
                        Err(Refusal::StaleCreate)
                    }
                }
                Row::Placeholder { .. } | Row::Stale { .. } | Row::Live { .. } => {
                    Err(Refusal::NotCreating)
                }
                Row::Gone => Err(Refusal::RowGone),
            }
        }
        Event::Interact => match row {
            Row::Placeholder { .. } | Row::Creating { .. } => Err(Refusal::Pending),
            Row::Stale { .. } | Row::Live { .. } => Ok((row, vec![Effect::Allow])),
            Row::Gone => Err(Refusal::RowGone),
        },
    }
}

/// An answer over `got` may replace data from `had`: the same connection or a newer one.
fn at_least(had: Connection, got: Connection) -> Result<(), Refusal> {
    if got >= had { Ok(()) } else { Err(Refusal::StaleConnection) }
}

/// An answer over `got` says something new about data from `had` only from a newer connection;
/// the same one says it already.
fn newer(had: Connection, got: Connection) -> Result<(), Refusal> {
    match got.cmp(&had) {
        std::cmp::Ordering::Greater => Ok(()),
        std::cmp::Ordering::Equal => Err(Refusal::Unchanged),
        std::cmp::Ordering::Less => Err(Refusal::StaleConnection),
    }
}

/// The generation the table's sample states hold.
const SAMPLE: u64 = 7;

/// One row per state, in [`Row::KINDS`] order, holding [`SAMPLE`] where it holds a generation.
pub fn sample_states() -> [Row; 6] {
    [
        Row::Placeholder { titled: false },
        Row::Placeholder { titled: true },
        Row::Stale { from: Connection(SAMPLE) },
        Row::Creating { create: Create(SAMPLE) },
        Row::Live { from: Connection(SAMPLE) },
        Row::Gone,
    ]
}

/// One event per kind, in [`Event::KINDS`] order, carrying `generation`.
pub fn sample_events(generation: u64) -> [Event; 6] {
    let connection = Connection(generation);
    let create = Create(generation);
    [
        Event::LaunchSnapshot { connection },
        Event::Listed { connection },
        Event::Unlisted { connection },
        Event::CreateFailed { create },
        Event::CreateClosed { create },
        Event::Interact,
    ]
}

/// The generations each event is tried at against the sample states: older than, the same as
/// and newer than the one they hold.
const AGES: [(&str, u64); 3] = [("older", SAMPLE - 1), ("same", SAMPLE), ("newer", SAMPLE + 1)];

fn render_json(row: Row) -> Value {
    match row.render() {
        Some(r) => json!(r),
        None => Value::Null,
    }
}

/// The whole table as data: every state against every event at each generation age, each a
/// transition (the state it moves to, its effects' kinds and whether the row keeps its place)
/// or a named refusal; plus each state's render mapping.
pub fn table() -> Value {
    let mut rows = Vec::new();
    for row in sample_states() {
        // The same event at each age, so the ages of one event zip together.
        let [older, same, newer] = AGES.map(|(_, generation)| sample_events(generation));
        for ((older, same), newer) in older.into_iter().zip(same).zip(newer) {
            let tried: Vec<(Option<&str>, Event)> = if same.generation().is_some() {
                vec![(Some("older"), older), (Some("same"), same), (Some("newer"), newer)]
            } else {
                vec![(None, same)]
            };
            for (age, event) in tried {
                let mut entry = serde_json::Map::new();
                entry.insert("from".into(), json!(row.kind()));
                entry.insert("event".into(), json!(event.kind()));
                if let Some(age) = age {
                    entry.insert("generation".into(), json!(age));
                }
                match step(row, event) {
                    Ok((after, effects)) => {
                        entry.insert("to".into(), json!(after.kind()));
                        entry.insert(
                            "effects".into(),
                            json!(effects.iter().map(Effect::kind).collect::<Vec<_>>()),
                        );
                    }
                    Err(refusal) => {
                        entry.insert("refusal".into(), json!(refusal.as_str()));
                    }
                }
                rows.push(Value::Object(entry));
            }
        }
    }
    let states: Vec<Value> = sample_states()
        .iter()
        .map(|row| {
            json!({
                "state": row.kind(),
                "pending": row.is_pending(),
                "render": render_json(*row),
            })
        })
        .collect();
    json!({
        "version": 1,
        "source": "cmux-tui/crates/cmux-layout-reducer/src/sidebar_row.rs",
        "swift": "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Model/SidebarRowState.swift",
        "stale": "A daemon answer carries the connection it came over and a create's end its create ticket. Against a row holding generation 7 each is tried at 6 (older), 7 (same) and 8 (newer): an answer over an older connection is refused stale_connection, the end of another create stale_create, and an answer over the same connection that says what the row says already unchanged. A refusal leaves the row unchanged.",
        "layout": "A creating row is drawn in the final row's look and box (render.look final, render.layoutBox row, as live), and turning live it keeps its place (patch_in_place): nothing on screen changes. Every other change of state lays the list out again (relayout).",
        "states": states,
        "events": Event::KINDS,
        "refusals": Refusal::ALL.map(Refusal::as_str),
        "transitions": rows,
    })
}

/// [`table`] as the committed file's text.
pub fn table_text() -> String {
    // A Value's alternate Display is the pretty form and cannot fail.
    format!("{:#}\n", table())
}

#[cfg(test)]
mod tests;
