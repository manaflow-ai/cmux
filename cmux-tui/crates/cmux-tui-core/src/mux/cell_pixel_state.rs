//! Cell pixel update state: retry timing, public update results, completion tracking, test hooks, pending operations and the retry queue, and the bounded apply and convergence checks.

use super::*;

pub(super) const CELL_PIXEL_RETRY_INITIAL: Duration = Duration::from_millis(25);

pub(super) const CELL_PIXEL_RETRY_MAX: Duration = Duration::from_millis(250);

pub(super) const CELL_PIXEL_RETRY_MAX_ATTEMPTS: u8 = 4;

pub(super) fn cell_pixel_retry_delay(attempts: u8) -> Duration {
    let multiplier = 1_u32.checked_shl(u32::from(attempts.saturating_sub(1))).unwrap_or(u32::MAX);
    CELL_PIXEL_RETRY_INITIAL.saturating_mul(multiplier).min(CELL_PIXEL_RETRY_MAX)
}

#[derive(Debug, Default)]
pub struct CellPixelUpdate {
    pub resizes: Vec<(SurfaceId, (u16, u16), u64)>,
    pub failures: Vec<CellPixelUpdateFailure>,
}

#[derive(Debug)]
pub struct CellPixelUpdateFailure {
    pub surface: SurfaceId,
    pub error: String,
    pub deferred: bool,
}

#[derive(Debug)]
pub(super) struct PendingCellPixelUpdate {
    pub(super) generation: u64,
    pub(super) target: (u16, u16),
    pub(super) failures: HashSet<SurfaceId>,
    pub(super) use_for_creation: bool,
}

pub(super) struct CellPixelCompletionTracker {
    pub(super) generation: u64,
    pub(super) target: (u16, u16),
    pub(super) publishing: AtomicBool,
    pub(super) completed: Mutex<HashSet<SurfaceId>>,
}

#[cfg(test)]
pub(super) type CellPixelBeforePublishHook = Arc<dyn Fn((u16, u16)) + Send + Sync>;

#[cfg(test)]
pub(super) type CellPixelOperationHook =
    Arc<dyn Fn(&Arc<Surface>, (u16, u16), Instant) -> anyhow::Result<Option<u64>> + Send + Sync>;

#[cfg(test)]
pub(super) type KittyImageBudgetOperationHook =
    Arc<dyn Fn(&Arc<Surface>, KittyGraphicsLimits, Instant) -> anyhow::Result<()> + Send + Sync>;

#[cfg(test)]
pub(super) type TerminalSpawnAfterCellPixelSnapshotHook = Arc<dyn Fn(bool) + Send + Sync>;

#[cfg(test)]
pub(super) type TerminalSpawnBeforeCellPixelReconcileHook =
    Arc<dyn Fn(&Arc<Surface>) + Send + Sync>;

pub(super) type CellPixelSurfaceResult = (SurfaceId, (u16, u16), anyhow::Result<Option<u64>>, bool);

pub(super) struct PendingCellPixelOperation {
    pub(super) surface: Weak<Surface>,
    pub(super) result: DeadlinePending<CellPixelSurfaceResult>,
}

pub(super) struct CellPixelRetryTask {
    pub(super) surfaces: Vec<Weak<Surface>>,
    pub(super) pending: Vec<PendingCellPixelOperation>,
    pub(super) attempts: u8,
    pub(super) generation: u64,
    pub(super) target: (u16, u16),
    pub(super) completion: Arc<CellPixelCompletionTracker>,
    pub(super) report: SurfaceResizeReporter,
    pub(super) timeout: Duration,
    #[cfg(test)]
    pub(super) operation_hook: Option<CellPixelOperationHook>,
}

#[derive(Default)]
pub(super) struct CellPixelRetryQueue {
    pub(super) pending: Option<CellPixelRetryTask>,
    pub(super) worker_running: bool,
}

pub(super) fn apply_cell_pixel_size_until(
    surface: &Arc<Surface>,
    target: (u16, u16),
    deadline: Instant,
    report: &SurfaceResizeReporter,
    #[cfg(test)] operation_hook: Option<&CellPixelOperationHook>,
) -> CellPixelSurfaceResult {
    let id = surface.id;
    let size = surface.size();
    let callback = report.clone();
    #[cfg(test)]
    if let Some(hook) = operation_hook {
        let result =
            validate_cell_pixel_convergence(surface, target, hook(surface, target, deadline));
        callback(id, size, result.as_ref().ok().copied().flatten());
        let deferred = result.as_ref().err().is_some_and(|error| {
            error.downcast_ref::<crate::terminal_host_runtime::DeferredCellPixelAck>().is_some()
        });
        return (id, size, result, deferred);
    }
    let result = validate_cell_pixel_convergence(
        surface,
        target,
        surface.set_cell_pixel_size_reporting_until(
            target.0,
            target.1,
            deadline,
            Box::new(move |accepted| callback(id, size, accepted)),
        ),
    );
    let deferred = result.as_ref().err().is_some_and(|error| {
        error.downcast_ref::<crate::terminal_host_runtime::DeferredCellPixelAck>().is_some()
    });
    (id, size, result, deferred)
}

pub(super) fn validate_cell_pixel_convergence(
    surface: &Surface,
    target: (u16, u16),
    result: anyhow::Result<Option<u64>>,
) -> anyhow::Result<Option<u64>> {
    let reservation = result?;
    if reservation.is_none() && surface.cell_pixel_size() != target {
        anyhow::bail!("cell pixel update did not converge to {}x{} pixels", target.0, target.1);
    }
    Ok(reservation)
}
