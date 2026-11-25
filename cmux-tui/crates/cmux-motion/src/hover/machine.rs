//! The hover card state machine (plans/cmux-next/hovercards.md). One per app:
//! there is one phase, so at most one card is pending or shown. Pure: the
//! coordinator (the platform layer) feeds it events and runs its effects on
//! its one card and its one timer.

use super::timing::{
    HOVER_CARD_PIN_LIFETIME, HOVER_CARD_RESHOW_WINDOW, HOVER_CARD_STILL_POINTER_DELAY,
    HoverIntentTiming,
};

/// What the pointer leaving a shown card's target does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HoverCardLeave {
    /// The card stays for the leave grace; a pointer heading into it or
    /// resting on it keeps it (the workspace card).
    Lingers,
    /// The card hides as soon as the pointer leaves its target for anywhere
    /// but the card (a browser's tab preview). The card touches its target,
    /// so a pointer moving onto it keeps it while it rests there. Another
    /// target reached within `reshow` (nanoseconds) shows its card at once.
    Hides { reshow: i64 },
}

impl HoverCardLeave {
    /// The card hides as the pointer leaves its target (`Hides`).
    #[must_use]
    pub const fn hides_at_once(self) -> bool {
        matches!(self, Self::Hides { .. })
    }
}

/// What the machine needs to know about a target: its id, its window, how
/// long the pointer must rest on it before its card shows (nanoseconds; zero
/// or less: none), and what leaving it does.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct HoverTarget<Id> {
    pub id: Id,
    pub window: i64,
    pub delay: i64,
    pub leave: HoverCardLeave,
}

/// Keeps cards away while it lasts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HoverSuppression {
    Drag,
    Scroll,
    SidebarHide,
}

impl HoverSuppression {
    /// Every suppression, in bit order (`HoverSuppressions` bit `i` is `ALL[i]`).
    pub const ALL: [Self; 3] = [Self::Drag, Self::Scroll, Self::SidebarHide];

    const fn bit(self) -> u8 {
        match self {
            Self::Drag => 0b001,
            Self::Scroll => 0b010,
            Self::SidebarHide => 0b100,
        }
    }
}

/// A set of suppressions (bit `i` is `HoverSuppression::ALL[i]`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct HoverSuppressions(u8);

impl HoverSuppressions {
    /// The set from its bits; bits past the known suppressions are dropped.
    #[must_use]
    pub const fn from_bits(bits: u8) -> Self {
        Self(bits & 0b111)
    }

    #[must_use]
    pub const fn bits(self) -> u8 {
        self.0
    }

    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    #[must_use]
    pub const fn contains(self, s: HoverSuppression) -> bool {
        self.0 & s.bit() != 0
    }

    pub fn insert(&mut self, s: HoverSuppression) {
        self.0 |= s.bit();
    }

    pub fn remove(&mut self, s: HoverSuppression) {
        self.0 &= !s.bit();
    }
}

/// The machine's phase.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum HoverCardPhase<Id> {
    Idle,
    /// The pointer rests on `target`; its card shows when `token` fires.
    Pending {
        target: HoverTarget<Id>,
        token: u64,
    },
    /// The card shows `target` because the pointer rests on it.
    Shown {
        target: HoverTarget<Id>,
    },
    /// The card shows `target` because an action asked for it (Show Resource
    /// Usage). It stays when the pointer leaves; a dismissal or its lifetime
    /// (`token`) ends it.
    Pinned {
        target: HoverTarget<Id>,
        token: u64,
    },
    /// The card still shows `target`, but the pointer left every target, or
    /// heads into the card across another one (the safe triangle); another
    /// target before `token` fires slides the card over, else it hides. A
    /// pointer resting on the card keeps it.
    Leaving {
        target: HoverTarget<Id>,
        token: u64,
    },
    /// A card just hid; a hover before `token` fires shows at once (quick reshow).
    Grace {
        token: u64,
    },
}

/// Inputs of the machine.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum HoverCardEvent<Id> {
    /// What is under the pointer now: after a pointer move (`moved` true), or
    /// after content moved under a still pointer (`moved` false), from a fresh
    /// hit test. `aiming`: the pointer moved toward the shown card along the
    /// safe triangle (`aimed_at`). `bridging`: no target, but the pointer is
    /// between a source's targets or on the shown card: a `Hides` card stays
    /// for its reshow window, so the next target swaps it in without a hide.
    Hit {
        target: Option<HoverTarget<Id>>,
        moved: bool,
        aiming: bool,
        bridging: bool,
    },
    /// Whether the pointer rests on the shown card now (sent before each
    /// deadline: the card ignores the mouse, so no source sees it there).
    PointerOnCard(bool),
    /// The one-shot timer for `token` fired.
    Deadline(u64),
    /// A key, a click, a scroll wheel, a menu, the window or app losing focus,
    /// or an action: ends any card and keeps cards away until the pointer moves.
    Dismiss,
    Suppress(HoverSuppression),
    Unsuppress(HoverSuppression),
    /// The target is gone (tab closed, workspace removed, strip torn down).
    TargetRemoved(Id),
    /// Show `target`'s card now, until a dismissal (Show Resource Usage).
    Pin(HoverTarget<Id>),
    /// A card its owner shows took the one card window (true), or left it
    /// (false). Taking it ends any pending or shown card without a hide (the
    /// one card morphs to the owner's content); while it shows, the next
    /// target the pointer reaches takes the card back at once.
    Owned(bool),
}

/// Outputs: what the coordinator does to the one card and the one timer.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum HoverCardEffect<Id> {
    /// Arms the one timer for `token` after `after` nanoseconds (replacing any armed one).
    Schedule {
        token: u64,
        after: i64,
    },
    CancelTimer,
    /// Shows the card for `target`, or moves it there and updates it.
    /// `sliding`: the card was visible for another target and slides over.
    Show {
        target: HoverTarget<Id>,
        sliding: bool,
    },
    Hide,
}

/// The most effects one event produces (`end` then `resume`: cancel, hide, arm).
pub const MAX_EFFECTS_PER_EVENT: usize = 3;

/// The effects of one event, in order, without allocating.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Effects<Id> {
    items: [Option<HoverCardEffect<Id>>; MAX_EFFECTS_PER_EVENT],
    len: usize,
}

impl<Id> Effects<Id> {
    #[must_use]
    pub const fn new() -> Self {
        Self { items: [None, None, None], len: 0 }
    }

    fn push(&mut self, effect: HoverCardEffect<Id>) {
        if let Some(slot) = self.items.get_mut(self.len) {
            *slot = Some(effect);
            self.len = self.len.saturating_add(1);
        }
    }

    fn with(mut self, effect: HoverCardEffect<Id>) -> Self {
        self.push(effect);
        self
    }

    fn extend(mut self, other: Self) -> Self {
        for effect in other.items.into_iter().flatten() {
            self.push(effect);
        }
        self
    }

    #[must_use]
    pub const fn len(&self) -> usize {
        self.len
    }

    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn iter(&self) -> impl Iterator<Item = &HoverCardEffect<Id>> {
        self.items.iter().flatten()
    }

    /// The effects as a vector (tests, debugging).
    #[must_use]
    pub fn to_vec(&self) -> Vec<HoverCardEffect<Id>>
    where
        Id: Clone,
    {
        self.iter().cloned().collect()
    }
}

impl<Id> Default for Effects<Id> {
    fn default() -> Self {
        Self::new()
    }
}

impl<Id> IntoIterator for Effects<Id> {
    type Item = HoverCardEffect<Id>;
    type IntoIter = std::iter::Flatten<std::array::IntoIter<Option<HoverCardEffect<Id>>, 3>>;

    fn into_iter(self) -> Self::IntoIter {
        self.items.into_iter().flatten()
    }
}

/// The hover card state machine.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct HoverCardMachine<Id> {
    phase: HoverCardPhase<Id>,
    /// Active suppressions; no card is pending or shown while any lasts.
    suppressions: HoverSuppressions,
    /// What the last hit test found under the pointer.
    last_hit: Option<HoverTarget<Id>>,
    /// After a dismissal or suppression, a still pointer starts no card on the
    /// target it is already on; a pointer move clears it.
    quiet: bool,
    /// The next timer token; every token is used once.
    next_token: u64,
    /// The pointer rests on the shown card (the coordinator says so before each deadline).
    pointer_on_card: bool,
    /// A card its owner shows has the one card window (`Owned`).
    owned_card_shown: bool,
    /// The last deadline found the pointer on the card: when it leaves, the full grace starts then.
    was_on_card: bool,
    /// How long after a card hides a new hover shows at once.
    pub reshow_window: i64,
    /// How long a pinned card stays without a dismissal.
    pub pin_lifetime: i64,
    /// How long a card stays after the pointer leaves every target and the card.
    pub leave_window: i64,
    /// How long a pointer heading into the shown card may pause on another
    /// target it crosses before that target takes the card over.
    pub aim_window: i64,
    /// How long a target with no delay waits when it arrives under a still pointer.
    pub still_pointer_delay: i64,
}

impl<Id> Default for HoverCardMachine<Id> {
    fn default() -> Self {
        Self::new()
    }
}

/// The parts of a machine, every field (the C ABI keeps a machine as a plain
/// struct and rebuilds it per call with `from_parts`).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct HoverCardMachineParts<Id> {
    pub phase: HoverCardPhase<Id>,
    pub suppressions: HoverSuppressions,
    pub last_hit: Option<HoverTarget<Id>>,
    pub quiet: bool,
    pub next_token: u64,
    pub pointer_on_card: bool,
    pub owned_card_shown: bool,
    pub was_on_card: bool,
    pub reshow_window: i64,
    pub pin_lifetime: i64,
    pub leave_window: i64,
    pub aim_window: i64,
    pub still_pointer_delay: i64,
}

fn same_id<Id: PartialEq>(a: Option<&HoverTarget<Id>>, b: Option<&HoverTarget<Id>>) -> bool {
    a.map(|t| &t.id) == b.map(|t| &t.id)
}

impl<Id> HoverCardMachine<Id> {
    /// A machine with the default windows.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            phase: HoverCardPhase::Idle,
            suppressions: HoverSuppressions(0),
            last_hit: None,
            quiet: false,
            next_token: 1,
            pointer_on_card: false,
            owned_card_shown: false,
            was_on_card: false,
            reshow_window: HOVER_CARD_RESHOW_WINDOW,
            pin_lifetime: HOVER_CARD_PIN_LIFETIME,
            leave_window: HoverIntentTiming::STANDARD.card_grace,
            aim_window: HoverIntentTiming::STANDARD.card_aim,
            still_pointer_delay: HOVER_CARD_STILL_POINTER_DELAY,
        }
    }

    #[must_use]
    pub fn from_parts(p: HoverCardMachineParts<Id>) -> Self {
        Self {
            phase: p.phase,
            suppressions: p.suppressions,
            last_hit: p.last_hit,
            quiet: p.quiet,
            next_token: p.next_token,
            pointer_on_card: p.pointer_on_card,
            owned_card_shown: p.owned_card_shown,
            was_on_card: p.was_on_card,
            reshow_window: p.reshow_window,
            pin_lifetime: p.pin_lifetime,
            leave_window: p.leave_window,
            aim_window: p.aim_window,
            still_pointer_delay: p.still_pointer_delay,
        }
    }

    #[must_use]
    pub fn into_parts(self) -> HoverCardMachineParts<Id> {
        HoverCardMachineParts {
            phase: self.phase,
            suppressions: self.suppressions,
            last_hit: self.last_hit,
            quiet: self.quiet,
            next_token: self.next_token,
            pointer_on_card: self.pointer_on_card,
            owned_card_shown: self.owned_card_shown,
            was_on_card: self.was_on_card,
            reshow_window: self.reshow_window,
            pin_lifetime: self.pin_lifetime,
            leave_window: self.leave_window,
            aim_window: self.aim_window,
            still_pointer_delay: self.still_pointer_delay,
        }
    }

    #[must_use]
    pub const fn phase(&self) -> &HoverCardPhase<Id> {
        &self.phase
    }

    #[must_use]
    pub const fn suppressions(&self) -> HoverSuppressions {
        self.suppressions
    }

    #[must_use]
    pub const fn last_hit(&self) -> Option<&HoverTarget<Id>> {
        self.last_hit.as_ref()
    }

    #[must_use]
    pub const fn quiet(&self) -> bool {
        self.quiet
    }

    #[must_use]
    pub const fn next_token(&self) -> u64 {
        self.next_token
    }

    #[must_use]
    pub const fn pointer_on_card(&self) -> bool {
        self.pointer_on_card
    }

    #[must_use]
    pub const fn owned_card_shown(&self) -> bool {
        self.owned_card_shown
    }

    /// The last deadline found the pointer on the card.
    #[must_use]
    pub const fn was_on_card(&self) -> bool {
        self.was_on_card
    }

    /// The target whose card is pending or shown.
    #[must_use]
    pub const fn active_target(&self) -> Option<&HoverTarget<Id>> {
        match &self.phase {
            HoverCardPhase::Pending { target, .. }
            | HoverCardPhase::Shown { target }
            | HoverCardPhase::Pinned { target, .. }
            | HoverCardPhase::Leaving { target, .. } => Some(target),
            HoverCardPhase::Idle | HoverCardPhase::Grace { .. } => None,
        }
    }

    /// The target whose card is on screen.
    #[must_use]
    pub const fn shown_target(&self) -> Option<&HoverTarget<Id>> {
        match &self.phase {
            HoverCardPhase::Shown { target }
            | HoverCardPhase::Pinned { target, .. }
            | HoverCardPhase::Leaving { target, .. } => Some(target),
            HoverCardPhase::Idle
            | HoverCardPhase::Pending { .. }
            | HoverCardPhase::Grace { .. } => None,
        }
    }

    /// The token the armed timer carries, if one should be armed.
    #[must_use]
    pub const fn armed_token(&self) -> Option<u64> {
        match &self.phase {
            HoverCardPhase::Pending { token, .. }
            | HoverCardPhase::Grace { token }
            | HoverCardPhase::Pinned { token, .. }
            | HoverCardPhase::Leaving { token, .. } => Some(*token),
            HoverCardPhase::Idle | HoverCardPhase::Shown { .. } => None,
        }
    }

    const fn is_idle(&self) -> bool {
        matches!(self.phase, HoverCardPhase::Idle)
    }

    fn take_token(&mut self) -> u64 {
        let token = self.next_token;
        self.next_token = self.next_token.wrapping_add(1);
        token
    }
}

impl<Id: Clone + PartialEq> HoverCardMachine<Id> {
    /// Applies one event and returns what the coordinator must do, in order.
    pub fn reduce(&mut self, event: HoverCardEvent<Id>) -> Effects<Id> {
        match event {
            HoverCardEvent::Hit { target, moved, aiming, bridging } => {
                self.hit(target, moved, aiming, bridging)
            }
            HoverCardEvent::PointerOnCard(on) => {
                self.pointer_on_card = on;
                Effects::new()
            }
            HoverCardEvent::Deadline(token) => self.deadline(token),
            HoverCardEvent::Dismiss => {
                self.quiet = true;
                self.end()
            }
            HoverCardEvent::Suppress(reason) => {
                self.suppressions.insert(reason);
                self.quiet = true;
                self.end()
            }
            HoverCardEvent::Unsuppress(reason) => {
                self.suppressions.remove(reason);
                // A pointer that moved during the drag or scroll gets its card.
                self.resume()
            }
            HoverCardEvent::TargetRemoved(id) => {
                if self.last_hit.as_ref().is_some_and(|t| t.id == id) {
                    self.last_hit = None;
                }
                if !self.active_target().is_some_and(|t| t.id == id) {
                    return Effects::new();
                }
                let ended = self.end();
                ended.extend(self.resume())
            }
            HoverCardEvent::Owned(shown) => {
                self.owned_card_shown = shown;
                if !shown {
                    return Effects::new();
                }
                // The owner's card takes the window: no card of a target is
                // pending or shown, and nothing hides (the window morphs).
                self.quiet = false;
                let had_timer = self.armed_token().is_some();
                self.phase = HoverCardPhase::Idle;
                if had_timer {
                    Effects::new().with(HoverCardEffect::CancelTimer)
                } else {
                    Effects::new()
                }
            }
            HoverCardEvent::Pin(target) => {
                // No card during a drag or scroll, pinned or not.
                if !self.suppressions.is_empty() {
                    return Effects::new();
                }
                self.quiet = false;
                let was_shown = self.shown_target().is_some();
                let token = self.take_token();
                self.phase = HoverCardPhase::Pinned { target: target.clone(), token };
                Effects::new()
                    .with(HoverCardEffect::Schedule { token, after: self.pin_lifetime })
                    .with(HoverCardEffect::Show { target, sliding: was_shown })
            }
        }
    }

    fn deadline(&mut self, token: u64) -> Effects<Id> {
        match self.phase.clone() {
            HoverCardPhase::Pending { target, token: armed } if armed == token => {
                self.phase = HoverCardPhase::Shown { target: target.clone() };
                Effects::new().with(HoverCardEffect::Show { target, sliding: false })
            }
            HoverCardPhase::Grace { token: armed } if armed == token => {
                self.phase = HoverCardPhase::Idle;
                Effects::new()
            }
            HoverCardPhase::Leaving { target: shown, token: armed } if armed == token => {
                // The pointer rests on the card: it stays, and looks again
                // after the grace. Just off it: the full grace starts now. A
                // card that hides on leave stays only while the pointer is on
                // it (it touches its tab, Lawrence 2026-10-19), and looks
                // again after its reshow window.
                let hides = shown.leave.hides_at_once();
                if self.pointer_on_card || (!hides && self.was_on_card) {
                    self.was_on_card = self.pointer_on_card;
                    let again = self.take_token();
                    let after = match shown.leave {
                        HoverCardLeave::Hides { reshow } => reshow,
                        HoverCardLeave::Lingers => self.leave_window,
                    };
                    self.phase = HoverCardPhase::Leaving { target: shown, token: again };
                    return Effects::new().with(HoverCardEffect::Schedule { token: again, after });
                }
                // The pointer stopped aiming on another target: it takes the card over.
                if self.suppressions.is_empty()
                    && let Some(target) = self.last_hit.clone()
                    && target.id != shown.id
                {
                    self.phase = HoverCardPhase::Shown { target: target.clone() };
                    return Effects::new().with(HoverCardEffect::Show { target, sliding: true });
                }
                // No target took the card over: it hides, and a quick return
                // still shows at once.
                let grace = self.take_token();
                self.phase = HoverCardPhase::Grace { token: grace };
                let reshow = match shown.leave {
                    HoverCardLeave::Hides { reshow } => reshow,
                    HoverCardLeave::Lingers => self.reshow_window,
                };
                Effects::new()
                    .with(HoverCardEffect::Hide)
                    .with(HoverCardEffect::Schedule { token: grace, after: reshow })
            }
            HoverCardPhase::Pinned { target, token: armed } if armed == token => {
                // The pinned card's lifetime ended (its timer is spent). With
                // the pointer still on its target it stays as a hover card.
                if self.suppressions.is_empty()
                    && let Some(hit) = self.last_hit.clone()
                    && hit.id == target.id
                {
                    self.phase = HoverCardPhase::Shown { target: hit };
                    return Effects::new();
                }
                self.phase = HoverCardPhase::Idle;
                Effects::new().with(HoverCardEffect::Hide).extend(self.resume())
            }
            // A stale token (its state was left before it fired) does nothing.
            _ => Effects::new(),
        }
    }

    fn hit(
        &mut self,
        target: Option<HoverTarget<Id>>,
        moved: bool,
        aiming: bool,
        bridging: bool,
    ) -> Effects<Id> {
        let previous = std::mem::replace(&mut self.last_hit, target.clone());
        if target.is_some() {
            self.was_on_card = false;
        }
        let same_as_previous = same_id(target.as_ref(), previous.as_ref());
        // Quiet covers only the target the pointer already rested on: another
        // target arriving under it ends it, and so does a pointer move, except
        // on a target whose card hides on leave (a browser's tab preview: a
        // click or Esc lasts until the pointer leaves the tab).
        let target_hides = target.as_ref().is_some_and(|t| t.leave.hides_at_once());
        if !same_as_previous || (moved && !target_hides) {
            self.quiet = false;
        }
        if !self.suppressions.is_empty() {
            return if self.is_idle() { Effects::new() } else { self.end() };
        }
        // A still pointer after a dismissal starts nothing on the target it
        // was already on; a different target moving under it may.
        if self.quiet && same_as_previous {
            if let Some(shown) = self.shown_target()
                && target.as_ref().is_some_and(|t| t.id == shown.id)
            {
                return Effects::new();
            }
            return if self.is_idle() { Effects::new() } else { self.end() };
        }
        match self.phase.clone() {
            HoverCardPhase::Idle => {
                let Some(target) = target else { return Effects::new() };
                // The owner's card shows: the next target takes the one card at once (it morphs).
                if self.owned_card_shown {
                    self.phase = HoverCardPhase::Shown { target: target.clone() };
                    return Effects::new().with(HoverCardEffect::Show { target, sliding: true });
                }
                self.arm(target, moved)
            }
            HoverCardPhase::Pending { target: pending, .. } => {
                let Some(target) = target else { return self.end() };
                if target.id == pending.id {
                    return Effects::new();
                }
                self.arm(target, moved)
            }
            HoverCardPhase::Grace { .. } => {
                let Some(target) = target else { return Effects::new() };
                self.phase = HoverCardPhase::Shown { target: target.clone() };
                Effects::new()
                    .with(HoverCardEffect::CancelTimer)
                    .with(HoverCardEffect::Show { target, sliding: false })
            }
            HoverCardPhase::Shown { target: shown } => {
                self.hit_shown(shown, target, aiming, bridging)
            }
            HoverCardPhase::Leaving { target: shown, .. } => {
                self.hit_leaving(shown, target, aiming, bridging)
            }
            HoverCardPhase::Pinned { target: shown, token } => {
                // The pointer leaving keeps a pinned card, and so does content
                // moving under a still pointer; a pointer that moves onto
                // another target takes over.
                let Some(target) = target else { return Effects::new() };
                if target.id == shown.id {
                    self.phase = HoverCardPhase::Pinned { target, token };
                    return Effects::new();
                }
                if !moved {
                    return Effects::new();
                }
                self.phase = HoverCardPhase::Shown { target: target.clone() };
                Effects::new()
                    .with(HoverCardEffect::CancelTimer)
                    .with(HoverCardEffect::Show { target, sliding: true })
            }
        }
    }

    fn hit_shown(
        &mut self,
        shown: HoverTarget<Id>,
        target: Option<HoverTarget<Id>>,
        aiming: bool,
        bridging: bool,
    ) -> Effects<Id> {
        let on_shown = target.as_ref().is_some_and(|t| t.id == shown.id);
        if let HoverCardLeave::Hides { reshow } = shown.leave
            && !on_shown
        {
            let Some(target) = target else {
                if bridging {
                    // Between targets: the card stays for the reshow window,
                    // and the next target slides it over (no hide and show
                    // crossing a gap).
                    let token = self.take_token();
                    self.phase = HoverCardPhase::Leaving { target: shown, token };
                    return Effects::new().with(HoverCardEffect::Schedule { token, after: reshow });
                }
                let grace = self.take_token();
                self.phase = HoverCardPhase::Grace { token: grace };
                return Effects::new()
                    .with(HoverCardEffect::Hide)
                    .with(HoverCardEffect::Schedule { token: grace, after: reshow });
            };
            if aiming {
                // Heading into a card beside its row across another row (the
                // safe triangle): that row takes the card only if the pointer
                // stops on it (Leo 2026-11-01: "for my mouse to be able to
                // reliably go across them").
                let token = self.take_token();
                self.phase = HoverCardPhase::Leaving { target: shown, token };
                return Effects::new()
                    .with(HoverCardEffect::Schedule { token, after: self.aim_window });
            }
            // Otherwise it swaps at once.
            self.phase = HoverCardPhase::Shown { target: target.clone() };
            return Effects::new().with(HoverCardEffect::Show { target, sliding: true });
        }
        let Some(target) = target else {
            let token = self.take_token();
            let after = if aiming { self.aim_window } else { self.leave_window };
            self.phase = HoverCardPhase::Leaving { target: shown, token };
            return Effects::new().with(HoverCardEffect::Schedule { token, after });
        };
        if target.id == shown.id {
            // The target moved or resized: the coordinator moves the card.
            self.phase = HoverCardPhase::Shown { target };
            return Effects::new();
        }
        if aiming {
            // Heading into the card across another target: that target takes
            // the card over only if the pointer stops on it.
            let token = self.take_token();
            self.phase = HoverCardPhase::Leaving { target: shown, token };
            return Effects::new()
                .with(HoverCardEffect::Schedule { token, after: self.aim_window });
        }
        self.phase = HoverCardPhase::Shown { target: target.clone() };
        Effects::new().with(HoverCardEffect::Show { target, sliding: true })
    }

    fn hit_leaving(
        &mut self,
        shown: HoverTarget<Id>,
        target: Option<HoverTarget<Id>>,
        aiming: bool,
        bridging: bool,
    ) -> Effects<Id> {
        if let HoverCardLeave::Hides { reshow } = shown.leave {
            let Some(target) = target else {
                // Still between targets or on the card: the window runs on.
                // Off them and off the card: it hides now.
                if bridging {
                    return Effects::new();
                }
                let grace = self.take_token();
                self.phase = HoverCardPhase::Grace { token: grace };
                return Effects::new()
                    .with(HoverCardEffect::Hide)
                    .with(HoverCardEffect::Schedule { token: grace, after: reshow });
            };
            if aiming && target.id != shown.id {
                // Still heading into the card: the aim restarts.
                let token = self.take_token();
                self.phase = HoverCardPhase::Leaving { target: shown, token };
                return Effects::new()
                    .with(HoverCardEffect::Schedule { token, after: self.aim_window });
            }
            return self.retake(shown, target);
        }
        let on_shown = target.as_ref().is_some_and(|t| t.id == shown.id);
        if aiming && !on_shown {
            // Still heading for the card: the aim restarts.
            let token = self.take_token();
            self.phase = HoverCardPhase::Leaving { target: shown, token };
            return Effects::new()
                .with(HoverCardEffect::Schedule { token, after: self.aim_window });
        }
        let Some(target) = target else { return Effects::new() };
        self.retake(shown, target)
    }

    /// From `Leaving`: `target` takes the card (back), and the timer stops.
    fn retake(&mut self, shown: HoverTarget<Id>, target: HoverTarget<Id>) -> Effects<Id> {
        let same = target.id == shown.id;
        self.phase = HoverCardPhase::Shown { target: target.clone() };
        let effects = Effects::new().with(HoverCardEffect::CancelTimer);
        if same { effects } else { effects.with(HoverCardEffect::Show { target, sliding: true }) }
    }

    /// From idle, with the pointer resting on a target and nothing keeping
    /// cards away, that target's card starts again (after a pinned card of
    /// another target ended).
    fn resume(&mut self) -> Effects<Id> {
        if !self.is_idle() || !self.suppressions.is_empty() || self.quiet {
            return Effects::new();
        }
        let Some(target) = self.last_hit.clone() else { return Effects::new() };
        self.arm(target, false)
    }

    fn arm(&mut self, target: HoverTarget<Id>, moved: bool) -> Effects<Id> {
        // A target with no delay: a moving pointer's card shows on this hit;
        // content moving under a still pointer waits a moment. Targets with a
        // delay (`sidebar.hoverCards.delay`) wait it.
        if target.delay <= 0 && moved {
            let had_timer = self.armed_token().is_some();
            self.phase = HoverCardPhase::Shown { target: target.clone() };
            let effects = if had_timer {
                Effects::new().with(HoverCardEffect::CancelTimer)
            } else {
                Effects::new()
            };
            return effects.with(HoverCardEffect::Show { target, sliding: false });
        }
        let token = self.take_token();
        let after = if target.delay > 0 { target.delay } else { self.still_pointer_delay };
        self.phase = HoverCardPhase::Pending { target, token };
        Effects::new().with(HoverCardEffect::Schedule { token, after })
    }

    /// Back to idle: cancels the timer and hides a shown card.
    fn end(&mut self) -> Effects<Id> {
        self.was_on_card = false;
        let was_shown = self.shown_target().is_some();
        let had_timer = self.armed_token().is_some();
        self.phase = HoverCardPhase::Idle;
        let mut effects = Effects::new();
        if had_timer {
            effects.push(HoverCardEffect::CancelTimer);
        }
        if was_shown {
            effects.push(HoverCardEffect::Hide);
        }
        effects
    }
}
