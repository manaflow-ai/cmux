//! Surface geometry: grid resize and cell-pixel size, with acceptance and
//! completion reporting, and the test hooks that drive the PTY master.

use super::*;

impl Surface {
    /// Resize this surface. PTYs receive cell dimensions; browsers also
    /// use the last configured cell pixel size for CDP device metrics.
    /// Returns whether a clamped size change was applied or accepted. Browser
    /// reconfiguration completes on its worker and emits the final size there.
    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        match self {
            Surface::Pty(pty) => pty.resize(cols, rows),
            Surface::Browser(browser) => browser.resize(cols, rows),
        }
    }

    /// Hosted PTYs acknowledge a resize with an authoritative replay/color
    /// pair. The mux must wait for that pair before publishing the new grid.
    pub(crate) fn resize_reports_asynchronously(&self) -> bool {
        match self {
            Surface::Pty(pty) => {
                #[cfg(any(unix, windows))]
                {
                    matches!(
                        &*pty.runtime.lock().unwrap_or_else(std::sync::PoisonError::into_inner),
                        PtyRuntime::Hosted(_)
                    )
                }
                #[cfg(not(any(unix, windows)))]
                {
                    false
                }
            }
            Surface::Browser(_) => true,
        }
    }

    pub fn resize_reporting_acceptance(
        &self,
        cols: u16,
        rows: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<Option<u64>> {
        match self {
            Surface::Pty(pty) => match pty.resize(cols, rows) {
                Ok(accepted) => {
                    report(accepted.then_some(0));
                    Ok(accepted.then_some(0))
                }
                Err(error) => {
                    report(None);
                    Err(error)
                }
            },
            Surface::Browser(browser) => browser.resize_reporting_acceptance(cols, rows, report),
        }
    }

    pub(crate) fn resize_reporting_completion(
        &self,
        cols: u16,
        rows: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
        completion: Option<BrowserResizeWaiter>,
    ) -> anyhow::Result<Option<u64>> {
        match self {
            Surface::Pty(pty) => match pty.resize(cols, rows) {
                Ok(accepted) => {
                    report(accepted.then_some(0));
                    if let Some(completion) = completion {
                        let _ = completion.send(Ok(()));
                    }
                    Ok(accepted.then_some(0))
                }
                Err(error) => {
                    report(None);
                    if let Some(completion) = completion {
                        let _ = completion.send(Err(error.to_string().into()));
                    }
                    Err(error)
                }
            },
            Surface::Browser(browser) => {
                browser.resize_reporting_completion(cols, rows, report, completion)
            }
        }
    }

    pub fn resize_needed(&self, cols: u16, rows: u16) -> bool {
        let desired = (cols.max(1), rows.max(1));
        match self {
            Surface::Pty(pty) => {
                let geometry =
                    *pty.geometry.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                (geometry.cols, geometry.rows) != desired
            }
            Surface::Browser(browser) => browser.resize_needed(desired.0, desired.1),
        }
    }

    /// Wait, at most until `deadline`, until a hosted PTY's mirror has
    /// applied every grid asked of its host. A hosted resize returns once the
    /// size is sent; the host's resize arrives later on its stream. An attach
    /// that sized the grid waits here so its replay is built at the new grid
    /// instead of being followed by a second, `resized` replay. Returns
    /// whether the mirror is settled (always for a local or idle PTY).
    pub(crate) fn settle_hosted_viewer_size(&self, deadline: Instant) -> bool {
        let Surface::Pty(pty) = self else { return true };
        #[cfg(any(unix, windows))]
        {
            // Only the request is sent under the runtime lock; the wait is not.
            let barrier =
                match &*pty.runtime.lock().unwrap_or_else(std::sync::PoisonError::into_inner) {
                    PtyRuntime::Hosted(host) => host.begin_viewer_size_barrier(),
                    _ => return true,
                };
            if let Some(acknowledged) = barrier {
                let remaining = deadline.saturating_duration_since(Instant::now());
                return acknowledged.recv_timeout(remaining).is_ok();
            }
            // A host without viewer size acknowledgements: wait for the
            // mirror to reach the size last asked.
            loop {
                let observed = pty.stream_progress.revision();
                let target =
                    match &*pty.runtime.lock().unwrap_or_else(std::sync::PoisonError::into_inner) {
                        PtyRuntime::Hosted(host) => host.viewer_size(),
                        _ => None,
                    };
                let Some(target) = target else { return true };
                let geometry =
                    *pty.geometry.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                if (geometry.cols, geometry.rows) == target {
                    return true;
                }
                if pty.stream_progress.wait_for_change_until(observed, Some(deadline)).is_none() {
                    return false;
                }
            }
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (pty, deadline);
            true
        }
    }

    pub(crate) fn pending_resize_completion(
        &self,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<Option<PendingBrowserResize>> {
        match self {
            Surface::Pty(_) => Ok(None),
            Surface::Browser(browser) => browser.pending_resize_completion(cols, rows),
        }
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> anyhow::Result<bool> {
        self.set_cell_pixel_size_reporting(width_px, height_px, Box::new(|_| {}))
            .map(|reservation_id| reservation_id.is_some())
    }

    pub fn set_cell_pixel_size_reporting(
        &self,
        width_px: u16,
        height_px: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<Option<u64>> {
        match self {
            Surface::Pty(pty) => match pty.set_cell_pixel_size(width_px, height_px) {
                Ok(changed) => {
                    report(changed.then_some(0));
                    Ok(changed.then_some(0))
                }
                Err(error) => {
                    report(None);
                    Err(error)
                }
            },
            Surface::Browser(browser) => {
                browser.set_cell_pixel_size_reporting(width_px, height_px, report)
            }
        }
    }

    pub(crate) fn set_cell_pixel_size_reporting_until(
        &self,
        width_px: u16,
        height_px: u16,
        deadline: Instant,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<Option<u64>> {
        match self {
            Surface::Pty(pty) => {
                match pty.set_cell_pixel_size_until(width_px, height_px, Some(deadline)) {
                    Ok(changed) => {
                        report(changed.then_some(0));
                        Ok(changed.then_some(0))
                    }
                    Err(error) => {
                        report(None);
                        Err(error)
                    }
                }
            }
            Surface::Browser(browser) => {
                browser.set_cell_pixel_size_reporting(width_px, height_px, report)
            }
        }
    }

    pub fn size(&self) -> (u16, u16) {
        match self {
            Surface::Pty(pty) => {
                let geometry =
                    *pty.geometry.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                (geometry.cols, geometry.rows)
            }
            Surface::Browser(browser) => browser.size(),
        }
    }

    /// The grid size this daemon last asked for. For a hosted terminal this
    /// is the viewer size sent to the host, which can be ahead of the mirror
    /// in [`Self::size`] until the host publishes `Resized`.
    pub(crate) fn requested_size(&self) -> (u16, u16) {
        #[cfg(any(unix, windows))]
        if let Surface::Pty(pty) = self
            && let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap()
            && let Some(size) = host.viewer_size()
        {
            return size;
        }
        self.size()
    }

    pub(crate) fn cell_pixel_size(&self) -> (u16, u16) {
        match self {
            Surface::Pty(pty) => {
                let geometry =
                    *pty.geometry.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                (geometry.cell_width, geometry.cell_height)
            }
            Surface::Browser(browser) => browser.cell_pixel_size(),
        }
    }

    #[cfg(test)]
    pub(crate) fn fail_next_test_master_resize(&self) {
        self.as_pty()
            .and_then(|pty| pty.test_master_control.as_ref())
            .expect("test PTY surface")
            .fail_next_resize
            .store(true, Ordering::Release);
    }

    #[cfg(test)]
    pub(crate) fn test_master_size(&self) -> PtySize {
        let runtime = self.as_pty().expect("test PTY surface").runtime.lock().unwrap();
        let PtyRuntime::Local { master, .. } = &*runtime else {
            panic!("test PTY surface uses a local runtime");
        };
        master.as_deref().expect("test PTY master is open").get_size().unwrap()
    }

    #[cfg(test)]
    pub(crate) fn test_cell_pixel_size(&self) -> (u16, u16) {
        let geometry = *self.as_pty().expect("test PTY surface").geometry.lock().unwrap();
        (geometry.cell_width, geometry.cell_height)
    }

    /// Stop the daemon's durable hosted-terminal mirror from constraining the
    /// host grid when the mux has no size-participating viewer for this
    /// surface. A later viewer report re-registers through `resize`.
    pub(crate) fn release_viewer_size(&self) -> anyhow::Result<bool> {
        let Surface::Pty(pty) = self else { return Ok(false) };
        #[cfg(any(unix, windows))]
        {
            let runtime = pty.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                return Ok(host.release_viewer_size()?);
            }
        }
        Ok(false)
    }
}
