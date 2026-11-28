//! The palette's navigation state machine: a stack of scope levels, each with its own query, rows
//! and selection, changed only by [`Reducer::reduce`] (`(state, event) -> (state', effects)`, pure,
//! with the scope [`Graph`] as its environment). Rules: plans/cmux-next/palette-scopes.md section
//! 4.3; the invariants of section 4.4 are checked by this module's property tests.
//!
//! A port of the macOS app's `PaletteNavReducer`; the app reaches it through [`Nav`] over the C
//! ABI (`cmux_palette_nav_*` in [`crate::ffi`]) and keeps only the effects it performs.

pub mod graph;
#[cfg(test)]
mod tests;

pub use graph::{Descriptor, Graph, Parents, Problem, ROOT};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// Which entry gestures are on (Debug Settings `palette.scopeEntry`) and how deep scopes nest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    /// A prefix typed into an empty query enters its scope.
    pub prefix_entry: bool,
    /// A keyword plus Tab enters its scope.
    pub keyword_entry: bool,
    pub max_depth: i64,
}

impl Default for Config {
    fn default() -> Self {
        Config { prefix_entry: true, keyword_entry: true, max_depth: 8 }
    }
}

impl Config {
    /// A config with at least two levels (the root and one scope).
    pub fn normalized(self) -> Self {
        Config { max_depth: self.max_depth.max(2), ..self }
    }
}

/// How a level was entered.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum Entry {
    /// Level 0.
    Root,
    /// Opened directly (shortcut, menu, CLI) above the root.
    Opened,
    /// A prefix typed into the parent's empty query.
    Prefix(String),
    /// The parent's query was this keyword and the user pressed Tab.
    Keyword(String),
    /// The scope row with this id was chosen (Return, Tab, click).
    Row(String),
    /// Tab on the parent's row with this id (its actions, its tabs).
    Drill(String),
    /// A command of the parent's row with this id (nil: no row) pushed a page of its own.
    Command(Option<String>),
}

impl Entry {
    /// Entered inside this palette session (Escape pops it).
    pub fn is_pushed(&self) -> bool {
        !matches!(self, Entry::Root | Entry::Opened)
    }
}

/// What navigation needs from a result row. Titles and commands stay in the palette model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub id: String,
    /// A scope row: Return or Tab enters this scope.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enters: Option<String>,
    /// Tab drills into this scope with the row as context.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drills: Option<String>,
    #[serde(default = "yes")]
    pub is_enabled: bool,
}

fn yes() -> bool {
    true
}

impl Row {
    pub fn new(id: impl Into<String>) -> Self {
        Row { id: id.into(), enters: None, drills: None, is_enabled: true }
    }
}

/// One level of the palette stack.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Level {
    pub id: i64,
    pub scope: String,
    pub entry: Entry,
    pub query: String,
    /// Bumps on every query change and refresh; batches carry it.
    pub generation: i64,
    /// The rows last accepted, for the generation `rows_generation`.
    pub rows: Vec<Row>,
    pub rows_generation: i64,
    /// The query text `rows` were found for.
    pub rows_query: Option<String>,
    /// A batch of `generation` is still expected.
    pub is_loading: bool,
    pub selection: Option<String>,
    /// Preserve intentional no-selection across refresh/provider batches.
    pub selection_suppressed: bool,
    /// The query changed: the next accepted batch selects the default row.
    pub pending_reset: bool,
    /// Return arrived while `rows` were stale: run once fresh rows land.
    pub pending_submit: bool,
    /// The user chose `selection` after the last query change.
    pub selection_pinned: bool,
    /// The chosen row a waiting Return runs when a later batch of this query brings it.
    pub pending_choice: Option<String>,
    /// The empty-query row index the last batch asked for, if any.
    pub empty_query_selection: Option<i64>,
    /// Bumps whenever `rows` is assigned, so a host mirror copies rows only when they changed.
    #[serde(skip)]
    pub rows_revision: u64,
}

impl Level {
    fn new(id: i64, scope: String, entry: Entry, query: String) -> Self {
        Level {
            id,
            scope,
            entry,
            query,
            generation: 1,
            rows: Vec::new(),
            rows_generation: 0,
            rows_query: None,
            is_loading: true,
            selection: None,
            selection_suppressed: false,
            pending_reset: true,
            pending_submit: false,
            selection_pinned: false,
            pending_choice: None,
            empty_query_selection: None,
            rows_revision: 0,
        }
    }

    /// The rows on screen belong to the current query.
    pub fn rows_are_current(&self) -> bool {
        self.rows_generation == self.generation
    }

    /// The drill or scope row this level was entered from.
    pub fn context(&self) -> Option<String> {
        match &self.entry {
            Entry::Drill(row) | Entry::Row(row) => Some(row.clone()),
            Entry::Command(row) => row.clone(),
            _ => None,
        }
    }

    fn set_rows(&mut self, rows: Vec<Row>) {
        self.rows = rows;
        self.rows_revision += 1;
    }
}

/// The palette's navigation state: client view state that never leaves the palette.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub is_open: bool,
    /// Level 0 is the root scope while open; empty while closed.
    pub levels: Vec<Level>,
    /// Next level id. Ids are unique for the life of the state.
    #[serde(rename = "nextLevelID")]
    pub next_level_id: i64,
}

impl Default for State {
    fn default() -> Self {
        State { is_open: false, levels: Vec::new(), next_level_id: 1 }
    }
}

impl State {
    pub fn top(&self) -> Option<&Level> {
        self.levels.last()
    }

    fn index_of_level(&self, id: i64) -> Option<usize> {
        self.levels.iter().position(|level| level.id == id)
    }
}

/// Inputs to the reducer: keys, field edits and source batches.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Event {
    /// Open on the root, or on `scope` above the root, with `query` typed.
    Open {
        #[serde(default)]
        scope: Option<String>,
        #[serde(default)]
        query: String,
    },
    /// The palette closed from outside.
    Close,
    /// The field's text changed.
    SetQuery {
        text: String,
        #[serde(default = "yes")]
        allows_scope_entry: bool,
    },
    /// Backspace with an empty field.
    BackspaceOnEmpty,
    Tab,
    ShiftTab,
    Escape,
    /// A click on the chip of level `index`: pop every level above it.
    PopTo {
        index: i64,
    },
    /// Return, or a click on row `row_id` (nil: the selection).
    Activate {
        #[serde(default, rename = "rowID")]
        row_id: Option<String>,
    },
    /// A command pushed its own page `scope` from row `row` of the top level, with `query` typed.
    Push {
        scope: String,
        #[serde(default)]
        row: Option<String>,
        #[serde(default)]
        query: String,
    },
    /// Arrow keys; wraps.
    Move {
        delta: i64,
    },
    Select {
        #[serde(rename = "rowID")]
        row_id: String,
    },
    /// Clear an intentionally exhausted section selection.
    ClearSelection,
    /// A batch from the source of `level_id` for `generation`.
    Results {
        #[serde(rename = "levelID")]
        level_id: i64,
        generation: i64,
        rows: Vec<Row>,
        replace: bool,
        is_final: bool,
        #[serde(default)]
        empty_query_selection: Option<i64>,
        #[serde(default)]
        provisional: bool,
    },
    /// The owner of the top level's data changed: reload, keep selection.
    Refresh,
    /// The top level shows another page in its place: the query is `query`, rows and selection
    /// start over.
    Restart {
        query: String,
    },
}

/// Why a step was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Refusal {
    DepthLimit,
}

/// Work for the palette model after a reducer step.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Effect {
    /// Ask the scope's source for `query`; tag batches with `generation`.
    Load {
        #[serde(rename = "levelID")]
        level_id: i64,
        scope: String,
        query: String,
        generation: i64,
        context: Option<String>,
    },
    /// Stop the level's sources (it was popped or the palette closed).
    Cancel {
        #[serde(rename = "levelID")]
        level_id: i64,
    },
    /// Run the primary command of `row_id`.
    Run {
        #[serde(rename = "levelID")]
        level_id: i64,
        #[serde(rename = "rowID")]
        row_id: String,
    },
    /// Open the Actions menu of `row_id` (Tab with nothing to enter).
    OpenActions {
        #[serde(rename = "rowID")]
        row_id: String,
    },
    /// Hide the palette.
    Dismiss,
    /// Accessibility announcement: the scope now on top.
    AnnounceEntered {
        scope: String,
    },
    AnnounceLeft {
        to: String,
    },
    Refused {
        reason: Refusal,
    },
}

/// The reducer: the scope graph and the entry config, applied to a [`State`].
#[derive(Debug, Clone, Default)]
pub struct Reducer {
    pub graph: Graph,
    pub config: Config,
}

impl Reducer {
    pub fn new(graph: Graph, config: Config) -> Self {
        Reducer { graph, config: config.normalized() }
    }

    /// Applies `event` to `state` and returns the effects to perform, in order.
    pub fn reduce(&self, state: &mut State, event: Event) -> Vec<Effect> {
        match event {
            Event::Open { scope, query } => return self.open(state, scope, query),
            Event::Close => return close(state),
            _ => {}
        }
        if !state.is_open || state.levels.is_empty() {
            return Vec::new();
        }
        let top = state.levels.len() - 1;
        match event {
            Event::Open { .. } | Event::Close => Vec::new(),
            Event::SetQuery { text, allows_scope_entry } => {
                self.set_query(state, text, allows_scope_entry)
            }
            Event::BackspaceOnEmpty => {
                if !state.levels[top].query.is_empty() {
                    return Vec::new();
                }
                self.pop(state, top as i64 - 1)
            }
            Event::Tab => self.tab(state),
            Event::ShiftTab => self.pop(state, top as i64 - 1),
            Event::Escape => self.escape(state),
            Event::PopTo { index } => self.pop(state, index),
            Event::Activate { row_id } => self.activate(state, row_id),
            Event::Push { scope, row, query } => {
                self.push(state, scope, Entry::Command(row), query, true)
            }
            Event::Move { delta } => {
                move_selection(state, delta);
                Vec::new()
            }
            Event::Select { row_id } => {
                let level = &mut state.levels[top];
                if level.rows.iter().any(|row| row.id == row_id) {
                    level.selection = Some(row_id);
                    pin(level);
                }
                Vec::new()
            }
            Event::ClearSelection => {
                let level = &mut state.levels[top];
                level.selection = None;
                level.selection_suppressed = true;
                level.pending_reset = false;
                level.pending_submit = false;
                level.selection_pinned = false;
                level.pending_choice = None;
                Vec::new()
            }
            Event::Results {
                level_id,
                generation,
                rows,
                replace,
                is_final,
                empty_query_selection,
                provisional,
            } => self.accept(
                state,
                level_id,
                generation,
                rows,
                replace,
                is_final,
                empty_query_selection,
                provisional,
            ),
            Event::Refresh => vec![reload(&mut state.levels[top])],
            Event::Restart { query } => {
                let level = &mut state.levels[top];
                level.set_rows(Vec::new());
                vec![edit(level, query)]
            }
        }
    }

    // MARK: Open and close

    fn open(&self, state: &mut State, scope: Option<String>, query: String) -> Vec<Effect> {
        let mut effects = close(state);
        state.is_open = true;
        let target = scope.filter(|scope| scope != ROOT);
        let root_query = if target.is_none() { query.clone() } else { String::new() };
        effects.extend(self.push(state, ROOT.to_owned(), Entry::Root, root_query, false));
        let Some(target) = target else { return effects };
        effects.extend(self.push(state, target, Entry::Opened, query, true));
        effects
    }

    // MARK: Stack

    fn push(
        &self,
        state: &mut State,
        scope: String,
        entry: Entry,
        query: String,
        announce: bool,
    ) -> Vec<Effect> {
        if state.levels.len() as i64 >= self.config.max_depth {
            return vec![Effect::Refused { reason: Refusal::DepthLimit }];
        }
        // Left from its selected row: popping back keeps that row, even if the level showed
        // provisional rows (a consumed keyword already reset the level on purpose).
        if !matches!(entry, Entry::Keyword(_))
            && let Some(top) = state.levels.last_mut()
        {
            top.pending_reset = false;
        }
        let level = Level::new(state.next_level_id, scope.clone(), entry, query);
        state.next_level_id += 1;
        let mut effects = vec![load(&level)];
        state.levels.push(level);
        if announce {
            effects.push(Effect::AnnounceEntered { scope });
        }
        effects
    }

    /// Pops every level above `index` (at least the root stays). The new top shows its cached
    /// rows, keeps its selection and reloads.
    fn pop(&self, state: &mut State, index: i64) -> Vec<Effect> {
        let keep = (index.max(0) + 1) as usize;
        if keep >= state.levels.len() {
            return Vec::new();
        }
        let mut effects = Vec::new();
        while state.levels.len() > keep {
            if let Some(level) = state.levels.pop() {
                effects.push(Effect::Cancel { level_id: level.id });
            }
        }
        let top = state.levels.len() - 1;
        let level = &mut state.levels[top];
        level.pending_submit = false;
        // Returning from a page is explicit navigation: resume normal fallback selection even if
        // the parent had intentionally exhausted a section.
        level.selection_suppressed = false;
        effects.push(reload(level));
        effects.push(Effect::AnnounceLeft { to: level.scope.clone() });
        effects
    }

    // MARK: Keys

    fn set_query(&self, state: &mut State, text: String, allows_scope_entry: bool) -> Vec<Effect> {
        let top = state.levels.len() - 1;
        let level = &state.levels[top];
        if level.query == text {
            return Vec::new();
        }
        if allows_scope_entry
            && self.config.prefix_entry
            && level.query.is_empty()
            && (state.levels.len() as i64) < self.config.max_depth
            && let Some((first, rest)) = graph::split_first_grapheme(&text)
            && let Some(child) = self.graph.child_by_prefix(&level.scope, first)
        {
            let child = child.id.clone();
            let (first, rest) = (first.to_owned(), rest.to_owned());
            return self.push(state, child, Entry::Prefix(first), rest, true);
        }
        vec![edit(&mut state.levels[top], text)]
    }

    fn tab(&self, state: &mut State) -> Vec<Effect> {
        let top = state.levels.len() - 1;
        let level = &state.levels[top];
        if self.config.keyword_entry
            && (state.levels.len() as i64) < self.config.max_depth
            && let Some(child) = self.graph.child_by_keyword(&level.scope, &level.query)
        {
            let child = child.id.clone();
            let keyword = graph::lowercased(graph::trim_whitespace(&level.query));
            // The keyword is consumed: the parent comes back with an empty query (reloaded when
            // the child pops).
            let level = &mut state.levels[top];
            level.query = String::new();
            level.generation += 1;
            level.pending_reset = true;
            level.pending_submit = false;
            level.selection_pinned = false;
            level.pending_choice = None;
            level.is_loading = true;
            return self.push(state, child, Entry::Keyword(keyword), String::new(), true);
        }
        let Some(row) = selected_row(level).cloned() else { return Vec::new() };
        if let Some(target) = row.enters.filter(|target| self.graph.contains(target)) {
            return self.push(state, target, Entry::Row(row.id), String::new(), true);
        }
        if let Some(target) = row.drills.filter(|target| self.graph.contains(target)) {
            return self.push(state, target, Entry::Drill(row.id), String::new(), true);
        }
        if row.is_enabled { vec![Effect::OpenActions { row_id: row.id }] } else { Vec::new() }
    }

    fn escape(&self, state: &mut State) -> Vec<Effect> {
        let top = state.levels.len() - 1;
        if state.levels[top].entry.is_pushed() {
            return self.pop(state, top as i64 - 1);
        }
        if !state.levels[top].query.is_empty() {
            return vec![edit(&mut state.levels[top], String::new())];
        }
        let mut effects = close(state);
        effects.push(Effect::Dismiss);
        effects
    }

    fn activate(&self, state: &mut State, row_id: Option<String>) -> Vec<Effect> {
        let top = state.levels.len() - 1;
        let level = &mut state.levels[top];
        if row_id.is_none() && level.selection_suppressed {
            return Vec::new();
        }
        if let Some(row_id) = row_id {
            if !level.rows.iter().any(|row| row.id == row_id) {
                return Vec::new();
            }
            level.selection = Some(row_id);
            level.selection_suppressed = false;
            pin(level);
        } else if !level.rows_are_current()
            && level.rows_query.as_deref() != Some(level.query.as_str())
        {
            // The rows on screen belong to an older query text (a refresh of the same text runs
            // the highlighted row at once).
            level.pending_submit = true;
            return Vec::new();
        } else if level.pending_reset && level.rows_are_current() {
            // Provisional rows (the empty query's stand-in): Return runs the ranked batch's
            // default row when it lands, unless the user chose a row (that clears the reset).
            level.pending_submit = true;
            return Vec::new();
        }
        let level = &state.levels[top];
        let Some(row) = selected_row(level).cloned() else { return Vec::new() };
        let level_id = level.id;
        if let Some(target) = row.enters.filter(|target| self.graph.contains(target)) {
            return self.push(state, target, Entry::Row(row.id), String::new(), true);
        }
        if row.is_enabled { vec![Effect::Run { level_id, row_id: row.id }] } else { Vec::new() }
    }

    // MARK: Results

    #[allow(clippy::too_many_arguments)]
    fn accept(
        &self,
        state: &mut State,
        level_id: i64,
        generation: i64,
        rows: Vec<Row>,
        replace: bool,
        is_final: bool,
        empty_query_selection: Option<i64>,
        provisional: bool,
    ) -> Vec<Effect> {
        let Some(index) = state.index_of_level(level_id) else { return Vec::new() };
        if state.levels[index].generation != generation {
            return Vec::new();
        }
        let is_top = index == state.levels.len() - 1;
        let level = &mut state.levels[index];
        if let Some(selection) = empty_query_selection {
            level.empty_query_selection = Some(selection.max(0));
        }
        let previous_index =
            level.rows.iter().position(|row| Some(&row.id) == level.selection.as_ref());
        if replace || level.rows_generation != generation {
            level.set_rows(unique(rows));
        } else {
            let mut merged = std::mem::take(&mut level.rows);
            merged.extend(rows);
            level.set_rows(unique(merged));
        }
        level.rows_generation = generation;
        level.rows_query = Some(level.query.clone());
        level.is_loading = !is_final;
        if level.selection_suppressed {
            level.selection = None;
            level.pending_submit = false;
            level.pending_choice = None;
            return Vec::new();
        }
        if let Some(choice) = level.pending_choice.clone()
            && level.rows.iter().any(|row| row.id == choice)
        {
            level.selection = Some(choice);
            level.pending_choice = None;
        }
        let shown = level
            .selection
            .as_ref()
            .is_some_and(|selection| level.rows.iter().any(|row| &row.id == selection));
        let fallback = |level: &Level| -> Option<String> {
            if level.rows.is_empty() {
                return None;
            }
            match previous_index {
                Some(previous) => Some(level.rows[previous.min(level.rows.len() - 1)].id.clone()),
                None => self.default_selection(level),
            }
        };
        if level.pending_reset {
            level.selection = self.default_selection(level);
            // Stand-in rows: the ranked batch picks the default row again.
            level.pending_reset = provisional;
        } else if level.pending_choice.is_some() {
            // A waiting Return's chosen row is still missing.
            if !shown {
                level.selection = fallback(level);
            }
            if !is_final {
                return Vec::new();
            }
            // The query's rows are complete without it: Return runs nothing it did not show.
            level.pending_choice = None;
            level.pending_submit = false;
        } else if shown {
            // Kept by id.
        } else if level.selection_pinned && level.pending_submit && !is_final {
            // Return waits for the chosen row: a later batch of this query may hold it.
            // Meanwhile the selection shows a row on screen.
            level.pending_choice = level.selection.clone();
            level.selection = fallback(level);
            return Vec::new();
        } else {
            level.selection = fallback(level);
            // The chosen row is not in this query's results: Return runs nothing it did not show.
            if level.selection_pinned {
                level.pending_submit = false;
            }
        }
        let submit = level.pending_submit && is_top;
        level.pending_submit = false;
        if submit { self.activate(state, None) } else { Vec::new() }
    }

    fn default_selection(&self, level: &Level) -> Option<String> {
        if level.rows.is_empty() {
            return None;
        }
        let preferred = if level.query.is_empty() {
            level
                .empty_query_selection
                .or_else(|| self.graph.descriptor(&level.scope).map(|d| d.empty_query_selection))
                .unwrap_or(0)
        } else {
            0
        };
        let index = preferred.clamp(0, level.rows.len() as i64 - 1) as usize;
        Some(level.rows[index].id.clone())
    }
}

fn close(state: &mut State) -> Vec<Effect> {
    let effects =
        state.levels.iter().rev().map(|level| Effect::Cancel { level_id: level.id }).collect();
    state.levels.clear();
    state.is_open = false;
    effects
}

fn move_selection(state: &mut State, delta: i64) {
    let top = state.levels.len() - 1;
    let level = &mut state.levels[top];
    level.selection_suppressed = false;
    if level.rows.is_empty() {
        return;
    }
    let count = level.rows.len() as i64;
    let current = level
        .rows
        .iter()
        .position(|row| Some(&row.id) == level.selection.as_ref())
        .map_or(-1, |index| index as i64);
    let next = (current.wrapping_add(delta) % count + count) % count;
    level.selection = Some(level.rows[next as usize].id.clone());
    pin(level);
}

/// The user chose the selection: fresh rows of the current query keep it.
fn pin(level: &mut Level) {
    level.selection_suppressed = false;
    level.pending_reset = false;
    level.selection_pinned = true;
    level.pending_choice = None;
}

fn edit(level: &mut Level, text: String) -> Effect {
    level.query = text;
    level.pending_reset = true;
    level.pending_submit = false;
    level.selection_pinned = false;
    level.pending_choice = None;
    level.selection_suppressed = false;
    reload(level)
}

/// New generation for the same level; the rows on screen stay until its first batch lands.
fn reload(level: &mut Level) -> Effect {
    level.generation += 1;
    level.is_loading = true;
    load(level)
}

fn load(level: &Level) -> Effect {
    Effect::Load {
        level_id: level.id,
        scope: level.scope.clone(),
        query: level.query.clone(),
        generation: level.generation,
        context: level.context(),
    }
}

fn selected_row(level: &Level) -> Option<&Row> {
    let selection = level.selection.as_ref()?;
    level.rows.iter().find(|row| &row.id == selection)
}

fn unique(rows: Vec<Row>) -> Vec<Row> {
    let mut seen = HashSet::new();
    rows.into_iter().filter(|row| seen.insert(row.id.clone())).collect()
}

/// A reducer and the state it owns, as the app holds them behind one C handle. Each step answers
/// the effects and a snapshot of the state whose levels carry `rows` only when they changed since
/// the last snapshot, so a keystroke does not copy hundreds of unchanged rows back to the host.
#[derive(Debug, Default)]
pub struct Nav {
    pub reducer: Reducer,
    pub state: State,
    sent_rows: HashMap<i64, u64>,
}

/// One level as a snapshot carries it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LevelSnapshot<'a> {
    #[serde(flatten)]
    pub level: LevelFields<'a>,
    /// The level's rows, present only when they changed since the last snapshot (or `full`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rows: Option<&'a [Row]>,
}

/// A level's fields other than its rows.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LevelFields<'a> {
    pub id: i64,
    pub scope: &'a str,
    pub entry: &'a Entry,
    pub query: &'a str,
    pub generation: i64,
    pub rows_generation: i64,
    pub rows_query: Option<&'a str>,
    pub is_loading: bool,
    pub selection: Option<&'a str>,
    pub selection_suppressed: bool,
    pub pending_reset: bool,
    pub pending_submit: bool,
    pub selection_pinned: bool,
    pub pending_choice: Option<&'a str>,
    pub empty_query_selection: Option<i64>,
}

/// The state as a step answers it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StateSnapshot<'a> {
    pub is_open: bool,
    #[serde(rename = "nextLevelID")]
    pub next_level_id: i64,
    pub levels: Vec<LevelSnapshot<'a>>,
}

impl Nav {
    pub fn new(reducer: Reducer) -> Self {
        Nav { reducer, state: State::default(), sent_rows: HashMap::new() }
    }

    /// Applies one event; the effects to perform, in order.
    pub fn send(&mut self, event: Event) -> Vec<Effect> {
        self.reducer.reduce(&mut self.state, event)
    }

    /// The state, with each level's rows only when they changed since the last snapshot (every
    /// level's rows when `full`).
    pub fn snapshot(&mut self, full: bool) -> StateSnapshot<'_> {
        let live: HashSet<i64> = self.state.levels.iter().map(|level| level.id).collect();
        self.sent_rows.retain(|id, _| live.contains(id));
        let mut levels = Vec::with_capacity(self.state.levels.len());
        for level in &self.state.levels {
            let sent = self.sent_rows.insert(level.id, level.rows_revision);
            let changed = full || sent != Some(level.rows_revision);
            levels.push(LevelSnapshot {
                level: LevelFields {
                    id: level.id,
                    scope: &level.scope,
                    entry: &level.entry,
                    query: &level.query,
                    generation: level.generation,
                    rows_generation: level.rows_generation,
                    rows_query: level.rows_query.as_deref(),
                    is_loading: level.is_loading,
                    selection: level.selection.as_deref(),
                    selection_suppressed: level.selection_suppressed,
                    pending_reset: level.pending_reset,
                    pending_submit: level.pending_submit,
                    selection_pinned: level.selection_pinned,
                    pending_choice: level.pending_choice.as_deref(),
                    empty_query_selection: level.empty_query_selection,
                },
                rows: changed.then_some(level.rows.as_slice()),
            });
        }
        StateSnapshot {
            is_open: self.state.is_open,
            next_level_id: self.state.next_level_id,
            levels,
        }
    }
}

/// One request to a [`Nav`] handle (`cmux_palette_nav_call`).
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Request {
    /// Registers a scope graph and answers it (registered scopes in order and the problems).
    /// Without `install` the handle's reducer keeps its graph (a graph built only to read it).
    Graph {
        root: Box<Descriptor>,
        #[serde(default)]
        scopes: Vec<Descriptor>,
        /// The user's prefix assignments, applied first (`graph::apply_assigned_prefixes`).
        #[serde(default)]
        assigned: HashMap<String, Option<String>>,
        #[serde(default)]
        install: bool,
    },
    /// Sets the entry config; answers it normalized.
    Config { config: Config },
    /// Applies events in order; answers every effect and the state after the last one.
    Reduce {
        events: Vec<Event>,
        #[serde(default)]
        full: bool,
    },
    /// Answers the state (every level's rows when `full`).
    State {
        #[serde(default)]
        full: bool,
    },
    /// Answers Search Tabs rows (`crate::tab_search`); the handle's state is untouched.
    TabSearchRows(crate::tab_search::Request),
}

#[derive(Serialize)]
struct ReduceResponse<'a> {
    effects: Vec<Effect>,
    state: StateSnapshot<'a>,
}

impl Nav {
    /// Answers one JSON request; an error is a message.
    pub fn call(&mut self, request: &[u8]) -> Result<Vec<u8>, String> {
        let request: Request =
            serde_json::from_slice(request).map_err(|error| error.to_string())?;
        let bytes = match request {
            Request::Graph { root, scopes, assigned, install } => {
                let graph = Graph::new(*root, graph::apply_assigned_prefixes(&assigned, scopes));
                let bytes = serde_json::to_vec(&graph);
                if install {
                    self.reducer.graph = graph;
                }
                bytes
            }
            Request::Config { config } => {
                self.reducer.config = config.normalized();
                serde_json::to_vec(&self.reducer.config)
            }
            Request::Reduce { events, full } => {
                let mut effects = Vec::new();
                for event in events {
                    effects.extend(self.send(event));
                }
                serde_json::to_vec(&ReduceResponse { effects, state: self.snapshot(full) })
            }
            Request::State { full } => serde_json::to_vec(&self.snapshot(full)),
            Request::TabSearchRows(request) => {
                serde_json::to_vec(&crate::tab_search::answer(&request))
            }
        };
        bytes.map_err(|error| error.to_string())
    }
}
