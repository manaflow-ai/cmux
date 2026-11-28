//! The bench's measure clock for the freeing timer (`--measure-freeing-clock-fifo`).

/// `--measure-freeing-clock-fifo` (the bench, `scripts/measure/infinite-items.py`): a thread
/// blocked on reading the FIFO (no wakeup while nothing is written); each line holds the seconds
/// to let pass for the freeing timer (`Mux::advance_freeing_clock`).
#[cfg(unix)]
pub(crate) fn start_measure_freeing_clock(
    mux: &std::sync::Arc<cmux_tui_core::Mux>,
    fifo: &std::path::Path,
) -> anyhow::Result<()> {
    use std::io::BufRead;
    use std::os::unix::fs::FileTypeExt;
    let kind = std::fs::metadata(fifo)
        .map_err(|error| {
            anyhow::anyhow!("--measure-freeing-clock-fifo {}: {error}", fifo.display())
        })?
        .file_type();
    if !kind.is_fifo() {
        anyhow::bail!("--measure-freeing-clock-fifo {}: not a FIFO", fifo.display());
    }
    let mux = std::sync::Arc::downgrade(mux);
    let fifo = fifo.to_path_buf();
    eprintln!("cmux-tui: measure freeing clock on ({})", fifo.display());
    std::thread::Builder::new().name("measure-clock".into()).spawn(move || {
        loop {
            // Blocks until a writer opens it; its lines end at the writer's close.
            let Ok(file) = std::fs::File::open(&fifo) else { return };
            for line in std::io::BufReader::new(file).lines() {
                let Ok(line) = line else { break };
                let Some(owner) = mux.upgrade() else { return };
                match line.trim().parse::<u64>() {
                    Ok(seconds) => {
                        owner.advance_freeing_clock(std::time::Duration::from_secs(seconds))
                    }
                    Err(_) => eprintln!("cmux-tui: measure freeing clock: not seconds: {line:?}"),
                }
            }
        }
    })?;
    Ok(())
}

#[cfg(not(unix))]
pub(crate) fn start_measure_freeing_clock(
    _mux: &std::sync::Arc<cmux_tui_core::Mux>,
    _fifo: &std::path::Path,
) -> anyhow::Result<()> {
    anyhow::bail!("--measure-freeing-clock-fifo needs a Unix FIFO")
}
