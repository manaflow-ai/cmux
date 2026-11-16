//! The place of a new tab in its create request (`tab-create-place-v1`).
//!
//! `new-tab`, `new-conversation-tab` and `new-frontend-browser-tab` take
//! `place`: where the tab goes in the strip of its pane. The client that
//! makes the tab and the daemon then hold the same list, and no move follows
//! the create.
//!
//! A creation takes its slot in the list of its pane when its request
//! arrives ([`Mux::admit_tab_creation`]): a `new-tab` of a connection before
//! its terminal launches, each other request in its handler. The handler
//! checks the request and runs the create inside a scope
//! ([`Mux::place_tab_creation`]). The creation carries the place to its
//! effect as internal fields ([`insert_fields`]), which are stored with the
//! effect's intent. The attach of the tab reads them ([`Placed::of`]) and
//! asks the list for the index and for the active tab ([`Placed::land`]),
//! inside the state lock that inserts the tab.

use std::cell::Cell;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::StripRequest;
use super::place_list::{Asked, PlaceLists};
use crate::Actor;
use crate::Mux;
use crate::PaneId;
use crate::SurfaceId;
use crate::model::State;
use crate::workspace_registry::PresentationSnapshot;

/// Advertised by `identify` once the three create commands take `place`.
pub(crate) const CAPABILITY: &str = "tab-create-place-v1";

/// Internal `tab.create_terminal` and `tab.create_browser` field (never
/// accepted from a v2 client; the catalog refuses unknown fields): the
/// checked `place` of the request.
pub(crate) const PLACE_FIELD: &str = "tab_place";

/// Internal field, as [`PLACE_FIELD`]: the `transaction` of a `new-tab` or a
/// `new-frontend-browser-tab`, which the tab's `tab-added` carries. A
/// conversation tab keeps its own field
/// ([`crate::mux::FRONTEND_BROWSER_TRANSACTION_FIELD`]).
pub(crate) const TRANSACTION_FIELD: &str = "tab_transaction";

/// Internal field, as [`PLACE_FIELD`]: what the daemon knew when the request
/// arrived (its connection, the slot of its creation, and the run of the
/// daemon). It is not a part of the request, so a retry of the same request
/// can carry another value: the creation fingerprint leaves it out
/// (`semantic_creation_fields`), and the effect of the creation reads it
/// (`creation_effect_fields`).
pub(crate) const ORIGIN_FIELD: &str = "tab_place_origin";

/// The connection of a creation that no connection of this run asked for.
const NO_CLIENT: u64 = u64::MAX;

/// The id of this run of the daemon. A creation that a later run resumes has
/// the connection and the slot of the run that stored it: they name nothing
/// in the later run.
fn run() -> &'static str {
    static RUN: OnceLock<String> = OnceLock::new();
    RUN.get_or_init(crate::workspace_registry::new_uuid_v4)
}

/// A transaction as a create request names it: 1-128 printable ASCII characters.
fn is_transaction(name: &str) -> bool {
    !name.is_empty() && name.len() <= 128 && name.bytes().all(|byte| byte.is_ascii_graphic())
}

/// `place` of a create request: exactly one of `after`, `after_creation`,
/// `before` and `start`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
pub(crate) struct TabPlaceRequest {
    /// Right after this tab of the pane.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    after: Option<SurfaceId>,
    /// Right after the tab that this creation of the same connection made:
    /// the `transaction` of that create request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    after_creation: Option<String>,
    /// Right before this tab of the pane.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    before: Option<SurfaceId>,
    /// `true`: the first tab after the pinned tabs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    start: Option<bool>,
    /// `true`: the tab joins the tab group of the tab that it names.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    joins: Option<bool>,
}

/// The tab or the strip end that a new tab is put next to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Anchor {
    After(SurfaceId),
    AfterCreation(String),
    Before(SurfaceId),
    Start,
}

/// A checked [`TabPlaceRequest`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TabPlace {
    pub(crate) anchor: Anchor,
    pub(crate) joins: bool,
}

impl TabPlaceRequest {
    /// The place that the request names. A request that names no position,
    /// or more than one, is refused: a daemon that guessed would put the tab
    /// where its client does not show it.
    pub(crate) fn checked(&self) -> anyhow::Result<TabPlace> {
        anyhow::ensure!(
            self.after_creation.as_deref().is_none_or(is_transaction),
            "bad request: place.after_creation must be 1-128 printable ASCII characters"
        );
        let anchor = match (self.after, self.after_creation.as_deref(), self.before, self.start) {
            (Some(tab), None, None, None) => Anchor::After(tab),
            (None, Some(creation), None, None) => Anchor::AfterCreation(creation.to_string()),
            (None, None, Some(tab), None) => Anchor::Before(tab),
            (None, None, None, Some(true)) => Anchor::Start,
            _ => anyhow::bail!(
                "bad request: place names exactly one of after, after_creation, before and start: true"
            ),
        };
        let joins = self.joins.unwrap_or(false);
        anyhow::ensure!(
            !(joins && anchor == Anchor::Start),
            "bad request: place.joins needs the tab that after, after_creation or before names"
        );
        Ok(TabPlace { anchor, joins })
    }
}

/// What the handler of a create request gives to the creation of its tab.
#[derive(Clone, Debug, Default)]
pub(crate) struct Scope {
    /// The connection of the request.
    pub(crate) client: u64,
    /// The checked `place` of the request.
    pub(crate) place: Option<TabPlaceRequest>,
    /// The `transaction` of a `new-tab` or a `new-frontend-browser-tab`.
    pub(crate) transaction: Option<String>,
    /// The slot of the creation in the list of its pane.
    pub(crate) hole: Option<u64>,
}

thread_local! {
    static SCOPED: Cell<Option<Scope>> = const { Cell::new(None) };
}

/// Restores the scope that was set before [`enter`], when it drops.
#[must_use = "the scope ends when this value drops"]
pub(crate) struct Entered(Option<Scope>);

impl Drop for Entered {
    fn drop(&mut self) {
        SCOPED.with(|slot| slot.set(self.0.take()));
    }
}

/// The next tab creation of this thread takes `scope`, until the returned
/// value drops.
pub(crate) fn enter(scope: Scope) -> Entered {
    Entered(SCOPED.with(|slot| slot.replace(Some(scope))))
}

/// Put the scope of a creation into its effect `fields`, once: a second
/// creation in the same scope has no place. A creation with no `place` and
/// no transaction gets no field, so its stored intent is as before.
pub(crate) fn insert_fields(fields: &mut Map<String, Value>) {
    let Some(scope) = SCOPED.with(Cell::take) else { return };
    if let Some(place) = scope.place.as_ref().and_then(|place| serde_json::to_value(place).ok()) {
        fields.insert(PLACE_FIELD.to_string(), place);
    }
    if let Some(transaction) = scope.transaction {
        fields.insert(TRANSACTION_FIELD.to_string(), Value::String(transaction));
    }
    let named = fields.contains_key(TRANSACTION_FIELD)
        || fields.contains_key(crate::mux::FRONTEND_BROWSER_TRANSACTION_FIELD);
    if named || fields.contains_key(PLACE_FIELD) {
        let origin =
            serde_json::json!({ "client": scope.client, "hole": scope.hole, "run": run() });
        fields.insert(ORIGIN_FIELD.to_string(), origin);
    }
}

/// The place facts of a tab creation's effect fields.
#[derive(Clone, Debug, Default)]
pub(crate) struct Placed {
    pub(crate) place: Option<TabPlace>,
    /// The transaction that the tab's `tab-added` carries.
    pub(crate) transaction: Option<Arc<str>>,
    /// The connection of the request.
    pub(crate) client: Option<u64>,
    /// The slot of the creation in the list of its pane.
    pub(crate) hole: Option<u64>,
}

/// Where the attach of a new tab puts it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Landing {
    /// The index of the pane's strip that the tab takes at its attach.
    pub(crate) index: usize,
    /// The tab group that the tab then joins, and its index among the
    /// members ([`Mux::join_new_tab`]).
    pub(crate) joins: Option<(String, usize)>,
    /// The tab takes the active tab of the pane.
    pub(crate) active: bool,
}

impl Placed {
    pub(crate) fn of(fields: &Map<String, Value>) -> Self {
        let place = fields
            .get(PLACE_FIELD)
            .and_then(|place| serde_json::from_value::<TabPlaceRequest>(place.clone()).ok())
            .and_then(|place| place.checked().ok());
        let transaction = [TRANSACTION_FIELD, crate::mux::FRONTEND_BROWSER_TRANSACTION_FIELD]
            .into_iter()
            .find_map(|field| fields.get(field).and_then(Value::as_str))
            .map(Arc::from);
        let origin = fields
            .get(ORIGIN_FIELD)
            .filter(|origin| origin.get("run").and_then(Value::as_str) == Some(run()));
        let number =
            |name: &str| origin.and_then(|origin| origin.get(name)).and_then(Value::as_u64);
        Self { place, transaction, client: number("client"), hole: number("hole") }
    }

    /// The slot of `tab`, a new tab of `pane` whose creation has a `place`
    /// or took a slot when its request arrived (a `transaction` with no
    /// `place`: the slot at the end of the strip of that time). None for
    /// each other creation, which keeps the slot of its kind. With
    /// `activate` the tab asks for the active tab of the pane. The caller
    /// holds the state lock and inserts the tab at the index in the same
    /// lock.
    pub(crate) fn land(
        &self,
        state: &State,
        presentation: &PresentationSnapshot,
        pane: PaneId,
        tab: SurfaceId,
        activate: bool,
    ) -> Option<Landing> {
        if self.place.is_none() && self.hole.is_none() {
            return None;
        }
        let (slots, groups) = strip_slots(state, presentation, pane);
        let asked = Asked {
            client: self.client.unwrap_or(NO_CLIENT),
            transaction: self.transaction.as_deref(),
            place: self.place.as_ref(),
            activate,
        };
        let (settled, active) =
            state.tab_places.lock().commit(pane, &slots, &groups, self.hole, asked, tab);
        let run = settled.joined.and_then(|run| {
            let start = slots.iter().position(|slot| slot.group == Some(run))?;
            let members = slots.iter().filter(|slot| slot.group == Some(run)).count();
            Some((groups.get(run)?.clone(), start, members))
        });
        Some(match run {
            // The tab attaches after the run with no group, as a browser tab
            // put after a grouped tab does, and then joins in its slot.
            Some((group, start, members)) => Landing {
                index: start.saturating_add(members),
                joins: Some((group, settled.index.saturating_sub(start).min(members))),
                active,
            },
            None => Landing { index: settled.index.min(slots.len()), joins: None, active },
        })
    }

    /// A new tab of `pane` that [`Placed::land`] gave no slot; `asks` says if
    /// it asks for the active tab of the pane. A creation with a slot gets
    /// the answer of the list; each other creation gets the active tab when
    /// it asks, as before `place`. The caller holds the state lock.
    pub(crate) fn takes_active(&self, state: &State, pane: PaneId, asks: bool) -> bool {
        let Some(number) = self.hole else { return asks };
        let open =
            |tab: SurfaceId| state.panes.get(&pane).is_some_and(|pane| pane.tabs.contains(&tab));
        state.tab_places.lock().takes_active(pane, number, asks, open)
    }
}

/// The index of a terminal tab's creation ([`super::tab_slot`]) and its
/// place: what the attach of a new terminal tab reads of its effect fields.
#[derive(Clone, Debug, Default)]
pub(crate) struct Spot {
    pub(crate) index: Option<usize>,
    pub(crate) placed: Placed,
}

impl Spot {
    pub(crate) fn of(fields: &Map<String, Value>) -> Self {
        Self { index: super::tab_slot::effect_index(fields), placed: Placed::of(fields) }
    }
}

/// The lists of one daemon. Each copy of the session state has the same
/// lists: a creation takes its slot outside the commit of a strip change,
/// which works on a copy of the state.
#[derive(Clone, Default)]
pub(crate) struct SharedPlaceLists(Arc<Mutex<PlaceLists>>);

impl SharedPlaceLists {
    /// The lists. A caller that needs the state lock also takes it first.
    pub(crate) fn lock(&self) -> MutexGuard<'_, PlaceLists> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// A create request as the place rules read it.
#[derive(Clone, Copy, Debug)]
pub(crate) struct CreateRequest<'a> {
    /// The connection of the request.
    pub(crate) client: u64,
    /// The pane that the request names.
    pub(crate) pane: Option<PaneId>,
    pub(crate) place: Option<&'a TabPlaceRequest>,
    /// The `transaction` of the request: the name of its creation.
    pub(crate) transaction: Option<&'a str>,
}

/// The creation of one create request in its handler. When it drops, a
/// creation that made no tab leaves its slot.
#[must_use = "the creation ends when this value drops"]
pub(crate) struct Placing<'a> {
    mux: &'a Mux,
    hole: Option<u64>,
    _entered: Entered,
}

impl Placing<'_> {
    /// The create gave `tab`. A creation whose attach did not take its slot
    /// (a replayed create, a tab with no `place`) names that tab from now on.
    pub(crate) fn made(&self, tab: SurfaceId) {
        self.mux.end_tab_creation(self.hole, Some(tab));
    }
}

impl Drop for Placing<'_> {
    fn drop(&mut self) {
        self.mux.end_tab_creation(self.hole, None);
    }
}

impl Mux {
    /// `request` arrived: its creation takes its slot in the list of its
    /// pane, and the number of the slot is returned. No slot: the request
    /// has no `place` and no `transaction`, names no pane of the session, or
    /// has a `place` that its handler refuses.
    pub(crate) fn admit_tab_creation(&self, request: CreateRequest<'_>) -> Option<u64> {
        let pane = request.pane?;
        let place = request.place.map(TabPlaceRequest::checked).transpose().ok()?;
        if place.is_none() && request.transaction.is_none() {
            return None;
        }
        let presentation = self.presentation_snapshot();
        let asked = Asked {
            client: request.client,
            transaction: request.transaction,
            place: place.as_ref(),
            activate: true,
        };
        self.with_state(|state| {
            if !state.panes.contains_key(&pane) {
                return None;
            }
            let (slots, groups) = strip_slots(state, &presentation, pane);
            Some(state.tab_places.lock().admit(pane, &slots, &groups, asked))
        })
    }

    /// The handler of `request` starts its creation: `place` is checked, the
    /// creation takes its slot if it has none (`hole`), and the next tab
    /// creation of this thread carries the place until the returned value
    /// drops. `carried`: the creation's `tab-added` gets the transaction
    /// from the field of this file (a conversation tab has its own field).
    pub(crate) fn place_tab_creation(
        &self,
        request: CreateRequest<'_>,
        hole: Option<u64>,
        carried: bool,
    ) -> anyhow::Result<Placing<'_>> {
        if let Some(place) = request.place {
            place.checked()?;
            anyhow::ensure!(
                request.pane.is_some(),
                "bad request: place needs pane (the pane of the strip that it names)"
            );
        }
        // A carried `transaction` names a creation in the strip of `pane`.
        // With no `pane` the creation takes no slot, and on the paths of a
        // workspace its `tab-added` does not carry the transaction.
        anyhow::ensure!(
            !carried || request.transaction.is_none() || request.pane.is_some(),
            "bad request: transaction needs pane (the pane of the new tab)"
        );
        let hole = hole.or_else(|| self.admit_tab_creation(request));
        let scope = Scope {
            client: request.client,
            place: request.place.cloned(),
            transaction: request.transaction.filter(|_| carried).map(str::to_string),
            hole,
        };
        Ok(Placing { mux: self, hole, _entered: enter(scope) })
    }

    /// The creation with the slot `hole` ended: with `tab` it names that tab
    /// from now on, with none it made no tab. Nothing for a creation that
    /// has its tab already.
    pub(crate) fn end_tab_creation(&self, hole: Option<u64>, tab: Option<SurfaceId>) {
        let Some(hole) = hole else { return };
        // A drop calls this, also while a panic unwinds: a poisoned state
        // lock gives its value, not a second panic.
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.tab_places.lock().end(hole, tab);
    }

    /// The connection `client` closed: no later request names its creations.
    pub(crate) fn forget_tab_creations(&self, client: u64) {
        self.with_state(|state| state.tab_places.lock().forget_client(client));
    }

    /// `added`, a tab that attached right after the run of a tab group,
    /// joins the group at its index among the members ([`Landing::joins`]).
    /// A refused join leaves the tab after the run with no group.
    pub(crate) fn join_new_tab(self: &Arc<Self>, added: SurfaceId, joins: Option<(String, usize)>) {
        let Some((group, index)) = joins else { return };
        let request = StripRequest::local(&Actor::Daemon, "tab.group.add");
        match self.tab_group_add(request, &group, move |_| Ok(vec![added]), Some(index)) {
            Ok(_) => self.emit_tab_group_members(&[added], None),
            Err(error) => eprintln!("cmux-tui: tab {added} did not join {group}: {error:#}"),
        }
    }
}

/// One entry of a pane's strip as the place rules see it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Slot {
    /// The tab of the entry.
    pub(crate) tab: Option<SurfaceId>,
    /// A pinned tab: no placed tab goes before it.
    pub(crate) pinned: bool,
    /// The tab group run of the entry: entries with one number are one run.
    pub(crate) group: Option<usize>,
}

/// The side of a strip entry, or the strip end, that a new tab takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Wanted {
    /// Right after the entry at this index.
    After(usize),
    /// Right before the entry at this index.
    Before(usize),
    Start,
    End,
}

/// The index of `slots` that a new tab takes, and the run that it joins.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Settled {
    pub(crate) index: usize,
    pub(crate) joined: Option<usize>,
}

/// Where a new tab lands in `slots`.
///
/// It never lands before a pinned tab. A tab that `joins` takes the slot
/// next to its anchor inside the anchor's run. A tab that does not join
/// never splits a run: a slot inside a run moves to the end of the run when
/// the tab is put after its anchor (as the old `after` field of a browser
/// tab did), and to the start of the run when it is put before its anchor.
pub(crate) fn settle(slots: &[Slot], wanted: Wanted, joins: bool) -> Settled {
    let floor = slots.iter().rposition(|slot| slot.pinned).map_or(0, |last| last.saturating_add(1));
    let (raw, anchor, before) = match wanted {
        Wanted::After(anchor) => (anchor.saturating_add(1), Some(anchor), false),
        Wanted::Before(anchor) => (anchor, Some(anchor), true),
        Wanted::Start => (0, None, false),
        Wanted::End => return Settled { index: slots.len(), joined: None },
    };
    let index = raw.clamp(floor, slots.len());
    let group = anchor.and_then(|anchor| slots.get(anchor)).and_then(|slot| slot.group);
    if let Some(group) = group.filter(|_| joins) {
        return Settled { index, joined: Some(group) };
    }
    let (left, right) = slots.split_at(index);
    let around = left
        .iter()
        .filter_map(|slot| slot.group)
        .find(|group| right.iter().any(|slot| slot.group == Some(*group)));
    let in_run = |slot: &Slot| slot.group == around;
    let index = match around {
        None => index,
        Some(_) if before => slots.iter().position(in_run).unwrap_or(index).max(floor),
        Some(_) => slots.iter().rposition(in_run).map_or(index, |last| last.saturating_add(1)),
    };
    Settled { index, joined: None }
}

/// The strip of `pane` as the place rules see it, and the id of the tab
/// group of each run number.
pub(crate) fn strip_slots(
    state: &State,
    presentation: &PresentationSnapshot,
    pane: PaneId,
) -> (Vec<Slot>, Vec<String>) {
    let runs = super::super::pane_tab_groups(state, presentation, pane);
    let tabs = state.panes.get(&pane).map(|pane| pane.tabs.as_slice()).unwrap_or_default();
    let slots = tabs
        .iter()
        .map(|tab| Slot {
            tab: Some(*tab),
            pinned: super::super::tab_groups::is_pinned(state, presentation, *tab),
            group: runs.iter().position(|run| run.members.contains(tab)),
        })
        .collect();
    (slots, runs.into_iter().map(|run| run.group.id).collect())
}
