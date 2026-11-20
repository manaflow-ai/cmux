//! Creation groups (SPLIT BURST, STATUS 6602): the creations that wait for
//! the creation fence at the same time commit as one group.
//!
//! A creation holds the creation fence (`resource_creation_execution`) from
//! its prepare through its projection commit, so a close never sees half a
//! creation and recovery never finds two creations in flight. Four splits
//! sent at once therefore made four projection commits in a row, each a
//! projection build and a journal write behind the fence: the answers came
//! 12-20 ms apart.
//!
//! Now a creation that arrives while another group waits for the fence or
//! runs joins that group, until the group starts its commit. The group's
//! first member (its leader) takes the fence for all members. Each member
//! runs its own prepare and effect on its own thread, one at a time in
//! arrival order, so the choices a caller scopes to its thread (a reopen's
//! identity, a tab slot) stay with it. Then the leader commits every staged
//! member's created view in one projection and one journal write, settles
//! the members whose commit failed, activates their launches, gives each
//! member its answer and releases the fence. A close still waits for the
//! whole group. As Chrome coalesces the input of one frame into one update,
//! a burst of scripted splits becomes one model update; a group never waits
//! for a creation that has not arrived, so a lone creation commits at once.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::{Condvar, Mutex};

use super::*;
use crate::mux::resource_effects::CreatedViewCommit;
use crate::panic_free::RecoverPoison;
use crate::workspace_registry::ResourceCreationRecovery;

/// The most members one group takes. Later creations start the next group,
/// so a steady stream of creations cannot hold the leader's answer back.
const MAX_GROUP_MEMBERS: usize = 8;

/// The creation groups of one mux.
#[derive(Default)]
pub(crate) struct CreationGroups {
    state: Mutex<GroupsState>,
    changed: Condvar,
}

#[derive(Default)]
struct GroupsState {
    next_id: u64,
    /// The group whose leader may take the creation fence next. Leaders
    /// take it in group order, which is the order the groups were started,
    /// so a later group never commits before an earlier one: a connection's
    /// split that cannot join its open group (full) commits after it.
    fence_next: u64,
    /// Groups after `fence_next` whose leader already released its turn.
    fence_done: BTreeSet<u64>,
    /// The group that still takes members: its leader waits for the fence
    /// or holds it, and its commit has not started.
    open: Option<u64>,
    groups: HashMap<u64, Group>,
}

#[derive(Default)]
struct Group {
    members: usize,
    /// The correlation keys and idempotency keys of its members. A request
    /// sent again with the same key must not join: it would find its
    /// original executed but not committed (`Blocked`, an indeterminate
    /// answer). In the next group it gets the original's replay.
    keys: HashSet<String>,
    /// The member whose turn it is; `None` until the leader holds the fence.
    turn: Option<usize>,
    /// Members that left before their turn ended (a panic); turns skip them.
    gone: HashSet<usize>,
    /// The members' staged commits, in turn order.
    staged: Vec<(usize, StagedCreation)>,
    /// The answers the leader gave, by member.
    answers: HashMap<usize, anyhow::Result<ResourcePatchCommit>>,
    /// The leader ended: it gave its answers, or it left without them.
    ended: bool,
    /// Members other than the leader that have not taken their answer.
    waiting: usize,
}

impl Group {
    /// Pass the turn on from `index`, past members that left.
    fn pass_turn(&mut self, index: usize) {
        let mut next = index + 1;
        while self.gone.contains(&next) {
            next += 1;
        }
        self.turn = Some(next);
    }

    fn all_ran(&self) -> bool {
        self.turn.is_some_and(|turn| turn >= self.members)
    }
}

/// A member's prepared and executed creation, ready for the group commit.
pub(super) struct StagedCreation {
    pub(super) idempotency_key: String,
    pub(super) operation_name: String,
    pub(super) fingerprint: Value,
    pub(super) result: Value,
    pub(super) recovery: ResourceCreationRecovery,
}

/// One creation's place in a group.
pub(super) struct GroupSeat<'a> {
    groups: &'a CreationGroups,
    group: u64,
    index: usize,
    turn_ended: bool,
    answered: bool,
    /// The leader released its group's turn at the creation fence.
    fence_turn_released: bool,
}

impl CreationGroups {
    /// Join the open group, or start one. A creation that may not share a
    /// commit (`groupable` false) starts a group that takes no one else; a
    /// creation whose `keys` a member of the open group holds starts the
    /// next group, which waits for the open one's commit.
    pub(super) fn join(&self, groupable: bool, keys: &[&str]) -> GroupSeat<'_> {
        let mut state = self.state.lock().recover_poison();
        let open_id = state.open.filter(|_| groupable);
        let open = open_id
            .and_then(|id| state.groups.get_mut(&id).map(|group| (id, group)))
            .filter(|(_, group)| {
                group.members < MAX_GROUP_MEMBERS
                    && keys.iter().all(|key| !group.keys.contains(*key))
            });
        let keys = keys.iter().map(|key| (*key).to_owned());
        let (group, index) = match open {
            Some((id, group)) => {
                group.members += 1;
                group.waiting += 1;
                group.keys.extend(keys);
                (id, group.members - 1)
            }
            None => {
                let id = state.next_id;
                state.next_id += 1;
                let group = Group { members: 1, keys: keys.collect(), ..Group::default() };
                state.groups.insert(id, group);
                if groupable {
                    state.open = Some(id);
                }
                (id, 0)
            }
        };
        GroupSeat {
            groups: self,
            group,
            index,
            turn_ended: false,
            answered: false,
            fence_turn_released: false,
        }
    }

    fn with_state<R>(&self, body: impl FnOnce(&mut GroupsState) -> R) -> R {
        let mut state = self.state.lock().recover_poison();
        let value = body(&mut state);
        drop(state);
        self.changed.notify_all();
        value
    }
}

impl GroupSeat<'_> {
    pub(super) fn is_leader(&self) -> bool {
        self.index == 0
    }

    /// The leader: wait until every earlier group released the creation
    /// fence's turn.
    pub(super) fn wait_fence_turn(&self) {
        debug_assert!(self.is_leader());
        let mut state = self.groups.state.lock().recover_poison();
        while state.fence_next != self.group {
            state = self.groups.changed.wait(state).recover_poison();
        }
    }

    /// The leader: its group is done with the creation fence; the next
    /// group's leader may take it.
    pub(super) fn release_fence_turn(&mut self) {
        if !self.is_leader() || self.fence_turn_released {
            return;
        }
        self.fence_turn_released = true;
        let group = self.group;
        self.groups.with_state(|state| {
            state.fence_done.insert(group);
            while state.fence_done.remove(&state.fence_next) {
                state.fence_next += 1;
            }
        });
    }

    /// The leader holds the fence: the first turn starts.
    pub(super) fn fence_held(&self) {
        debug_assert!(self.is_leader());
        self.groups.with_state(|state| {
            if let Some(group) = state.groups.get_mut(&self.group) {
                group.turn = Some(0);
            }
        });
    }

    /// Wait for this member's turn. False when the group ended first (its
    /// leader left): the member must not run, as nobody holds the fence.
    pub(super) fn wait_turn(&self) -> bool {
        let mut state = self.groups.state.lock().recover_poison();
        loop {
            match state.groups.get(&self.group) {
                None => return false,
                Some(group) if group.ended => return false,
                Some(group) if group.turn == Some(self.index) => return true,
                Some(_) => {}
            }
            state = self.groups.changed.wait(state).recover_poison();
        }
    }

    /// End this member's turn, with its staged commit if it has one.
    pub(super) fn end_turn(&mut self, staged: Option<StagedCreation>) {
        let index = self.index;
        self.turn_ended = true;
        self.groups.with_state(|state| {
            if let Some(group) = state.groups.get_mut(&self.group) {
                if let Some(staged) = staged {
                    group.staged.push((index, staged));
                }
                group.pass_turn(index);
            }
        });
    }

    /// The leader: wait until every member ran, close the group to new
    /// members, and take the staged commits in turn order.
    pub(super) fn close_when_all_ran(&self) -> Vec<(usize, StagedCreation)> {
        debug_assert!(self.is_leader());
        let mut state = self.groups.state.lock().recover_poison();
        loop {
            let all_ran = state.groups.get(&self.group).is_none_or(Group::all_ran);
            if all_ran {
                if state.open == Some(self.group) {
                    state.open = None;
                }
                return state
                    .groups
                    .get_mut(&self.group)
                    .map(|group| std::mem::take(&mut group.staged))
                    .unwrap_or_default();
            }
            state = self.groups.changed.wait(state).recover_poison();
        }
    }

    /// The leader: give the other members their answers. Returns the
    /// leader's own answer, if the commit gave one.
    pub(super) fn answer(
        &mut self,
        answers: Vec<(usize, anyhow::Result<ResourcePatchCommit>)>,
    ) -> Option<anyhow::Result<ResourcePatchCommit>> {
        debug_assert!(self.is_leader());
        self.answered = true;
        let mut own = None;
        self.groups.with_state(|state| {
            let Some(group) = state.groups.get_mut(&self.group) else { return };
            for (index, answer) in answers {
                if index == 0 {
                    own = Some(answer);
                } else {
                    group.answers.insert(index, answer);
                }
            }
            group.ended = true;
            if group.waiting == 0 {
                state.groups.remove(&self.group);
            }
        });
        own
    }

    /// A member that staged a commit: wait for the leader's answer.
    pub(super) fn wait_answer(&mut self) -> anyhow::Result<ResourcePatchCommit> {
        debug_assert!(!self.is_leader());
        self.answered = true;
        let mut state = self.groups.state.lock().recover_poison();
        loop {
            let Some(group) = state.groups.get_mut(&self.group) else {
                return Err(anyhow::anyhow!(
                    "the creation group ended without this creation's answer"
                ));
            };
            if let Some(answer) = group.answers.remove(&self.index) {
                Self::took_answer(&mut state, self.group);
                drop(state);
                self.groups.changed.notify_all();
                return answer;
            }
            if group.ended {
                Self::took_answer(&mut state, self.group);
                drop(state);
                self.groups.changed.notify_all();
                return Err(anyhow::anyhow!(
                    "the creation group ended without this creation's answer"
                ));
            }
            state = self.groups.changed.wait(state).recover_poison();
        }
    }

    fn took_answer(state: &mut GroupsState, id: u64) {
        let Some(group) = state.groups.get_mut(&id) else { return };
        group.waiting = group.waiting.saturating_sub(1);
        if group.ended && group.waiting == 0 {
            state.groups.remove(&id);
        }
    }
}

impl Drop for GroupSeat<'_> {
    /// A member that leaves early (a panic, or an answer it did not wait
    /// for) must not hold its group: its turn passes on, and a leader that
    /// leaves ends the group, so no member runs without the fence.
    fn drop(&mut self) {
        self.release_fence_turn();
        let (index, turn_ended, answered, leader) =
            (self.index, self.turn_ended, self.answered, self.is_leader());
        self.groups.with_state(|state| {
            if state.open == Some(self.group) && leader {
                state.open = None;
            }
            let Some(group) = state.groups.get_mut(&self.group) else { return };
            if !turn_ended {
                group.gone.insert(index);
                if group.turn == Some(index) {
                    group.pass_turn(index);
                }
            }
            if leader {
                group.ended = true;
                if group.waiting == 0 {
                    state.groups.remove(&self.group);
                }
            } else if !answered {
                Self::took_answer(state, self.group);
            }
        });
    }
}

std::thread_local! {
    /// What [`with_group_join_notice`] runs when this thread's creation
    /// joins a group.
    static JOIN_NOTICE: std::cell::RefCell<Option<Box<dyn FnOnce()>>> =
        const { std::cell::RefCell::new(None) };
}

/// Restores the notice that was set before [`with_group_join_notice`].
struct RestoreNotice(Option<Box<dyn FnOnce()>>);

impl Drop for RestoreNotice {
    fn drop(&mut self) {
        let previous = self.0.take();
        JOIN_NOTICE.with(|notice| *notice.borrow_mut() = previous);
    }
}

/// Run `body`; when a creation it makes joins a creation group that takes
/// other members, run `notice` once, right after the join. A connection
/// that commits its creations in request order starts its next split then,
/// so the splits of one connection can share one group (SPLIT BURST).
pub(crate) fn with_group_join_notice<R>(notice: Box<dyn FnOnce()>, body: impl FnOnce() -> R) -> R {
    let _restore = RestoreNotice(JOIN_NOTICE.with(|slot| slot.replace(Some(notice))));
    body()
}

fn notify_group_joined() {
    if let Some(notice) = JOIN_NOTICE.with(|slot| slot.borrow_mut().take()) {
        notice();
    }
}

/// What a creation's own steps left.
pub(super) enum StagedCreationOutcome {
    /// Its answer: a replay, a failure or a settlement.
    Answered(anyhow::Result<ResourcePatchCommit>),
    /// An executed creation that waits for its group's projection commit.
    Staged(Box<StagedCreation>),
}

/// Whether creations of `operation` may share a group commit: a split or a
/// new pane. A new pane makes a workspace only in an empty session, and its
/// placement is not a choice scoped to the caller's thread.
pub(super) fn creation_shares_group_commit(operation: ResourceOperation) -> bool {
    matches!(operation, ResourceOperation::PaneSplit | ResourceOperation::PaneCreate)
}

impl Mux {
    /// Run one creation in its group: `stage` runs in the creation's turn,
    /// under the creation fence its group's leader holds. The leader then
    /// commits every staged member and answers them.
    pub(super) fn run_in_creation_group(
        self: &Arc<Self>,
        groupable: bool,
        keys: &[&str],
        stage: impl FnOnce() -> StagedCreationOutcome,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mut seat = self.creation_groups.join(groupable, keys);
        if groupable {
            notify_group_joined();
        }
        let fence = seat.is_leader().then(|| {
            self.run_creation_before_fence_hook();
            // The fence guards no data: a creation that panicked under it
            // leaves nothing half done for the next one to see.
            let fence = self.creation_wait(|| {
                seat.wait_fence_turn();
                self.resource_creation_execution.lock().unwrap_or_else(PoisonError::into_inner)
            });
            seat.fence_held();
            fence
        });
        // The leader's activity spans every member's effect and the commit.
        let activity =
            fence.as_ref().map(|_| ResourceCreationActivity::begin(&self.resource_creation_active));
        if !self.creation_wait(|| seat.wait_turn()) {
            anyhow::bail!("the creation group ended before this creation ran");
        }
        crate::debug_spans::mark("creation.execution_locked");
        let own = match stage() {
            StagedCreationOutcome::Answered(answer) => {
                seat.end_turn(None);
                Some(answer)
            }
            StagedCreationOutcome::Staged(staged) => {
                seat.end_turn(Some(*staged));
                None
            }
        };
        let Some(fence) = fence else {
            return own.unwrap_or_else(|| {
                let answer = seat.wait_answer();
                crate::debug_spans::mark("creation.group_answered");
                answer
            });
        };
        let staged = seat.close_when_all_ran();
        crate::debug_spans::mark("creation.group_ran");
        let answers = self.commit_creation_group(staged);
        drop(activity);
        let committed = seat.answer(answers);
        drop(fence);
        seat.release_fence_turn();
        own.or(committed)
            .unwrap_or_else(|| Err(anyhow::anyhow!("the creation group gave its leader no answer")))
    }

    /// Commit a group's staged creations: one alone as before, several in
    /// one projection and one journal write. A failed commit settles each
    /// member as a failed lone commit does.
    fn commit_creation_group(
        &self,
        staged: Vec<(usize, StagedCreation)>,
    ) -> Vec<(usize, anyhow::Result<ResourcePatchCommit>)> {
        if staged.len() <= 1 {
            return staged
                .into_iter()
                .map(|(index, staged)| (index, self.commit_staged_creation(staged)))
                .collect();
        }
        let views = staged
            .iter()
            .map(|(_, staged)| CreatedViewCommit {
                idempotency_key: &staged.idempotency_key,
                operation: &staged.operation_name,
                fingerprint: &staged.fingerprint,
                result: &staged.result,
            })
            .collect::<Vec<_>>();
        let committed = self.commit_created_views_projection(&views);
        drop(views);
        match committed {
            Ok(commits) => staged
                .into_iter()
                .zip(commits)
                .map(|((index, _), commit)| (index, self.activated_creation(commit)))
                .collect(),
            Err(error) => staged
                .into_iter()
                .map(|(index, staged)| (index, self.settle_failed_staged_creation(staged, &error)))
                .collect(),
        }
    }
}
