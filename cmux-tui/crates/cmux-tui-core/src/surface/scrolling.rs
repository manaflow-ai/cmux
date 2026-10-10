//! Scrollback operations on `Surface`: shared and per-view scroll deltas,
//! scrollbar reads, and scroll-to-bottom with scroll events to the mux.

use super::*;

impl Surface {
    pub fn scroll_delta(&self, delta: isize) -> anyhow::Result<()> {
        let _ = self.apply_scroll_delta(None, delta)?;
        Ok(())
    }

    /// Scroll only this placement's in-process frontend viewport. Byte-mode
    /// frontends own the equivalent state in their terminal mirror.
    pub fn view_scroll_delta(&self, delta: isize) -> anyhow::Result<Option<Scrollbar>> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let mut term = pty.term.lock().unwrap();
        let Some(scrollbar) = pty.view_scrollbar_locked(&mut term) else { return Ok(None) };
        let target = if delta < 0 {
            scrollbar.offset.saturating_sub(delta.unsigned_abs() as u64)
        } else {
            scrollbar.offset.saturating_add(delta as u64)
        }
        .min(scrollbar.total.saturating_sub(scrollbar.len));
        if target == scrollbar.offset {
            return Ok(Some(scrollbar));
        }
        pty.set_view_scroll_offset_locked(&mut term, target);
        Ok(Some(Scrollbar { offset: target, ..scrollbar }))
    }

    pub fn view_scroll_delta_if_scrollbar(
        &self,
        expected: Scrollbar,
        delta: isize,
    ) -> anyhow::Result<Option<Scrollbar>> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let mut term = pty.term.lock().unwrap();
        let Some(scrollbar) = pty.view_scrollbar_locked(&mut term) else { return Ok(None) };
        if scrollbar != expected {
            return Ok(None);
        }
        let target = if delta < 0 {
            scrollbar.offset.saturating_sub(delta.unsigned_abs() as u64)
        } else {
            scrollbar.offset.saturating_add(delta as u64)
        }
        .min(scrollbar.total.saturating_sub(scrollbar.len));
        pty.set_view_scroll_offset_locked(&mut term, target);
        Ok(Some(Scrollbar { offset: target, ..scrollbar }))
    }

    pub fn view_scrollbar(&self) -> Option<Scrollbar> {
        let pty = self.as_pty()?;
        let mut term = pty.term.lock().unwrap();
        pty.view_scrollbar_locked(&mut term)
    }

    pub fn view_scroll_to_bottom(&self) -> anyhow::Result<bool> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let mut term = pty.term.lock().unwrap();
        let Some(scrollbar) = pty.view_scrollbar_locked(&mut term) else { return Ok(false) };
        let bottom = scrollbar.total.saturating_sub(scrollbar.len);
        let changed = scrollbar.offset != bottom;
        pty.set_view_scroll_offset_locked(&mut term, bottom);
        Ok(changed)
    }

    /// Apply a scroll only while the terminal still matches the rendered
    /// scrollbar geometry that admitted the pointer gesture.
    pub fn scroll_delta_if_scrollbar(
        &self,
        expected: Scrollbar,
        delta: isize,
    ) -> anyhow::Result<Option<Scrollbar>> {
        self.apply_scroll_delta(Some(expected), delta)
    }

    pub(super) fn apply_scroll_delta(
        &self,
        expected: Option<Scrollbar>,
        delta: isize,
    ) -> anyhow::Result<Option<Scrollbar>> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let (scrollbar, changed) = {
            let mut term = pty.term.lock().unwrap();
            if expected.is_some_and(|expected| term.scrollbar() != Some(expected)) {
                return Ok(None);
            }
            let before = terminal_scroll_position(&term);
            term.scroll_delta(delta);
            let after = terminal_scroll_position(&term);
            let changed = if before == after {
                None
            } else {
                broadcast_render_scroll_locked(pty, after);
                let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
                let _ = pty.build_frame_locked(&mut term, generation, false);
                Some(after)
            };
            (term.scrollbar(), changed)
        };
        if let Some((offset, at_bottom)) = changed
            && let Some(mux) = pty.mux.upgrade()
        {
            mux.emit_terminal_scroll(pty.event_surface_id, offset, at_bottom);
        }
        Ok(scrollbar)
    }

    pub fn scroll_to_bottom(&self) -> anyhow::Result<()> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let changed = {
            let mut term = pty.term.lock().unwrap();
            let before = terminal_scroll_position(&term);
            term.scroll_to_bottom();
            let after = terminal_scroll_position(&term);
            if before == after {
                None
            } else {
                broadcast_render_scroll_locked(pty, after);
                let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
                let _ = pty.build_frame_locked(&mut term, generation, false);
                Some(after)
            }
        };
        if let Some((offset, at_bottom)) = changed
            && let Some(mux) = pty.mux.upgrade()
        {
            mux.emit_terminal_scroll(pty.event_surface_id, offset, at_bottom);
        }
        Ok(())
    }
}

pub(super) fn broadcast_render_scroll_locked(pty: &PtySurface, position: (u64, bool)) {
    let (offset, at_bottom) = position;
    let mut render = pty.render.lock().unwrap();
    render.taps.retain(|tap| tap.send(RenderAttachFrame::ScrollChanged { offset, at_bottom }));
}

pub(super) fn terminal_scroll_position(term: &Terminal) -> (u64, bool) {
    match term.scrollbar() {
        Some(scrollbar) => (scrollbar.offset, !scrollbar.scrolled_back()),
        None => (0, true),
    }
}

pub(super) fn set_terminal_scroll_offset(term: &mut Terminal, target: u64) -> bool {
    let Some(scrollbar) = term.scrollbar() else { return target == 0 };
    let bottom = scrollbar.total.saturating_sub(scrollbar.len);
    let target = target.min(bottom);
    if target == bottom {
        term.scroll_to_bottom();
        return term.scrollbar().is_some_and(|scrollbar| scrollbar.offset == target);
    }
    let mut current = scrollbar.offset;
    let mut remaining = current.abs_diff(target);
    while current != target {
        let difference = i128::from(target) - i128::from(current);
        let step = difference.clamp(isize::MIN as i128, isize::MAX as i128) as isize;
        term.scroll_delta(step);
        let Some(next) = term.scrollbar().map(|scrollbar| scrollbar.offset) else { return false };
        let next_remaining = next.abs_diff(target);
        if next_remaining >= remaining {
            return false;
        }
        current = next;
        remaining = next_remaining;
    }
    true
}
