// What a reader sees of the per-PR gallery diff (compare.ts): the diff page (changed states first,
// each as a highlight overlay, a slider and an onion skin; unchanged states folded), the sticky PR
// comment, and the summary the team feed shows on the PR's card.
import { STATUS_ORDER, type Outcome, type Status } from "./compare";

export type ReportLinks = {
  /** The diff page, the PR's gallery and its matrix index, when published. */
  diff?: string;
  gallery?: string;
  matrix?: string;
  /** The CI run whose artifact holds the diff page and the renders, until a host serves them. */
  artifact?: string;
  /** The thumbnails' URL prefix: a state's thumbnail is this followed by its key (pr-media raw URLs). */
  thumbBase?: string;
  /** The branch's live gallery preview (`/wt/<name>/`, liveBase), on the tailnet gallery host. */
  live?: string;
};
export type ReportMeta = { pr: number; head: string; base: string; links: ReportLinks };

export const COMMENT_MARKER = "<!-- cmux-gallery-pr -->";
export const COMMENT_THUMBS = 6;
const SUMMARY_STATES = 5;

const LABELS: Record<Status, [one: string, many: string]> = {
  changed: ["state changed", "states changed"],
  new: ["new state", "new states"],
  removed: ["removed state", "removed states"],
  broken: ["broken state", "broken states"],
  nondeterministic: ["nondeterministic state", "nondeterministic states"],
  unchanged: ["state unchanged", "states unchanged"],
};

export function counts(outcomes: Outcome[]): Record<Status, number> {
  const out = Object.fromEntries(STATUS_ORDER.map((status) => [status, 0])) as Record<Status, number>;
  for (const outcome of outcomes) out[outcome.status]++;
  return out;
}

const plural = (n: number, status: Status) => `${n} ${LABELS[status][n === 1 ? 0 : 1]}`;

/** `entry/variant`, with the theme and engine only where the matrix varies them. */
export function stateLabel(outcome: Outcome, outcomes: Outcome[]): string {
  const themes = new Set(outcomes.map((o) => o.theme)).size > 1;
  const engines = new Set(outcomes.map((o) => o.engine)).size > 1;
  const extra = [themes ? outcome.theme : "", engines ? outcome.engine : ""].filter(Boolean);
  return `${outcome.entry}/${outcome.variant}${extra.length ? ` (${extra.join(", ")})` : ""}`;
}

/** The states whose play checks failed (play.ts: anchors, layout shift, long frames, or the play threw). */
export const playFailures = (outcomes: Outcome[]) => outcomes.filter((o) => o.play?.status === "fail");

/** Why one state's play failed: each failing step and its problems, else the error. */
export function playFailureText(outcome: Outcome): string {
  const steps = (outcome.frames ?? [])
    .filter((frame) => frame.play?.status === "fail")
    .map((frame) => `step ${frame.index + 1} ${frame.step}: ${frame.play!.problems.join("; ") || "failed"}`);
  return [...steps, outcome.play?.error].filter(Boolean).join(" · ") || "failed";
}

/** "7 states changed: agent-pane.composer/streaming, ... · 1 new state", or that nothing changed. */
export function summaryLine(outcomes: Outcome[]): string {
  const n = counts(outcomes);
  const changed = outcomes.filter((o) => o.status === "changed");
  // One name per entry/variant: the themes and engines of one state usually change together.
  const names = [...new Set(changed.map((o) => `${o.entry}/${o.variant}`))];
  const head = n.changed
    ? `${plural(n.changed, "changed")}: ${names.slice(0, SUMMARY_STATES).join(", ")}${names.length > SUMMARY_STATES ? ", ..." : ""}`
    : "No state changed";
  const rest = (["new", "removed", "broken"] as const).filter((s) => n[s]).map((s) => plural(n[s], s));
  const failed = new Set(playFailures(outcomes).map((o) => `${o.entry}/${o.variant}`)).size;
  if (failed) rest.push(`${failed} play check${failed === 1 ? "" : "s"} failed`);
  return [head, ...rest].join(" · ");
}

export function feedSummary(outcomes: Outcome[], meta: ReportMeta) {
  return {
    pr: meta.pr,
    head: meta.head,
    base: meta.base,
    summary: summaryLine(outcomes),
    counts: { ...counts(outcomes), playFailed: playFailures(outcomes).length },
    links: { diff: meta.links.diff, gallery: meta.links.gallery, matrix: meta.links.matrix },
    changed: outcomes
      .filter((o) => o.status === "changed")
      .map((o) => ({
        state: stateLabel(o, outcomes),
        entry: o.entry,
        variant: o.variant,
        theme: o.theme,
        engine: o.engine,
        ratio: o.ratio,
        thumb: thumbUrl(o, meta),
        steps: o.frames?.length,
      })),
    playFailed: playFailures(outcomes).map((o) => ({ state: stateLabel(o, outcomes), why: playFailureText(o) })),
  };
}

// Outcomes may come from an artifact the PR's own code wrote (the publisher reads outcomes.json), so
// a key becomes a URL only when it is a plain file name, and labels are escaped for a table cell.
const SAFE_KEY = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

// The publisher uploads <thumbBase file prefix><key> through scripts/pr-media.py, whose sanitize()
// collapses each run of dashes (an `entry--variant` key keeps its double dash), so the link names
// the file pr-media.py stores.
const storedName = (key: string) => key.replace(/-{2,}/g, "-");

export const thumbUrl = (o: Outcome, meta: ReportMeta) =>
  o.thumb && meta.links.thumbBase && SAFE_KEY.test(o.key) ? `${meta.links.thumbBase}${storedName(o.key)}` : undefined;

/** The changed states whose thumbnails the comment shows; the publisher uploads exactly these. */
export const commentThumbs = (outcomes: Outcome[], meta: ReportMeta) =>
  outcomes.filter((o) => o.status === "changed" && thumbUrl(o, meta)).slice(0, COMMENT_THUMBS);

/** The live preview's path for a branch: gallery-live.sh's preview name (lower case, [a-z0-9-] runs,
 *  at most 40 characters). The comment gives the path only; the host is tailnet-only. */
export function liveBase(branch: string): string | undefined {
  const name = branch
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 40)
    .replace(/-$/, "");
  return name ? `/wt/${name}/` : undefined;
}

/** A state's page in the live preview: `/wt/<name>/?entry=<id>#/<id>/<variant>`. */
export const liveLink = (o: Outcome, meta: ReportMeta) =>
  meta.links.live && SAFE_KEY.test(o.entry) && SAFE_KEY.test(o.variant)
    ? `${meta.links.live}?entry=${o.entry}#/${o.entry}/${o.variant}`
    : undefined;

type LiveEntry = { label: string; url: string };

/** One live link per changed or new entry and variant (themes and engines share a page). */
function liveEntries(outcomes: Outcome[], meta: ReportMeta): LiveEntry[] {
  const seen = new Set<string>();
  const links: LiveEntry[] = [];
  for (const o of outcomes) {
    if (o.status !== "changed" && o.status !== "new") continue;
    const link = liveLink(o, meta);
    if (!link || seen.has(link)) continue;
    seen.add(link);
    links.push({ label: `${o.entry}/${o.variant}`, url: link });
  }
  return links;
}

const escapeMd = (text: string) => text.replace(/[\r\n]+/g, " ").replace(/[|[\]<>`*_\\]/g, (c) => `\\${c}`);
const escapeHtml = (text: string) =>
  text.replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]!);

function liveLinks(outcomes: Outcome[], meta: ReportMeta): string[] {
  return liveEntries(outcomes, meta).map(({ label, url }) => `- ${escapeMd(label)}: \`${url}\``);
}

export function commentMarkdown(outcomes: Outcome[], meta: ReportMeta): string {
  const n = counts(outcomes);
  const lines = [COMMENT_MARKER, "### Gallery", "", `**${escapeMd(summaryLine(outcomes))}**`, ""];
  const links = [
    meta.links.diff && `[Diff page](${meta.links.diff})`,
    meta.links.gallery && `[Gallery at this head](${meta.links.gallery})`,
    meta.links.matrix && `[Matrix](${meta.links.matrix})`,
    !meta.links.diff &&
      meta.links.artifact &&
      `[Diff page and renders](${meta.links.artifact}) (the run's \`gallery-pr\` artifact)`,
  ].filter(Boolean);
  if (links.length) lines.push(links.join(" · "), "");
  const changed = outcomes.filter((o) => o.status === "changed" && thumbUrl(o, meta));
  if (changed.length) {
    lines.push("| State | Before · after |", "| --- | --- |");
    for (const o of commentThumbs(outcomes, meta))
      lines.push(`| ${escapeMd(stateLabel(o, outcomes))} | <img src="${thumbUrl(o, meta)}" width="480"> |`);
    if (changed.length > COMMENT_THUMBS) lines.push("", `${changed.length - COMMENT_THUMBS} more on the diff page.`);
    lines.push("");
  }
  const live = liveLinks(outcomes, meta);
  if (live.length) {
    lines.push(
      "**Live preview** (follows this branch; start it with `scripts/gallery-live.sh up <branch>` from an hq checkout):",
      "",
    );
    lines.push(...live.slice(0, COMMENT_THUMBS));
    if (live.length > COMMENT_THUMBS) lines.push(`- ${live.length - COMMENT_THUMBS} more on the diff page`);
    lines.push("");
  }
  const failed = playFailures(outcomes);
  if (failed.length) {
    lines.push(
      "**Play checks failed** (0 px anchor movement, 0 layout shift, no frame over 33 ms unless the entry gives a reason):",
      "",
    );
    for (const o of failed.slice(0, COMMENT_THUMBS))
      lines.push(`- ${escapeMd(stateLabel(o, outcomes))}: ${escapeMd(playFailureText(o))}`);
    if (failed.length > COMMENT_THUMBS) lines.push(`- ${failed.length - COMMENT_THUMBS} more on the diff page`);
    lines.push("");
  }
  if (n.nondeterministic)
    lines.push(
      `${plural(n.nondeterministic, "nondeterministic")} differed from a second render of the same head (a clock or fixture leak) and ${n.nondeterministic === 1 ? "is" : "are"} not counted as changes.`,
      "",
    );
  lines.push(`<sub>${n.unchanged} unchanged · base ${meta.base.slice(0, 11)} · head ${meta.head.slice(0, 11)}</sub>`);
  return `${lines.join("\n")}\n`;
}

/** The diff page: plain HTML and a small script, images beside it (base/, head/, thumbs/). */
export function diffPage(outcomes: Outcome[], meta: ReportMeta): string {
  const data = JSON.stringify({ outcomes, labels: outcomes.map((o) => stateLabel(o, outcomes)) }).replace(
    /</g,
    "\\u003c",
  );
  const title = `PR #${meta.pr} gallery diff`;
  const live = liveEntries(outcomes, meta);
  const liveMarkup = live.length
    ? `<details class="live-links"><summary>Live previews (${live.length})</summary><ul>${live
        .map(({ label, url }) => `<li><a href="${escapeHtml(url)}">${escapeHtml(label)}</a></li>`)
        .join("")}</ul></details>`
    : "";
  return `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>
:root{color-scheme:light dark;--bg:#f6f6f4;--card:#fff;--text:#1d1d1b;--muted:#6b6b66;--edge:#0001;--box:#e5484d;--new:#2f7d4f;--removed:#9a6b00}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--card:#1f1f1e;--text:#ededeb;--muted:#a1a19c;--edge:#fff2}}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,sans-serif}
header{padding:20px 16px 8px;max-width:1240px;margin:0 auto}
h1{font-size:18px;margin:0 0 4px}
.sub{color:var(--muted)}
.live-links{margin-top:10px;color:var(--muted);font-size:12px}.live-links ul{columns:2;margin:6px 0 0;padding-left:18px}.live-links a{color:inherit}
label{display:inline-flex;align-items:center;gap:6px;margin-top:10px;color:var(--muted);font-size:12px}
select{font:inherit;color:var(--text);background:var(--card);border:1px solid var(--edge);border-radius:6px;padding:3px 6px}
main{max-width:1240px;margin:0 auto;padding:8px 16px 48px}
h2{font-size:15px;margin:28px 0 10px}
article{background:var(--card);border-radius:10px;box-shadow:0 0 0 1px var(--edge);padding:12px;margin:0 0 16px}
.meta{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:baseline;margin-bottom:10px}
.meta strong{font-size:14px}
.tag{font-size:12px;padding:1px 8px;border-radius:99px;background:var(--edge)}
.tag.new{color:var(--new)}.tag.removed{color:var(--removed)}.tag.changed,.tag.broken,.tag.nondeterministic{color:var(--box)}
.views{display:flex;gap:4px;margin-left:auto}
.views button{font:inherit;font-size:12px;border:0;border-radius:6px;padding:3px 10px;background:var(--edge);color:var(--text);cursor:pointer}
.views button[aria-pressed=true]{background:var(--text);color:var(--card)}
.stage{position:relative;max-width:100%;overflow:auto}
.stage img{display:block;max-width:100%;height:auto}
.frame{position:relative;display:inline-block;max-width:100%}
.frame .over{position:absolute;inset:0}
.frame .over img{width:100%;height:100%;max-width:none}
.box{position:absolute;outline:2px solid var(--box);outline-offset:1px;border-radius:2px;background:color-mix(in srgb,var(--box) 12%,transparent)}
input[type=range]{width:min(420px,100%);margin:8px 0 0}
.strip{display:flex;gap:8px;overflow-x:auto;margin-top:12px;padding-bottom:4px}
.frame-cell{flex:none;width:200px;display:flex;flex-direction:column;gap:4px;text-align:left;font:inherit;font-size:12px;color:var(--text);background:none;border:0;border-radius:8px;padding:6px;box-shadow:0 0 0 1px var(--edge);cursor:pointer}
.frame-cell[aria-pressed=true]{box-shadow:0 0 0 2px var(--text)}
.frame-cell img{width:100%;height:auto;border-radius:4px}
.frame-label{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.frame-metrics{color:var(--muted)}.frame-metrics.fail{color:var(--box)}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.pair figure{margin:0}.pair figcaption{color:var(--muted);font-size:12px;margin-bottom:4px}
details summary{cursor:pointer;color:var(--muted)}
ul.plain{columns:2;padding-left:18px;color:var(--muted)}
@media (max-width:640px){ul.plain{columns:1}.pair{grid-template-columns:1fr}}
</style>
<header><h1>${title}</h1><div class="sub" id="summary"></div><label>Entry <select id="entry-filter" aria-label="Filter gallery diff by entry"><option value="">All entries</option></select></label>${liveMarkup}</header>
<main id="main"></main>
<script>
const {outcomes, labels} = ${data};
const main = document.getElementById("main");
const entryFilter = document.getElementById("entry-filter");
const el = (tag, attrs = {}, ...kids) => { const n = document.createElement(tag); for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v); n.append(...kids); return n; };
const img = (src, alt) => el("img", {src, alt, loading: "lazy"});
const pct = (n, of) => (100 * n / of) + "%";
const order = ${JSON.stringify(STATUS_ORDER)};
const titles = {changed: "Changed", new: "New", removed: "Removed", broken: "Broken (the head stage did not mount)", nondeterministic: "Nondeterministic (differs from itself; not counted)", unchanged: "Unchanged"};
const n = Object.fromEntries(order.map((s) => [s, outcomes.filter((o) => o.status === s).length]));
document.getElementById("summary").textContent = order.filter((s) => n[s]).map((s) => n[s] + " " + s).join(" · ") + " · base ${meta.base.slice(0, 11)} · head ${meta.head.slice(0, 11)}";

function highlight(o) {
  const frame = el("div", {class: "frame"}, img(o.head, "head"));
  for (const b of o.boxes) frame.append(el("div", {class: "box", style: "left:" + pct(b.x, o.width) + ";top:" + pct(b.y, o.height) + ";width:" + pct(b.w, o.width) + ";height:" + pct(b.h, o.height)}));
  return frame;
}
function layered(o, mode) {
  const over = el("div", {class: "over"}, img(o.head, "head"));
  const frame = el("div", {class: "frame"}, img(o.base, "base"), over);
  const range = el("input", {type: "range", min: "0", max: "100", value: "50", "aria-label": mode === "slider" ? "Before / after split" : "Head opacity"});
  const apply = () => { const v = Number(range.value); if (mode === "slider") over.style.clipPath = "inset(0 0 0 " + v + "%)"; else over.style.opacity = String(v / 100); };
  range.addEventListener("input", apply); apply();
  return el("div", {}, frame, range);
}
function metricsText(m) {
  if (!m) return "";
  return "CLS " + m.layoutShift.toFixed(3) + " · " + m.longFrames + " long frame" + (m.longFrames === 1 ? "" : "s") + (m.longFrames ? " (max " + m.longFrameMaxMs.toFixed(1) + " ms)" : "") + (m.frameSource === "raf" ? " · software-rendered, not a gate" : "");
}
function picture(p, stage, buttons) {
  const views = {highlight: () => highlight(p), slider: () => layered(p, "slider"), onion: () => layered(p, "onion")};
  buttons.replaceChildren();
  if (p.status === "changed") {
    const show = (name) => { stage.replaceChildren(views[name]()); for (const b of buttons.children) b.setAttribute("aria-pressed", String(b.dataset.view === name)); };
    for (const name of Object.keys(views)) { const b = el("button", {type: "button", "data-view": name}, name[0].toUpperCase() + name.slice(1)); b.onclick = () => show(name); buttons.append(b); }
    show("highlight");
  } else if (p.status === "nondeterministic") {
    stage.replaceChildren(highlight(p));
  } else {
    const src = p.head || p.base;
    stage.replaceChildren(...(src ? [img(src, p.status)] : []));
  }
}
function card(o, i) {
  const stage = el("div", {class: "stage"});
  const buttons = el("div", {class: "views"});
  const meta = el("div", {class: "meta"}, el("strong", {}, labels[i]), el("span", {class: "tag " + o.status}, o.status));
  if (o.play && o.play.status === "fail") meta.append(el("span", {class: "tag broken"}, "play checks failed"));
  if (o.status === "changed" && o.pixels) meta.append(el("span", {class: "sub"}, (o.ratio * 100).toFixed(2) + "% of pixels · " + o.boxes.length + " region" + (o.boxes.length === 1 ? "" : "s")));
  meta.append(buttons);
  const parts = [meta, stage];
  if (o.frames && o.frames.length) {
    // The filmstrip: the played steps in order, then the final still; a frame opens in the views above.
    const strip = el("div", {class: "strip"});
    const select = (p, cell) => { picture(p, stage, buttons); for (const c of strip.children) c.setAttribute("aria-pressed", String(c === cell)); };
    // The final outcome's play field is the aggregate report, not a StepMetrics object.
    // Leave it off the final cell so metricsText never reads step-only fields from it.
    const frames = [
      ...o.frames.map((f) => ({...f, label: "Step " + (f.index + 1) + ": " + f.step})),
      {...o, play: undefined, label: "Final"},
    ];
    for (const f of frames) {
      const src = f.head || f.base;
      const cell = el("button", {type: "button", class: "frame-cell"}, ...(src ? [img(src, f.label)] : []), el("span", {class: "frame-label"}, f.label), el("span", {class: "tag " + f.status}, f.status));
      if (f.play) cell.append(el("span", {class: "frame-metrics" + (f.play.status === "fail" ? " fail" : "")}, metricsText(f.play) + (f.play.problems.length ? " · " + f.play.problems.join("; ") : "")));
      if (f.basePlay && f.play && (f.basePlay.layoutShift !== f.play.layoutShift || f.basePlay.longFrames !== f.play.longFrames)) cell.append(el("span", {class: "frame-metrics"}, "base: " + metricsText(f.basePlay)));
      cell.onclick = () => select(f, cell);
      strip.append(cell);
    }
    parts.push(strip);
    const first = frames.find((f) => f.status !== "unchanged") || frames[frames.length - 1];
    select(first, strip.children[frames.indexOf(first)]);
  } else {
    picture(o, stage, buttons);
  }
  if (o.play && o.play.error) parts.push(el("div", {class: "sub"}, "Play: " + o.play.error));
  return el("article", {id: o.key, "data-entry": o.entry}, ...parts);
}
order.forEach((status) => {
  const list = outcomes.map((o, i) => [o, i]).filter(([o]) => o.status === status);
  if (!list.length) return;
  if (status === "unchanged") {
    const section = el("section", {"data-status": status});
    const failed = list.filter(([o]) => o.play && o.play.status === "fail");
    if (failed.length) section.append(el("h2", {}, "Play checks failed (" + failed.length + ")"), ...failed.map(([o, i]) => card(o, i)));
    const details = el("details", {});
    details.append(
      el("summary", {"data-summary": "unchanged"}, list.length + " unchanged"),
      el("ul", {class: "plain"}, ...list.map(([o, i]) => el("li", {"data-entry": o.entry}, labels[i]))),
    );
    section.append(details);
    main.append(section);
    return;
  }
  const section = el("section", {"data-status": status});
  section.append(el("h2", {}, titles[status] + " (" + list.length + ")"), ...list.map(([o, i]) => card(o, i)));
  main.append(section);
});
for (const entry of [...new Set(outcomes.map((o) => o.entry))].sort()) entryFilter.append(el("option", {value: entry}, entry));
const applyEntryFilter = () => {
  const selected = entryFilter.value;
  for (const node of main.querySelectorAll("[data-entry]")) node.hidden = Boolean(selected && node.dataset.entry !== selected);
  for (const section of main.querySelectorAll("[data-status]")) {
    const visible = [...section.querySelectorAll("[data-entry]")].filter((node) => !node.hidden);
    section.hidden = visible.length === 0;
    const summary = section.querySelector("[data-summary='unchanged']");
    if (summary) summary.textContent = visible.length + " unchanged";
  }
};
entryFilter.addEventListener("change", applyEntryFilter);
applyEntryFilter();
</script>
</html>
`;
}
