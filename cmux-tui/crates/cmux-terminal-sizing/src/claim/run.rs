//! The helpers [`step`](super::step) runs an event through: each is one piece of the Swift it
//! replaces, named in its doc.

use super::{
    CLAIM_ANSWER_WINDOW_MS, Claim, Effect, Generation, Lease, Mode, Pending, RECLAIM_WAIT_MS,
    RELEASE_DEBOUNCE_MS, RESIZE_SETTLE_MS, SizeClaim, Timer,
};
use crate::TerminalGridSize;

pub(super) struct Run {
    pub(super) s: SizeClaim,
    pub(super) fx: Vec<Effect>,
    pub(super) mode: Mode,
}

impl Run {
    pub(super) fn start(&mut self, timer: Timer, after_ms: u64) -> Generation {
        self.s.issued = Generation(self.s.issued.0 + 1);
        let generation = self.s.issued;
        self.fx.push(Effect::StartTimer { timer, after_ms, generation });
        generation
    }

    pub(super) fn cancel(&mut self, timer: Timer) {
        self.fx.push(Effect::CancelTimer { timer });
    }

    pub(super) fn wants(&self) -> bool {
        self.mode == Mode::Fit && self.s.page_shown && self.s.foreground
    }

    /// `TerminalSizeClaimDebounce.update`: claim at once; release after the debounce when the
    /// page left, at once when the app left the foreground (or the mode keeps the host's size).
    pub(super) fn debounce(&mut self) {
        if self.wants() {
            if self.s.release_timer.take().is_some() {
                self.cancel(Timer::Release);
            }
            match self.s.claim {
                Claim::Released => {
                    self.s.claim = Claim::Unsent;
                    self.try_send();
                }
                Claim::Unsent
                | Claim::AwaitingAnswer { .. }
                | Claim::Claimed { .. }
                | Claim::Reclaiming { .. }
                | Claim::HostKeeps { .. } => {}
            }
            return;
        }
        match self.s.claim {
            Claim::Released => {
                if self.s.release_timer.take().is_some() {
                    self.cancel(Timer::Release);
                }
            }
            Claim::Unsent
            | Claim::AwaitingAnswer { .. }
            | Claim::Claimed { .. }
            | Claim::Reclaiming { .. }
            | Claim::HostKeeps { .. } => {
                if !self.s.foreground || self.mode == Mode::KeepHostSize {
                    if self.s.release_timer.take().is_some() {
                        self.cancel(Timer::Release);
                    }
                    self.release();
                } else if self.s.release_timer.is_none() {
                    self.s.release_timer = Some(self.start(Timer::Release, RELEASE_DEBOUNCE_MS));
                }
            }
        }
    }

    /// `setClaimsSize(false)`: the size goes back at once when the Mac holds one.
    pub(super) fn release(&mut self) {
        match self.s.claim {
            Claim::Released | Claim::Unsent => {}
            Claim::AwaitingAnswer { .. } => {
                self.cancel(Timer::Answer);
                self.fx.push(Effect::SendRelease);
            }
            Claim::Reclaiming { .. } => {
                self.cancel(Timer::Reclaim);
                self.fx.push(Effect::SendRelease);
            }
            Claim::Claimed { .. } | Claim::HostKeeps { .. } => self.fx.push(Effect::SendRelease),
        }
        if self.s.lease_timer.take().is_some() {
            self.cancel(Timer::Lease);
        }
        self.s.claim = Claim::Released;
    }

    /// Claiming with nothing at the Mac: the grid goes out once there is a link and a grid.
    pub(super) fn try_send(&mut self) {
        if let (Some(_), Some(grid)) = (self.s.link, self.s.grid) {
            self.send(grid);
        }
    }

    /// `resize-surface {grid}`, or a release when the mode keeps the host's size.
    pub(super) fn send(&mut self, grid: TerminalGridSize) {
        if self.mode == Mode::KeepHostSize {
            self.release();
            return;
        }
        match self.s.claim {
            Claim::Reclaiming { .. } => self.cancel(Timer::Reclaim),
            Claim::Released
            | Claim::Unsent
            | Claim::AwaitingAnswer { .. }
            | Claim::Claimed { .. }
            | Claim::HostKeeps { .. } => {}
        }
        self.fx.push(Effect::SendResize { grid });
        let asked = self.start(Timer::Answer, CLAIM_ANSWER_WINDOW_MS);
        self.s.claim = Claim::AwaitingAnswer { grid, asked };
        self.ensure_lease();
    }

    pub(super) fn ensure_lease(&mut self) {
        if self.s.lease_timer.is_none()
            && let Some(ms) = self.s.link.and_then(Lease::refresh_ms)
        {
            self.s.lease_timer = Some(self.start(Timer::Lease, ms));
        }
    }

    pub(super) fn drop_link_timers(&mut self) {
        match self.s.claim {
            Claim::AwaitingAnswer { .. } => self.cancel(Timer::Answer),
            Claim::Reclaiming { .. } => self.cancel(Timer::Reclaim),
            Claim::Released | Claim::Unsent | Claim::Claimed { .. } | Claim::HostKeeps { .. } => {}
        }
        if self.s.lease_timer.take().is_some() {
            self.cancel(Timer::Lease);
        }
    }

    /// `TerminalResizeSettle.measured`: the first grid at once, the applied one drops what is
    /// pending, the pending one again changes nothing, any other one waits out the settle.
    pub(super) fn measured(&mut self, grid: TerminalGridSize) {
        let Some(applied) = self.s.grid else {
            if self.s.settling.take().is_some() {
                self.cancel(Timer::Settle);
            }
            self.give(grid);
            return;
        };
        if grid == applied {
            if self.s.settling.take().is_some() {
                self.cancel(Timer::Settle);
            }
            return;
        }
        if self.s.settling.map(|p| p.grid) == Some(grid) {
            return;
        }
        let timer = self.start(Timer::Settle, RESIZE_SETTLE_MS);
        self.s.settling = Some(Pending { grid, timer });
    }

    /// `DaemonTerminalSession.resize`: remembered while released or unlinked, else claimed.
    pub(super) fn give(&mut self, grid: TerminalGridSize) {
        self.s.grid = Some(grid);
        match self.s.claim {
            Claim::Released => {}
            Claim::Unsent => self.try_send(),
            Claim::AwaitingAnswer { grid: at, .. }
            | Claim::Claimed { grid: at }
            | Claim::Reclaiming { grid: at, .. }
            | Claim::HostKeeps { grid: at } => {
                if at != grid {
                    self.send(grid);
                }
            }
        }
    }

    pub(super) fn host_grid(&mut self, host: TerminalGridSize) {
        self.s.host = Some(host);
        match self.s.claim {
            Claim::Released | Claim::Unsent => {}
            Claim::AwaitingAnswer { grid, .. } => {
                // Another grid inside the window is the claim's own round trip.
                if host == grid {
                    self.cancel(Timer::Answer);
                    self.s.claim = Claim::Claimed { grid };
                }
            }
            Claim::Claimed { grid } => {
                if host != grid {
                    // `claimAgain`: a grid the phone did not ask for, on screen.
                    if self.mode == Mode::KeepHostSize {
                        self.release();
                        return;
                    }
                    self.fx.push(Effect::SendResize { grid });
                    let asked = self.start(Timer::Reclaim, RECLAIM_WAIT_MS);
                    self.s.claim = Claim::Reclaiming { grid, asked };
                }
            }
            Claim::Reclaiming { grid, .. } => {
                if host == grid {
                    self.cancel(Timer::Reclaim);
                    self.s.claim = Claim::Claimed { grid };
                }
            }
            Claim::HostKeeps { grid } => {
                if host == grid {
                    self.s.claim = Claim::Claimed { grid };
                }
            }
        }
    }

    /// A timer the state runs under its generation fired.
    pub(super) fn fired(&mut self, timer: Timer) {
        match timer {
            Timer::Release => {
                self.s.release_timer = None;
                self.release();
            }
            Timer::Settle => {
                if let Some(pending) = self.s.settling.take() {
                    self.give(pending.grid);
                }
            }
            Timer::Answer | Timer::Reclaim => match self.s.claim {
                Claim::AwaitingAnswer { grid, .. } | Claim::Reclaiming { grid, .. } => {
                    let answered = self.s.host.is_none_or(|host| host == grid);
                    self.s.claim =
                        if answered { Claim::Claimed { grid } } else { Claim::HostKeeps { grid } };
                }
                Claim::Released
                | Claim::Unsent
                | Claim::Claimed { .. }
                | Claim::HostKeeps { .. } => {}
            },
            Timer::Lease => {
                self.s.lease_timer = None;
                match self.s.claim.at_mac() {
                    Some(_) if self.mode == Mode::KeepHostSize => self.release(),
                    Some(grid) => {
                        self.fx.push(Effect::RefreshLease { grid });
                        self.ensure_lease();
                    }
                    None => {}
                }
            }
        }
    }
}
