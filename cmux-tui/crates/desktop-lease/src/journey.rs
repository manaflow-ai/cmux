//! `desktop-lease journey`: a scripted computer-use agent. It speaks MCP to
//! `desktop-lease mcp` exactly as a session does (lease, act, release),
//! "thinks" between steps so the pool suspends the slot, checks each step's
//! screenshot by OCR (tesseract) for the text it expects, and writes
//! `results.json` (the first-user-journey results shape, plus timings),
//! `summary.md` and one PNG per step.

use crate::at;
use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use cmux_process::{Child, Command, Stdio};
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, ChildStdout};
use std::time::{Duration, Instant};

#[derive(Deserialize)]
pub struct Script {
    pub name: String,
    /// The journey's cell id in results.json (`web/onboarding-agents`).
    pub cell: String,
    #[serde(default)]
    pub lease: Value,
    /// The model's think time between steps, while the slot is suspended.
    #[serde(default = "think")]
    pub think_ms: u64,
    pub steps: Vec<Step>,
}

fn think() -> u64 {
    2000
}

#[derive(Deserialize)]
pub struct Step {
    pub name: String,
    pub tool: String,
    #[serde(default)]
    pub args: Value,
    /// Text the screenshot must show (OCR, case and spacing ignored).
    #[serde(default)]
    pub expect_text: Vec<String>,
}

struct Mcp {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next: u64,
}

impl Mcp {
    fn start(exe: &Path, socket: &Path, owner: &str) -> Result<Self> {
        let mut child = Command::new(exe)
            .args(["mcp", "--socket"])
            .arg(socket)
            .env(crate::mcp::OWNER_ENV, owner)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .context("desktop-lease mcp")?;
        let stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
        let stdout = BufReader::new(child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?);
        let mut mcp = Mcp { child, stdin, stdout, next: 1 };
        mcp.request(
            "initialize",
            json!({"protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "desktop-lease-journey", "version": "0"}}),
        )?;
        writeln!(
            mcp.stdin,
            "{}",
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"})
        )?;
        Ok(mcp)
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.next;
        self.next += 1;
        writeln!(
            self.stdin,
            "{}",
            json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
        )?;
        self.stdin.flush()?;
        let mut line = String::new();
        if self.stdout.read_line(&mut line)? == 0 {
            bail!("the MCP server closed");
        }
        let v: Value = serde_json::from_str(&line)?;
        if let Some(e) = v.get("error") {
            bail!("{method}: {e}");
        }
        Ok(at(&v, "/result").clone())
    }

    fn tool(&mut self, name: &str, args: Value) -> Result<(Value, Option<Vec<u8>>)> {
        let r = self.request("tools/call", json!({"name": name, "arguments": args}))?;
        let content = at(&r, "/content").as_array().cloned().unwrap_or_default();
        let text =
            content.iter().find(|c| at(c, "/type") == "text").and_then(|c| at(c, "/text").as_str());
        if at(&r, "/isError").as_bool() == Some(true) {
            bail!("{name}: {}", text.unwrap_or("error"));
        }
        let report = text.and_then(|t| serde_json::from_str(t).ok()).unwrap_or(Value::Null);
        let png = content
            .iter()
            .find(|c| at(c, "/type") == "image")
            .and_then(|c| at(c, "/data").as_str())
            .and_then(|d| base64::engine::general_purpose::STANDARD.decode(d).ok());
        Ok((report, png))
    }
}

impl Drop for Mcp {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn ocr(png: &Path) -> String {
    let read = |p: &Path| {
        Command::new("tesseract")
            .arg(p)
            .arg("stdout")
            .stderr(Stdio::null())
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default()
    };
    // Upscaled 2x (small grey text), and its negative (light text on dark buttons).
    let mut text = String::new();
    for (suffix, negate) in [("ocr.png", false), ("ocr-neg.png", true)] {
        let scaled = png.with_extension(suffix);
        let mut convert = Command::new("convert");
        convert.arg(png).args(["-resize", "200%"]);
        if negate {
            convert.arg("-negate");
        }
        if convert.arg(&scaled).status().is_ok_and(|s| s.success()) {
            text.push_str(&read(&scaled));
            text.push('\n');
            let _ = std::fs::remove_file(&scaled);
        } else if !negate {
            text.push_str(&read(png));
        }
    }
    text
}

fn squash(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

pub fn run(script_path: &Path, out: &Path, socket: &Path) -> Result<Value> {
    let script: Script = serde_json::from_str(&std::fs::read_to_string(script_path)?)
        .with_context(|| format!("journey script {}", script_path.display()))?;
    std::fs::create_dir_all(out)?;
    let exe = std::env::current_exe()?;
    let owner = format!("journey-{}", std::process::id());
    let mut mcp = Mcp::start(&exe, socket, &owner)?;
    let mut pool = crate::server::Client::connect(socket)?;

    let t = Instant::now();
    let (lease, _) = mcp.tool("desktop_lease", script.lease.clone())?;
    let lease_wall_ms = t.elapsed().as_secs_f64() * 1000.0;
    let slot =
        at(&lease, "/slot").as_str().ok_or_else(|| anyhow!("no slot in {lease}"))?.to_owned();

    let mut steps = Vec::new();
    let mut reds = Vec::new();
    for (i, step) in script.steps.iter().enumerate() {
        // The model thinks: the pool has suspended the slot by now; read what it holds.
        std::thread::sleep(Duration::from_millis(script.think_ms));
        let observed = pool.call(&json!({"op": "stats"}))?;
        let during_think = at(&observed, "/stats/slots")
            .as_array()
            .and_then(|s| {
                s.iter().find(|r| at(r, "/slot").as_str() == Some(slot.as_str())).cloned()
            })
            .unwrap_or(Value::Null);
        let mut args = step.args.clone();
        if args.is_null() {
            args = json!({});
        }
        args.as_object_mut()
            .ok_or_else(|| anyhow!("step {} args are not an object", step.name))?
            .insert("slot".to_owned(), json!(slot));
        let t = Instant::now();
        let called = mcp.tool(&step.tool, args);
        let wall_ms = t.elapsed().as_secs_f64() * 1000.0;
        let shot = PathBuf::from(format!("step-{:02}.png", i + 1));
        let mut seen = String::new();
        let (report, missing, error) = match called {
            Ok((report, png)) => {
                if let Some(png) = png {
                    std::fs::write(out.join(&shot), png)?;
                }
                seen = ocr(&out.join(&shot));
                let text = squash(&seen);
                let missing: Vec<_> = step
                    .expect_text
                    .iter()
                    .filter(|e| !text.contains(&squash(e)))
                    .cloned()
                    .collect();
                (report, missing, None)
            }
            Err(e) => (Value::Null, step.expect_text.clone(), Some(format!("{e:#}"))),
        };
        let pass = error.is_none() && missing.is_empty();
        if !pass {
            reds.push(json!({
                "rule": if error.is_some() { "crash" } else { "layout-break" },
                "where": script.cell,
                "step": step.name,
                "detail": error.clone().unwrap_or_else(|| format!("screenshot does not show {missing:?}")),
                "screenshot": shot,
            }));
        }
        eprintln!(
            "step {:>2} {:<4} {} (was {}, resume {:.1} ms, total {:.0} ms)",
            i + 1,
            if pass { "pass" } else { "RED" },
            step.name,
            at(&report, "/was").as_str().unwrap_or("?"),
            at(&report, "/resume_ms").as_f64().unwrap_or(0.0),
            wall_ms
        );
        steps.push(json!({
            "step": i + 1, "name": step.name, "tool": step.tool, "pass": pass,
            "missing_text": missing, "error": error, "ocr": seen.split_whitespace().collect::<Vec<_>>().join(" "), "screenshot": shot,
            "wall_ms": wall_ms, "report": report, "during_think": during_think,
        }));
    }
    let t = Instant::now();
    mcp.tool("desktop_release", json!({"slot": slot}))?;
    let release_ms = t.elapsed().as_secs_f64() * 1000.0;

    let passed = steps.iter().filter(|s| at(s, "/pass").as_bool() == Some(true)).count();
    let results = json!({
        "schema": 1,
        "surface": "web",
        "generated_at": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs(),
        "build": std::env::var("JOURNEY_BUILD").unwrap_or_default(),
        "run_url": null,
        "cells": [{
            "cell": script.cell, "harness": null, "state": null,
            "outcome": if reds.is_empty() { "pass" } else { "red" },
            "steps": steps.len(), "reds": reds,
        }],
        "missing_accounts": [],
        "desktop_lease": {
            "journey": script.name, "slot": slot, "lease": lease, "lease_wall_ms": lease_wall_ms,
            "release_ms": release_ms, "think_ms": script.think_ms,
            "steps_passed": passed, "steps": steps,
        },
    });
    std::fs::write(out.join("results.json"), serde_json::to_string_pretty(&results)?)?;
    std::fs::write(out.join("summary.md"), summary(&results))?;
    Ok(results)
}

fn summary(r: &Value) -> String {
    let d = at(r, "/desktop_lease");
    let mut s = format!(
        "# {}\n\nslot {} leased in {:.2} ms (warm: {}), released in {:.1} ms; {} of {} steps passed.\n\n\
         | # | step | pass | was | resume ms | act+shot ms | awake MB | think: state, MB | suspend ms (freeze+reclaim) |\n\
         |---|---|---|---|---|---|---|---|---|\n",
        at(d, "/journey").as_str().unwrap_or(""),
        at(d, "/slot").as_str().unwrap_or(""),
        at(d, "/lease/lease_ms").as_f64().unwrap_or(0.0),
        at(d, "/lease/from_warm"),
        at(d, "/release_ms").as_f64().unwrap_or(0.0),
        at(d, "/steps_passed"),
        at(d, "/steps").as_array().map_or(0, Vec::len),
    );
    for st in at(d, "/steps").as_array().into_iter().flatten() {
        let rep = at(st, "/report");
        let sus = at(rep, "/last_suspend");
        s += &format!(
            "| {} | {} | {} | {} | {:.1} | {:.0} | {:.0} | {} {:.0} | {} |\n",
            at(st, "/step"),
            at(st, "/name").as_str().unwrap_or(""),
            if at(st, "/pass").as_bool() == Some(true) { "pass" } else { "RED" },
            at(rep, "/was").as_str().unwrap_or("?"),
            at(rep, "/resume_ms").as_f64().unwrap_or(0.0),
            at(rep, "/act_ms").as_f64().unwrap_or(0.0)
                + at(rep, "/screenshot_ms").as_f64().unwrap_or(0.0),
            at(rep, "/resident_awake_mb").as_f64().unwrap_or(0.0),
            at(st, "/during_think/state").as_str().unwrap_or("?"),
            at(st, "/during_think/resident_mb").as_f64().unwrap_or(0.0),
            if sus.is_null() {
                "-".to_owned()
            } else {
                format!(
                    "{:.0}+{:.0} ({:.0} -> {:.0} MB)",
                    at(sus, "/freeze_ms").as_f64().unwrap_or(0.0),
                    at(sus, "/reclaim_ms").as_f64().unwrap_or(0.0),
                    at(sus, "/resident_before_mb").as_f64().unwrap_or(0.0),
                    at(sus, "/resident_after_mb").as_f64().unwrap_or(0.0)
                )
            },
        );
    }
    s
}
