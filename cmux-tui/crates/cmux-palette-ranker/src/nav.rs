//! The palette's navigation state machine: `(state, event) -> (state', effects)`, pure, with the
//! scope graph ([`crate::scope_graph`]) as its environment. The state is a stack of scope levels,
//! each with its own query, rows and selection. plans/cmux-next/palette-scopes.md section 4.3.
//!
//! Moved from Swift (`PaletteNavReducer`); the state, event and effect JSON are the Swift types'
//! synthesized `Codable` forms (an enum case is `{"case": {"_0": value, "label": value}}`), so the
//! macOS app keeps its value types and sends them as they are.

use crate::scope_graph::{Graph, ROOT, split_first_grapheme};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// Which entry gestures are on (Debug Settings `palette.scopeEntry`) and how deep scopes nest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

/// How a level was entered.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Entry {
    /// Level 0.
    Root {},
    /// Opened directly (shortcut, menu, CLI) above the root.
    Opened {},
    /// A prefix typed into the parent's empty query.
    Prefix {
        #[serde(rename = "_0")]
        prefix: String,
    },
    /// The parent's query was this keyword and the user pressed Tab.
    Keyword {
        #[serde(rename = "_0")]
        keyword: String,
    },
    /// The scope row with this id was chosen (Return, Tab, click).
    Row {
        #[serde(rename = "_0")]
        row: String,
    },
    /// Tab on the parent's row with this id (its actions, its tabs).
    Drill {
        #[serde(rename = "_0")]
        row: String,
    },
    /// A command of the parent's row with this id (none: no row) pushed a page of its own.
    Command {
        #[serde(rename = "_0", default, skip_serializing_if = "Option::is_none")]
        row: Option<String>,
    },
}

impl Entry {
    /// Entered inside this palette session (Escape pops it).
    pub fn is_pushed(&self) -> bool {
        !matches!(self, Entry::Root {} | Entry::Opened {})
    }
}

/// What navigation needs from a result row. Titles and commands stay with the host.
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
    pub is_enabled: bool,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows_query: Option<String>,
    /// A batch of `generation` is still expected.
    pub is_loading: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<String>,
    /// Preserve intentional no-selection across refresh and provider batches.
    pub selection_suppressed: bool,
    /// The query changed: the next accepted batch selects the default row.
    pub pending_reset: bool,
    /// Return arrived while `rows` were stale: run once fresh rows land.
    pub pending_submit: bool,
    /// The user chose `selection` after the last query change.
    pub selection_pinned: bool,
    /// The chosen row a waiting Return runs when a later batch of this query brings it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_choice: Option<String>,
    /// The empty-query row index the last batch asked for, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub empty_query_selection: Option<i64>,
}

impl Level {
    fn new(id: i64, scope: String, entry: Entry, query: String) -> Level {
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
        }
    }

    /// The rows on screen belong to the current query.
    pub fn rows_are_current(&self) -> bool {
        self.rows_generation == self.generation
    }

    /// The drill or scope row this level was entered from.
    pub fn context(&self) -> Option<String> {
        match &self.entry {
            Entry::Drill { row } | Entry::Row { row } => Some(row.clone()),
            Entry::Command { row } => row.clone(),
            _ => None,
        }
    }

    fn selected_row(&self) -> Option<&Row> {
        let selection = self.selection.as_ref()?;
        self.rows.iter().find(|r| &r.id == selection)
    }

    fn has_row(&self, id: &str) -> bool {
        self.rows.iter().any(|r| r.id == id)
    }
}

/// The navigation state: changed only by [`reduce`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub is_open: bool,
    /// Level 0 is the root scope while open; empty while closed.
    pub levels: Vec<Level>,
    /// Next level id: unique for the life of the state, so a batch for a popped level can never
    /// land on a new level.
    #[serde(rename = "nextLevelID")]
    pub next_level_id: i64,
}

impl Default for State {
    fn default() -> Self {
        State { is_open: false, levels: Vec::new(), next_level_id: 1 }
    }
}

/// Inputs to the reducer: keys, field edits and source batches.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Event {
    /// Open on the root, or on `scope` above the root, with `query` typed.
    Open {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        scope: Option<String>,
        query: String,
    },
    /// The palette closed from outside.
    Close {},
    /// The field's text changed.
    SetQuery {
        #[serde(rename = "_0")]
        text: String,
        #[serde(rename = "allowsScopeEntry", default = "yes")]
        allows_scope_entry: bool,
    },
    /// Backspace with an empty field.
    BackspaceOnEmpty {},
    Tab {},
    ShiftTab {},
    Escape {},
    /// A click on the chip of level `index`: pop every level above it.
    PopTo {
        #[serde(rename = "_0")]
        index: i64,
    },
    /// Return, or a click on row `row` (none: the selection).
    Activate {
        #[serde(rename = "_0", default, skip_serializing_if = "Option::is_none")]
        row: Option<String>,
    },
    /// A command pushed its own page `scope`, from row `row` of the top level, with `query`.
    Push {
        #[serde(rename = "_0")]
        scope: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        row: Option<String>,
        query: String,
    },
    /// Arrow keys; wraps.
    Move {
        #[serde(rename = "_0")]
        delta: i64,
    },
    Select {
        #[serde(rename = "_0")]
        row: String,
    },
    /// Clear an intentionally exhausted section selection.
    ClearSelection {},
    /// A batch from the source of `level_id` for `generation`.
    Results {
        #[serde(rename = "levelID")]
        level_id: i64,
        generation: i64,
        rows: Vec<Row>,
        replace: bool,
        #[serde(rename = "isFinal")]
        is_final: bool,
        #[serde(rename = "emptyQuerySelection", default, skip_serializing_if = "Option::is_none")]
        empty_query_selection: Option<i64>,
        #[serde(default)]
        provisional: bool,
    },
    /// The owner of the top level's data changed: reload, keep selection.
    Refresh {},
    /// The top level shows another page in its place: rows and selection start over.
    Restart {
        query: String,
    },
}

fn yes() -> bool {
    true
}

/// Why a push was refused.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Refusal {
    DepthLimit {},
}

/// Work for the host after a reducer step.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Effect {
    /// Ask the scope's source for `query`; tag batches with `generation`.
    Load {
        #[serde(rename = "levelID")]
        level_id: i64,
        scope: String,
        query: String,
        generation: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
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
    Dismiss {},
    /// Accessibility announcement: the scope now on top.
    AnnounceEntered {
        #[serde(rename = "_0")]
        scope: String,
    },
    AnnounceLeft {
        to: String,
    },
    Refused {
        #[serde(rename = "_0")]
        refusal: Refusal,
    },
}

/// One `nav_reduce` request: the graph and config are the environment.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReduceRequest {
    pub graph: Graph,
    #[serde(default)]
    pub config: Config,
    #[serde(default)]
    pub state: State,
    pub event: Event,
}

/// The state after the event and the effects to perform, in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ReduceReply {
    pub state: State,
    pub effects: Vec<Effect>,
}

/// Answers one `nav_reduce` request.
pub fn answer(request: ReduceRequest) -> ReduceReply {
    let reducer = Reducer { graph: &request.graph, config: &request.config };
    let mut state = request.state;
    let effects = reducer.reduce(&mut state, request.event);
    ReduceReply { state, effects }
}

/// The reducer: the graph and config it reads.
pub struct Reducer<'a> {
    pub graph: &'a Graph,
    pub config: &'a Config,
}

impl Reducer<'_> {
    fn max_depth(&self) -> usize {
        self.config.max_depth.max(2) as usize
    }

    /// Applies `event` to `state` and returns the effects to perform, in order.
    pub fn reduce(&self, state: &mut State, event: Event) -> Vec<Effect> {
        match event {
            Event::Open { scope, query } => return self.open(state, scope, query),
            Event::Close {} => return self.close(state),
            _ => {}
        }
        if !state.is_open || state.levels.is_empty() {
            return Vec::new();
        }
        let top = state.levels.len() - 1;
        match event {
            Event::Open { .. } | Event::Close {} => Vec::new(),
            Event::SetQuery { text, allows_scope_entry } => {
                self.set_query(state, text, allows_scope_entry)
            }
            Event::BackspaceOnEmpty {} => {
                if !state.levels[top].query.is_empty() {
                    return Vec::new();
                }
                self.pop(state, top as i64 - 1)
            }
            Event::Tab {} => self.tab(state),
            Event::ShiftTab {} => self.pop(state, top as i64 - 1),
            Event::Escape {} => self.escape(state),
            Event::PopTo { index } => self.pop(state, index),
            Event::Activate { row } => self.activate(state, row),
            Event::Push { scope, row, query } => {
                self.push(state, scope, Entry::Command { row }, query, true)
            }
            Event::Move { delta } => {
                Self::move_by(&mut state.levels[top], delta);
                Vec::new()
            }
            Event::Select { row } => {
                let level = &mut state.levels[top];
                if level.has_row(&row) {
                    level.selection = Some(row);
                    Self::pin(level);
                }
                Vec::new()
            }
            Event::ClearSelection {} => {
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
            Event::Refresh {} => vec![Self::reload(&mut state.levels[top])],
            Event::Restart { query } => {
                let level = &mut state.levels[top];
                level.rows.clear();
                vec![Self::edit(level, query)]
            }
        }
    }

    // Open and close

    fn open(&self, state: &mut State, scope: Option<String>, query: String) -> Vec<Effect> {
        let mut effects = self.close(state);
        state.is_open = true;
        let target = scope.filter(|s| s != ROOT);
        let root_query = if target.is_none() { query.clone() } else { String::new() };
        effects.extend(self.push(state, ROOT.into(), Entry::Root {}, root_query, false));
        if let Some(target) = target {
            effects.extend(self.push(state, target, Entry::Opened {}, query, true));
        }
        effects
    }

    fn close(&self, state: &mut State) -> Vec<Effect> {
        let effects =
            state.levels.iter().rev().map(|l| Effect::Cancel { level_id: l.id }).collect();
        state.levels.clear();
        state.is_open = false;
        effects
    }

    // Stack

    fn push(
        &self,
        state: &mut State,
        scope: String,
        entry: Entry,
        query: String,
        announce: bool,
    ) -> Vec<Effect> {
        if state.levels.len() >= self.max_depth() {
            return vec![Effect::Refused { refusal: Refusal::DepthLimit {} }];
        }
        // Left from its selected row: popping back keeps that row, even if the level showed
        // provisional rows (a consumed keyword already reset the level on purpose).
        if !matches!(entry, Entry::Keyword { .. }) {
            if let Some(top) = state.levels.last_mut() {
                top.pending_reset = false;
            }
        }
        let level = Level::new(state.next_level_id, scope.clone(), entry, query);
        state.next_level_id += 1;
        let mut effects = vec![Self::load(&level)];
        state.levels.push(level);
        if announce {
            effects.push(Effect::AnnounceEntered { scope });
        }
        effects
    }

    /// Pops every level above `index` (at least the root stays). The new top shows its cached
    /// rows, keeps its selection and reloads.
    fn pop(&self, state: &mut State, index: i64) -> Vec<Effect> {
        let keep = index.max(0) as usize + 1;
        if keep >= state.levels.len() {
            return Vec::new();
        }
        let mut effects = Vec::new();
        while state.levels.len() > keep {
            let level = state.levels.pop().expect("more levels than kept");
            effects.push(Effect::Cancel { level_id: level.id });
        }
        let top = state.levels.last_mut().expect("the root stays");
        top.pending_submit = false;
        // Returning from a page is explicit navigation: resume normal fallback selection even if
        // the parent had intentionally exhausted a section.
        top.selection_suppressed = false;
        effects.push(Self::reload(top));
        effects.push(Effect::AnnounceLeft { to: top.scope.clone() });
        effects
    }

    // Keys

    fn set_query(&self, state: &mut State, text: String, allows_scope_entry: bool) -> Vec<Effect> {
        let top = state.levels.len() - 1;
        let level = &state.levels[top];
        if level.query == text {
            return Vec::new();
        }
        if allows_scope_entry && self.config.prefix_entry && level.query.is_empty() {
            if let Some((first, rest)) = split_first_grapheme(&text) {
                if let Some(child) = self.graph.child_by_prefix(&level.scope, first) {
                    if state.levels.len() < self.max_depth() {
                        let (scope, prefix, rest) =
                            (child.id.clone(), first.to_string(), rest.to_string());
                        return self.push(state, scope, Entry::Prefix { prefix }, rest, true);
                    }
                }
            }
        }
        vec![Self::edit(&mut state.levels[top], text)]
    }

    fn tab(&self, state: &mut State) -> Vec<Effect> {
        let top = state.levels.len() - 1;
        let level = &state.levels[top];
        if self.config.keyword_entry && state.levels.len() < self.max_depth() {
            if let Some(child) = self.graph.child_by_keyword(&level.scope, &level.query) {
                let keyword = crate::scope_graph::normalize_keyword(&level.query);
                let child = child.id.clone();
                // The keyword is consumed: the parent comes back with an empty query (reloaded
                // when the child pops).
                let level = &mut state.levels[top];
                level.query.clear();
                level.generation += 1;
                level.pending_reset = true;
                level.pending_submit = false;
                level.selection_pinned = false;
                level.pending_choice = None;
                level.is_loading = true;
                return self.push(state, child, Entry::Keyword { keyword }, String::new(), true);
            }
        }
        let Some(row) = level.selected_row().cloned() else { return Vec::new() };
        if let Some(target) = row.enters.filter(|t| self.graph.contains(t)) {
            return self.push(state, target, Entry::Row { row: row.id }, String::new(), true);
        }
        if let Some(target) = row.drills.filter(|t| self.graph.contains(t)) {
            return self.push(state, target, Entry::Drill { row: row.id }, String::new(), true);
        }
        if row.is_enabled { vec![Effect::OpenActions { row_id: row.id }] } else { Vec::new() }
    }

    fn escape(&self, state: &mut State) -> Vec<Effect> {
        let top = state.levels.len() - 1;
        if state.levels[top].entry.is_pushed() {
            return self.pop(state, top as i64 - 1);
        }
        if !state.levels[top].query.is_empty() {
            return vec![Self::edit(&mut state.levels[top], String::new())];
        }
        let mut effects = self.close(state);
        effects.push(Effect::Dismiss {});
        effects
    }

    fn activate(&self, state: &mut State, row_id: Option<String>) -> Vec<Effect> {
        let top = state.levels.len() - 1;
        let level = &mut state.levels[top];
        if row_id.is_none() && level.selection_suppressed {
            return Vec::new();
        }
        if let Some(row_id) = row_id {
            if !level.has_row(&row_id) {
                return Vec::new();
            }
            level.selection = Some(row_id);
            level.selection_suppressed = false;
            Self::pin(level);
        } else if !level.rows_are_current()
            && level.rows_query.as_deref() != Some(level.query.as_str())
        {
            // The rows on screen belong to an older query text (a refresh of the same text runs
            // the highlighted row at once).
            level.pending_submit = true;
            return Vec::new();
        } else if level.pending_reset && level.rows_are_current() {
            // Provisional rows (the empty query's stand-in): Return runs the ranked batch's default
            // row when it lands, unless the user chose a row (that clears the pending reset).
            level.pending_submit = true;
            return Vec::new();
        }
        let level_id = level.id;
        let Some(row) = level.selected_row().cloned() else { return Vec::new() };
        if let Some(target) = row.enters.filter(|t| self.graph.contains(t)) {
            return self.push(state, target, Entry::Row { row: row.id }, String::new(), true);
        }
        if row.is_enabled { vec![Effect::Run { level_id, row_id: row.id }] } else { Vec::new() }
    }

    fn move_by(level: &mut Level, delta: i64) {
        level.selection_suppressed = false;
        if level.rows.is_empty() {
            return;
        }
        let count = level.rows.len() as i64;
        let current = level
            .selection
            .as_ref()
            .and_then(|s| level.rows.iter().position(|r| &r.id == s))
            .map_or(-1, |i| i as i64);
        let next = current.wrapping_add(delta).rem_euclid(count) as usize;
        level.selection = Some(level.rows[next].id.clone());
        Self::pin(level);
    }

    /// The user chose the selection: fresh rows of the current query keep it.
    fn pin(level: &mut Level) {
        level.selection_suppressed = false;
        level.pending_reset = false;
        level.selection_pinned = true;
        level.pending_choice = None;
    }

    // Results

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
        let Some(index) = state.levels.iter().position(|l| l.id == level_id) else {
            return Vec::new();
        };
        if state.levels[index].generation != generation {
            return Vec::new();
        }
        let is_top = index == state.levels.len() - 1;
        let level = &mut state.levels[index];
        if let Some(selection) = empty_query_selection {
            level.empty_query_selection = Some(selection.max(0));
        }
        let previous_index =
            level.selection.as_ref().and_then(|s| level.rows.iter().position(|r| &r.id == s));
        if replace || level.rows_generation != generation {
            level.rows = unique(rows);
        } else {
            let mut joined = std::mem::take(&mut level.rows);
            joined.extend(rows);
            level.rows = unique(joined);
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
        if let Some(choice) = level.pending_choice.clone() {
            if level.has_row(&choice) {
                level.selection = Some(choice);
                level.pending_choice = None;
            }
        }
        let shown = level.selection.as_ref().is_some_and(|s| level.has_row(s));
        let default_selection = self.default_selection(level);
        let fallback = |level: &Level| -> Option<String> {
            if level.rows.is_empty() {
                return None;
            }
            match previous_index {
                Some(i) => Some(level.rows[i.min(level.rows.len() - 1)].id.clone()),
                None => default_selection.clone(),
            }
        };
        if level.pending_reset {
            level.selection = default_selection.clone();
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
            // Return waits for the chosen row: a later batch of this query may hold it. Meanwhile
            // the selection shows a row on screen.
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
        let index = (preferred.max(0) as usize).min(level.rows.len() - 1);
        Some(level.rows[index].id.clone())
    }

    // Helpers

    fn edit(level: &mut Level, text: String) -> Effect {
        level.query = text;
        level.pending_reset = true;
        level.pending_submit = false;
        level.selection_pinned = false;
        level.pending_choice = None;
        level.selection_suppressed = false;
        Self::reload(level)
    }

    /// New generation for the same level; the rows on screen stay until its first batch lands.
    fn reload(level: &mut Level) -> Effect {
        level.generation += 1;
        level.is_loading = true;
        Self::load(level)
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
}

/// Rows with each id once, first occurrence kept.
fn unique(rows: Vec<Row>) -> Vec<Row> {
    let mut seen = HashSet::new();
    rows.into_iter().filter(|r| seen.insert(r.id.clone())).collect()
}

#[cfg(test)]
#[path = "nav_tests.rs"]
mod tests;
