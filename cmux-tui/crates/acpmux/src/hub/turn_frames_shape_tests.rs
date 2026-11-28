use super::super::super::turn_shots::capture_code;
use super::*;
use std::time::Duration;

fn shape(lines: &[&str]) -> Shape {
    of_lines(lines.iter().map(|l| (*l).to_owned()).collect())
}

#[test]
fn an_outline_is_read_from_the_cells_output_and_tidied() {
    let output =
        "TURN_SHOT {\"id\":\"t1\"}\nTURN_SHAPE [\"h1  Welcome\\n back\",\"button Save\",\"   \"]\n";
    let read = parse(output).unwrap();
    assert_eq!(read.lines, vec!["h1 Welcome back", "button Save"]);
    assert_eq!(read, shape(&["h1 Welcome back", "button Save"]));
    assert!(parse("TURN_SHOT {}\n").is_none());
    // A line the REPL cut short is no outline: the frame stays pixel-only.
    assert!(parse("TURN_SHAPE [\"h1 Welc").is_none());
}

#[test]
fn an_outline_is_bounded() {
    let long = "x".repeat(LINE_CHARS * 3);
    let many: Vec<String> = (0..MAX_LINES * 2).map(|i| format!("li {i} {long}")).collect();
    let read = of_lines(many);
    assert_eq!(read.lines.len(), MAX_LINES);
    assert!(read.lines.iter().all(|l| l.chars().count() == LINE_CHARS));
}

#[test]
fn the_same_outline_hashes_the_same_and_changed_text_does_not() {
    let a = shape(&["h1 Welcome", "button Save"]);
    assert_eq!(a.hash, shape(&["h1 Welcome", "button Save"]).hash);
    assert_eq!(change(&a, &a.clone()), None);
    let b = shape(&["h1 Welcome", "button Saved"]);
    assert_ne!(a.hash, b.hash);
    assert_eq!(change(&a, &b).as_deref(), Some("+1 -1 +button Saved -button Save"));
    let c = shape(&["h1 Welcome", "button Save", "alert/div Saved!"]);
    assert_eq!(change(&a, &c).as_deref(), Some("+1 -0 +alert/div Saved!"));
    // Lines split differently are a different outline.
    assert_ne!(shape(&["a b", "c"]).hash, shape(&["a", "b c"]).hash);
    let swapped = shape(&["button Save", "h1 Welcome"]);
    assert_eq!(change(&a, &swapped).as_deref(), Some("reordered"));
}

#[test]
fn a_change_summary_is_one_short_line() {
    let old: Vec<String> = (0..50).map(|i| format!("li item number {i}")).collect();
    let new: Vec<String> = (0..50).map(|i| format!("li row number {i}")).collect();
    let summary = change(&of_lines(old), &of_lines(new)).unwrap();
    assert!(summary.starts_with("+50 -50 +li row number 0 -li item number 0"), "{summary}");
    assert!(summary.chars().count() <= SUMMARY_CHARS, "{summary}");
    assert!(summary.ends_with('…'), "{summary}");
}

#[test]
fn the_last_kept_outline_is_compared_only_within_its_turn() {
    let session = "ses_shape_last";
    kept(session, "t1", Some(shape(&["h1 A"])));
    assert_eq!(since_last(session, "t1", Some(&shape(&["h1 A"]))), None);
    assert!(since_last(session, "t1", Some(&shape(&["h1 B"]))).is_some());
    assert_eq!(since_last(session, "t2", Some(&shape(&["h1 B"]))), None);
    assert_eq!(since_last(session, "t1", None), None);
    // A frame kept with no outline (the simulator, the app's window): the next compares nothing.
    kept(session, "t1", None);
    assert_eq!(since_last(session, "t1", Some(&shape(&["h1 B"]))), None);
    kept(session, "t1", Some(shape(&["h1 A"])));
    forget(session);
    assert_eq!(since_last(session, "t1", Some(&shape(&["h1 B"]))), None);
}

#[test]
fn a_captures_outline_is_handed_over_once() {
    let out = Path::new("/tmp/acpmux-shape-test/acpmux-turn-frames.capture.png");
    stash(out, Some(shape(&["h1 A"])));
    assert_eq!(take(out), Some(shape(&["h1 A"])));
    assert_eq!(take(out), None);
    stash(out, Some(shape(&["h1 A"])));
    stash(out, None);
    assert_eq!(take(out), None);
}

/// Runs `script` with node: its stdout, or none (said) where no node is on PATH.
fn node(script: &str) -> Option<String> {
    let run = std::process::Command::new("node").arg("-e").arg(script).output().ok()?;
    let stdout = String::from_utf8_lossy(&run.stdout).into_owned();
    assert!(run.status.success(), "{stdout}{}", String::from_utf8_lossy(&run.stderr));
    Some(stdout)
}

/// The cell's tail after the picture, against stand-ins of the host's `tabs`, `screenshot` and
/// `sleep`: it prints the outline once the picture is taken, and nothing when the page's read
/// outlasts [`READ_MS`] (the stand-in `sleep` ends at once) or throws.
#[test]
fn the_cell_prints_the_outline_after_the_picture_and_never_waits_past_its_bound() {
    let ws = "1A2B3C4D-0000-4000-8000-00000000ABCD";
    let run = |evaluate: &str| {
        let cell =
            capture_code("ws_1a2b3c4d00004000800000000000abcd", Path::new("/tmp/f.png"), None)
                + &cell();
        node(&format!(
            r#"const tabs = {{
  async list() {{ return [{{ id: "preview", url: "http://127.0.0.1:5173/", active: true, state: "live", workspace: "{ws}", agentDriven: true }}]; }},
  async get(id) {{ return {{ id, evaluate: {evaluate} }}; }},
}};
async function screenshot() {{ console.log("SHOT"); }}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms === {READ_MS} ? 5 : ms));
(async () => {{
{cell}
console.log("DONE");
}})();"#
        ))
    };
    let Some(out) =
        run(r#"async (fn) => (typeof fn === "function" ? ["h1 Hi", "button Go"] : null)"#)
    else {
        eprintln!("skipped: no node on PATH");
        return;
    };
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines[0], "SHOT", "{out}");
    assert!(lines[1].starts_with("TURN_SHOT "), "{out}");
    assert_eq!(parse(&out), Some(shape(&["h1 Hi", "button Go"])), "{out}");
    assert_eq!(lines.last(), Some(&"DONE"));
    let hung = run("() => new Promise(() => {})").unwrap();
    assert!(parse(&hung).is_none() && hung.contains("TURN_SHOT ") && hung.ends_with("DONE\n"));
    let threw = run(r#"async () => { throw new Error("detached"); }"#).unwrap();
    assert!(parse(&threw).is_none() && threw.ends_with("DONE\n"), "{threw}");
}

/// The in-page outline itself, against a small stand-in DOM: elements in the viewport that say
/// something, in document order; a hidden one, one off screen, a script's text and an input's
/// typed value never.
#[test]
fn the_outline_reads_what_the_viewport_shows_and_never_a_typed_value() {
    let outline = OUTLINE
        .replace("MAX_LINES", &MAX_LINES.to_string())
        .replace("LINE_CHARS", &LINE_CHARS.to_string());
    let script = format!(
        r#"const innerWidth = 800, innerHeight = 600;
const NodeFilter = {{ SHOW_ELEMENT: 1, FILTER_ACCEPT: 1, FILTER_REJECT: 2 }};
const on = {{ width: 10, height: 10, top: 10, left: 10, bottom: 20, right: 20 }};
const el = (localName, {{ attrs = {{}}, text = "", kids = [], rect = on, visible = true, type }} = {{}}) => ({{
  nodeType: 1, localName, type, kids,
  childNodes: [...(text ? [{{ nodeType: 3, data: text }}] : []), ...kids],
  getAttribute: (n) => (n in attrs ? attrs[n] : null),
  getBoundingClientRect: () => rect,
  checkVisibility: () => visible,
}});
const body = el("body", {{ kids: [
  el("h1", {{ text: "  Welcome\n back " }}),
  el("div", {{ kids: [el("span", {{ text: "Total: 3" }})] }}),
  el("button", {{ attrs: {{ role: "tab" }}, text: "Save" }}),
  el("input", {{ type: "password", attrs: {{ placeholder: "Password", value: "hunter2" }} }}),
  el("p", {{ text: "below the fold", rect: {{ width: 10, height: 10, top: 900, left: 0, bottom: 910, right: 10 }} }}),
  el("p", {{ text: "hidden", visible: false }}),
  el("script", {{ text: "secret()" }}),
  el("svg", {{ kids: [el("text", {{ text: "chart label" }})] }}),
] }});
const document = {{
  body,
  createTreeWalker(root, _show, filter) {{
    const order = [];
    const visit = (n) => {{
      if (n !== root && filter.acceptNode(n) === NodeFilter.FILTER_REJECT) return;
      order.push(n);
      n.kids.forEach(visit);
    }};
    visit(root);
    let at = 0;
    return {{ currentNode: root, nextNode: () => order[++at] || null }};
  }},
}};
console.log(JSON.stringify(({outline})()));"#
    );
    let Some(out) = node(&script) else {
        eprintln!("skipped: no node on PATH");
        return;
    };
    let lines: Vec<String> = serde_json::from_str(out.trim()).unwrap();
    assert_eq!(
        lines,
        vec!["h1 Welcome back", "span Total: 3", "tab/button Save", "input:password Password"]
    );
    assert!(!out.contains("hunter2"));
}

/// The duress number for the PR: the daemon's CPU for one frame's structural step (parse the
/// cell's outline, hash it, compare it with the last kept and summarize), at the bound
/// ([`MAX_LINES`] lines of [`LINE_CHARS`] characters, every line changed). Thread CPU time.
/// `cargo test -p acpmux --lib turn_frames_shape -- --ignored --nocapture`.
#[cfg(unix)]
#[test]
#[ignore]
fn measure_the_structural_step_per_frame() {
    fn cpu() -> Duration {
        let mut t = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: clock_gettime(2) writes the timespec it is handed.
        unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut t) };
        Duration::new(t.tv_sec as u64, t.tv_nsec as u32)
    }
    let pad = "x".repeat(LINE_CHARS);
    let page = |word: &str| {
        let lines: Vec<String> = (0..MAX_LINES).map(|i| format!("li {word} {i} {pad}")).collect();
        format!(
            "TURN_SHOT {{\"id\":\"t\"}}\nTURN_SHAPE {}\n",
            serde_json::to_string(&lines).unwrap()
        )
    };
    let (a, b) = (page("item"), page("row"));
    let typical = |word: &str| {
        let lines: Vec<String> = (0..80).map(|i| format!("div {word} {i} of the list")).collect();
        format!("TURN_SHAPE {}\n", serde_json::to_string(&lines).unwrap())
    };
    let (ta, tb) = (typical("item"), typical("row"));
    let rounds = 2000u32;
    let mut summaries = 0;
    for (name, x, y) in [("bound (400 x 120 chars)", &a, &b), ("typical (80 lines)", &ta, &tb)] {
        let last = parse(x).unwrap();
        let start = cpu();
        for _ in 0..rounds {
            let now = parse(y).unwrap();
            summaries += change(&last, &now).map_or(0, |s| s.len());
        }
        let per = (cpu() - start) / rounds;
        eprintln!(
            "turn_frames_shape: {name}: {:.1} us CPU per frame, {} bytes of cell output",
            per.as_secs_f64() * 1e6,
            y.len()
        );
    }
    assert!(summaries > 0);
}
