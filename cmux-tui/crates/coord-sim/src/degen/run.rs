//! RUN_DIR: the raw sample files and the verdict (format in `degen.rs`).

use serde_json::{Value, json};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

#[derive(Clone)]
pub struct Sink(Arc<Mutex<BufWriter<File>>>);

impl Sink {
    fn create(path: &Path) -> Result<Sink, String> {
        let f = File::create(path).map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(Sink(Arc::new(Mutex::new(BufWriter::new(f)))))
    }

    pub fn write(&self, v: &Value) {
        let mut w = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let _ = writeln!(w, "{v}");
    }

    pub fn flush(&self) {
        let _ = self.0.lock().unwrap_or_else(|e| e.into_inner()).flush();
    }
}

/// One case's RUN_DIR and its clock.
#[derive(Clone)]
pub struct Run {
    pub dir: PathBuf,
    pub t0: Instant,
    pub events: Sink,
    pub ops: Sink,
    pub procs: Sink,
}

impl Run {
    pub fn create(dir: &Path) -> Result<Run, String> {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        Ok(Run {
            dir: dir.to_path_buf(),
            t0: Instant::now(),
            events: Sink::create(&dir.join("events.ndjson"))?,
            ops: Sink::create(&dir.join("ops.ndjson"))?,
            procs: Sink::create(&dir.join("proc.ndjson"))?,
        })
    }

    pub fn t_ms(&self) -> f64 {
        self.t0.elapsed().as_secs_f64() * 1000.0
    }

    /// One `ops.ndjson` line: `op`, `ms`, `ok` and `extra`'s fields.
    pub fn op(&self, op: &str, ms: f64, ok: bool, extra: Value) {
        let mut v = json!({"t_ms": round(self.t_ms()), "op": op, "ms": round(ms), "ok": ok});
        if let (Some(o), Value::Object(e)) = (v.as_object_mut(), extra) {
            o.extend(e);
        }
        self.ops.write(&v);
    }

    /// Writes verdict.json and the VERDICT line; a failing verdict is the command's error.
    pub fn finish(&self, verdict: &Verdict) -> Result<(), String> {
        for s in [&self.events, &self.ops, &self.procs] {
            s.flush();
        }
        let v = verdict.json();
        let text = serde_json::to_string_pretty(&v).map_err(|e| e.to_string())?;
        std::fs::write(self.dir.join("verdict.json"), text).map_err(|e| e.to_string())?;
        let line = verdict.line();
        println!("{line}");
        if verdict.pass() { Ok(()) } else { Err(line) }
    }
}

pub fn round(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}

pub struct Check {
    name: String,
    pass: bool,
    value: Value,
    bound: String,
}

/// The invariants a case checked and the numbers it measured.
pub struct Verdict {
    case: String,
    checks: Vec<Check>,
    pub numbers: serde_json::Map<String, Value>,
}

impl Verdict {
    pub fn new(case: &str) -> Verdict {
        Verdict { case: case.to_owned(), checks: Vec::new(), numbers: serde_json::Map::new() }
    }

    pub fn check(&mut self, name: &str, pass: bool, value: impl Into<Value>, bound: &str) {
        self.checks.push(Check {
            name: name.into(),
            pass,
            value: value.into(),
            bound: bound.into(),
        });
    }

    /// `value <= bound`, the bound named in the check.
    pub fn at_most(&mut self, name: &str, value: f64, bound: f64) {
        self.check(name, value <= bound, round(value), &format!("<= {bound}"));
    }

    pub fn num(&mut self, name: &str, v: impl Into<Value>) {
        self.numbers.insert(name.into(), v.into());
    }

    pub fn pass(&self) -> bool {
        !self.checks.is_empty() && self.checks.iter().all(|c| c.pass)
    }

    fn json(&self) -> Value {
        let inv: Vec<Value> = self
            .checks
            .iter()
            .map(|c| json!({"name": c.name, "pass": c.pass, "value": c.value, "bound": c.bound}))
            .collect();
        json!({"schema": "coord-sim-degen.v1", "case": self.case, "pass": self.pass(), "invariants": inv, "numbers": self.numbers})
    }

    fn line(&self) -> String {
        let parts: Vec<String> = self
            .checks
            .iter()
            .map(|c| format!("{}{}={}", if c.pass { "" } else { "!" }, c.name, c.value))
            .collect();
        format!(
            "VERDICT {} {} {}",
            self.case,
            if self.pass() { "PASS" } else { "FAIL" },
            parts.join(" ")
        )
    }
}
