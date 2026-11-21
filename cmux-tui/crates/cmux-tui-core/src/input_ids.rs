//! Recent identified sends for one terminal. Like cmux-remote's PTY write records,
//! a retry distinguishes an accepted write from one that might have applied a prefix.
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Mutex};

const WINDOW: usize = 1000;
pub(crate) const MAX_ID_BYTES: usize = 128;

/// A PTY write started and its result does not establish how many bytes arrived.
#[derive(Debug)]
pub(crate) struct UncertainWrite;

impl std::fmt::Display for UncertainWrite {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("terminal input may have been partially written")
    }
}

#[derive(Clone, Copy)]
enum Outcome {
    Written,
    Uncertain,
}

#[derive(Default)]
struct Recent {
    outcomes: BTreeMap<Arc<str>, Outcome>,
    order: VecDeque<Arc<str>>,
}

#[derive(Default)]
pub(crate) struct InputIds(Mutex<Recent>);

impl InputIds {
    /// Serialize identified sends to this terminal through their write result. A retry
    /// arriving on a second connection cannot acknowledge an unfinished first write.
    pub(crate) fn run(
        &self,
        id: &str,
        action: impl FnOnce() -> anyhow::Result<()>,
    ) -> anyhow::Result<bool> {
        let mut recent = self.0.lock().map_err(|_| {
            anyhow::anyhow!("terminal input window unavailable").context(UncertainWrite)
        })?;
        match recent.outcomes.get(id) {
            Some(Outcome::Written) => return Ok(true),
            Some(Outcome::Uncertain) => return Err(anyhow::Error::msg(UncertainWrite)),
            None => {}
        }
        let result = action();
        let outcome = match &result {
            Ok(()) => Outcome::Written,
            Err(error) if error.is::<UncertainWrite>() => Outcome::Uncertain,
            Err(_) => return result.map(|()| false),
        };
        if recent.order.len() == WINDOW
            && let Some(oldest) = recent.order.pop_front()
        {
            recent.outcomes.remove(&oldest);
        }
        let id: Arc<str> = Arc::from(id);
        recent.outcomes.insert(id.clone(), outcome);
        recent.order.push_back(id);
        result.map(|()| false)
    }
}

/// A refusal of the first frame before admission is safe to retry. Once a prefix of
/// this logical batch succeeded, even a definite refusal of the next frame is ambiguous.
pub(crate) fn write_error(error: anyhow::Error, wrote_prefix: bool) -> anyhow::Error {
    if !wrote_prefix
        && error.downcast_ref::<std::io::Error>().is_some_and(crate::surface::input_not_written)
    {
        error
    } else {
        error.context(UncertainWrite)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn send_input_id_window_bounds_retained_entries_and_id_bytes() {
        let ids = InputIds::default();
        for n in 1..=100_000 {
            assert!(!ids.run(&format!("{n:0128}"), || Ok(())).unwrap());
            if n == 1_000 || n == 100_000 {
                let recent = ids.0.lock().unwrap();
                let bytes: usize = recent.outcomes.keys().map(|id| id.len()).sum();
                assert_eq!(
                    (recent.outcomes.len(), recent.order.len(), bytes),
                    (1000, 1000, 128_000)
                );
                let scale = if n == 1_000 { "1x" } else { "100x" };
                for (metric, value) in
                    [("retained_ids", recent.order.len()), ("retained_id_bytes", bytes)]
                {
                    println!(
                        "after NETCOND {}",
                        serde_json::json!({"surface":"terminal", "profile":"recent-input-ids@1", "phase":"warm", "scale":scale, "metric":metric, "value":value, "run":0, "seed":0})
                    );
                }
                eprintln!(
                    "after {n} sends: {} records, {bytes} retained ID bytes",
                    recent.outcomes.len()
                );
            }
        }
        assert!(ids.run(&format!("{:0128}", 99_001), || panic!("retained")).unwrap());
        assert!(!ids.run(&format!("{:0128}", 99_000), || Ok(())).unwrap());
    }

    #[test]
    fn send_input_id_remembers_ambiguous_writes_and_retries_refusals() {
        let ids = InputIds::default();
        assert!(ids.run("1", || anyhow::bail!("refused before write")).is_err());
        assert!(!ids.run("1", || Ok(())).unwrap());
        assert!(
            ids.run("2", || Err(anyhow::anyhow!("write failed").context(UncertainWrite))).is_err()
        );
        assert!(ids.run("2", || panic!("ambiguous write repeated")).is_err());
        assert!(!InputIds::default().run("1", || Ok(())).unwrap());
    }
}
