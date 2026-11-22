//! Hover intent for one warm group of tooltips: a target under the pointer
//! shows after `delay`, or at once while the group is warm (a tooltip shows,
//! or hid less than `warm_for` ago). Moving to another target before the
//! delay restarts it, so a sweep shows nothing. Pure: its owner feeds it the
//! target under the pointer and timer deadlines, and runs the effects on its
//! one timer.

/// The intent's phase.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HoverIntentPhase<T> {
    Idle,
    /// The pointer rests on `target`; it shows when `token` fires.
    Pending {
        target: T,
        token: u64,
    },
    Shown {
        target: T,
    },
    /// Nothing shows; until `token` fires, the next target shows at once.
    Warm {
        token: u64,
    },
}

/// What the owner does to its tooltip and its one timer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HoverIntentEffect<T> {
    /// Arm the one timer for `token` after `after` nanoseconds, replacing any armed one.
    Schedule {
        token: u64,
        after: i64,
    },
    CancelTimer,
    Show(T),
    Hide,
}

/// The most effects one call returns.
pub const MAX_INTENT_EFFECTS: usize = 2;

/// The effects of one call, in order, without allocating.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct IntentEffects<T> {
    items: [Option<HoverIntentEffect<T>>; MAX_INTENT_EFFECTS],
    len: usize,
}

impl<T> IntentEffects<T> {
    #[must_use]
    pub const fn new() -> Self {
        Self { items: [None, None], len: 0 }
    }

    fn with(mut self, effect: HoverIntentEffect<T>) -> Self {
        if let Some(slot) = self.items.get_mut(self.len) {
            *slot = Some(effect);
            self.len = self.len.saturating_add(1);
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

    pub fn iter(&self) -> impl Iterator<Item = &HoverIntentEffect<T>> {
        self.items.iter().flatten()
    }

    #[must_use]
    pub fn to_vec(&self) -> Vec<HoverIntentEffect<T>>
    where
        T: Clone,
    {
        self.iter().cloned().collect()
    }
}

impl<T> Default for IntentEffects<T> {
    fn default() -> Self {
        Self::new()
    }
}

/// One warm group of tooltips.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct HoverIntent<T> {
    phase: HoverIntentPhase<T>,
    next_token: u64,
    /// Pointer rest before the first target of a cold group shows (nanoseconds).
    pub delay: i64,
    /// How long the group stays warm after the last target hid (nanoseconds).
    pub warm_for: i64,
}

impl<T> HoverIntent<T> {
    #[must_use]
    pub const fn new(delay: i64, warm_for: i64) -> Self {
        Self { phase: HoverIntentPhase::Idle, next_token: 1, delay, warm_for }
    }

    /// An intent from its parts (the C ABI keeps it as a plain struct).
    #[must_use]
    pub const fn from_parts(
        phase: HoverIntentPhase<T>,
        next_token: u64,
        delay: i64,
        warm_for: i64,
    ) -> Self {
        Self { phase, next_token, delay, warm_for }
    }

    #[must_use]
    pub const fn phase(&self) -> &HoverIntentPhase<T> {
        &self.phase
    }

    #[must_use]
    pub const fn next_token(&self) -> u64 {
        self.next_token
    }

    #[must_use]
    pub const fn shown(&self) -> Option<&T> {
        if let HoverIntentPhase::Shown { target } = &self.phase { Some(target) } else { None }
    }

    #[must_use]
    pub const fn is_warm(&self) -> bool {
        matches!(self.phase, HoverIntentPhase::Shown { .. } | HoverIntentPhase::Warm { .. })
    }

    fn take_token(&mut self) -> u64 {
        let token = self.next_token;
        self.next_token = self.next_token.wrapping_add(1);
        token
    }
}

impl<T: Clone + PartialEq> HoverIntent<T> {
    /// The target under the pointer now (`None`: none).
    pub fn hover(&mut self, target: Option<T>) -> IntentEffects<T> {
        match self.phase.clone() {
            HoverIntentPhase::Idle => {
                let Some(target) = target else { return IntentEffects::new() };
                self.arm(target)
            }
            HoverIntentPhase::Pending { target: pending, .. } => {
                let Some(target) = target else {
                    self.phase = HoverIntentPhase::Idle;
                    return IntentEffects::new().with(HoverIntentEffect::CancelTimer);
                };
                if target == pending { IntentEffects::new() } else { self.arm(target) }
            }
            HoverIntentPhase::Shown { target: shown } => {
                let Some(target) = target else {
                    let token = self.take_token();
                    self.phase = HoverIntentPhase::Warm { token };
                    return IntentEffects::new()
                        .with(HoverIntentEffect::Hide)
                        .with(HoverIntentEffect::Schedule { token, after: self.warm_for });
                };
                if target == shown {
                    return IntentEffects::new();
                }
                self.phase = HoverIntentPhase::Shown { target: target.clone() };
                IntentEffects::new().with(HoverIntentEffect::Show(target))
            }
            HoverIntentPhase::Warm { .. } => {
                let Some(target) = target else { return IntentEffects::new() };
                self.phase = HoverIntentPhase::Shown { target: target.clone() };
                IntentEffects::new()
                    .with(HoverIntentEffect::CancelTimer)
                    .with(HoverIntentEffect::Show(target))
            }
        }
    }

    /// The one timer for `token` fired.
    pub fn deadline(&mut self, token: u64) -> IntentEffects<T> {
        match self.phase.clone() {
            HoverIntentPhase::Pending { target, token: armed } if armed == token => {
                self.phase = HoverIntentPhase::Shown { target: target.clone() };
                IntentEffects::new().with(HoverIntentEffect::Show(target))
            }
            HoverIntentPhase::Warm { token: armed } if armed == token => {
                self.phase = HoverIntentPhase::Idle;
                IntentEffects::new()
            }
            _ => IntentEffects::new(),
        }
    }

    /// A click, a key or a scroll: whatever shows goes, and the group is cold again.
    pub fn dismiss(&mut self) -> IntentEffects<T> {
        let effects = match self.phase {
            HoverIntentPhase::Idle => IntentEffects::new(),
            HoverIntentPhase::Pending { .. } | HoverIntentPhase::Warm { .. } => {
                IntentEffects::new().with(HoverIntentEffect::CancelTimer)
            }
            HoverIntentPhase::Shown { .. } => IntentEffects::new().with(HoverIntentEffect::Hide),
        };
        self.phase = HoverIntentPhase::Idle;
        effects
    }

    fn arm(&mut self, target: T) -> IntentEffects<T> {
        if self.delay <= 0 {
            self.phase = HoverIntentPhase::Shown { target: target.clone() };
            return IntentEffects::new().with(HoverIntentEffect::Show(target));
        }
        let token = self.take_token();
        self.phase = HoverIntentPhase::Pending { target, token };
        IntentEffects::new().with(HoverIntentEffect::Schedule { token, after: self.delay })
    }
}
