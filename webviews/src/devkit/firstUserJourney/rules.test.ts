// l10n-allow-file: test fixtures and expected English words, not shipped UI.
//
// The first-user journey's rules (rules.ts) on hand-made documents: each fires on the busted state it
// names and stays quiet on the good one beside it, so a red in a run is the page's, not the rule's.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  consoleErrors,
  deadButton,
  disabledWithoutReason,
  errorRegions,
  errorWithoutNextStep,
  permanentSpinners,
  rawErrorCode,
  rawErrorCodes,
  spinners,
  type ClickEffect,
} from "./rules";

const body = (html: string) => new JSDOM(`<!doctype html><body>${html}</body>`).window.document.body;
const none: ClickEffect = {
  dom: false,
  url: false,
  focus: false,
  clipboard: false,
  rpc: [],
  host: [],
  popup: false,
};

test("raw-error-code: codes, stack traces, JSON and type names read as raw; words do not", () => {
  for (const raw of [
    "connect ECONNREFUSED 127.0.0.1:8080",
    "Request failed: HTTP 503",
    "status: 401",
    "502 Bad Gateway",
    "TypeError: cannot read properties",
    "Error: socket closed",
    "at handleClick (App.tsx:120:15)",
    'Failed {"code":"auth.signed_out"}',
    "Model: undefined",
    "Name null",
    "[object Object]",
    "failed with -32603",
    "transport.harness_not_confirmed",
    "429 rate_limit_error",
    "ProtocolError",
  ])
    expect(rawErrorCode(raw)).toBeDefined();
  for (const words of [
    "Claude Code isn't signed in. Sign in to send messages.",
    "You've hit your usage limit. It resets at 3pm.",
    "Codex is not installed",
    "Retry in 5 seconds",
    "Use a nullable field",
    "Errors and warnings",
    "Build 2026.11.12",
  ])
    expect(rawErrorCode(words)).toBeUndefined();
});

test("raw-error-code reads only the page's own words, never code, a prompt, or the agent's text", () => {
  expect(rawErrorCodes(body(`<div>Sign in failed: HTTP 401</div>`))).toHaveLength(1);
  expect(rawErrorCodes(body(`<pre>TypeError: x is undefined</pre><code>ECONNREFUSED</code>`))).toEqual([]);
  expect(
    rawErrorCodes(body(`<div class="cv-user">why is it null?</div><div class="cv-markdown">Error: boom</div>`)),
  ).toEqual([]);
  expect(rawErrorCodes(body(`<details><summary>Details</summary>HTTP 500</details>`))).toEqual([]);
});

test("error-without-next-step: an error with a button, a command or an instruction has a next step", () => {
  const dead = body(`<div class="turn-error">Couldn't start the agent.</div>`);
  expect(errorWithoutNextStep(errorRegions(dead))).toHaveLength(1);
  const button = body(`<div class="turn-error"><p>Claude Code isn't signed in.</p><button>Sign in</button></div>`);
  expect(errorWithoutNextStep(errorRegions(button))).toEqual([]);
  const command = body(`<div class="turn-error">Not signed in. Run <code>claude auth login</code>.</div>`);
  expect(errorWithoutNextStep(errorRegions(command))).toEqual([]);
  const words = body(`<div class="turn-error">You've hit your usage limit. It resets at 3pm.</div>`);
  expect(errorWithoutNextStep(errorRegions(words))).toEqual([]);
  // A card's own words are found from its label: the button sits beside the error text.
  const beside = body(
    `<section><span class="error-text">The agent failed to start.</span><button>Retry</button></section>`,
  );
  expect(errorWithoutNextStep(errorRegions(beside))).toEqual([]);
});

test("error regions are only those that say something went wrong", () => {
  expect(errorRegions(body(`<div class="notice">Tip: press / for commands</div>`))).toEqual([]);
  expect(errorRegions(body(`<div role="alert">Cursor is not installed</div>`))).toHaveLength(1);
});

test("dead-button: any visible change, route, focus, clipboard, RPC or host call is an effect", () => {
  expect(deadButton("Copy", none)).toHaveLength(1);
  expect(deadButton("Copy", { ...none, clipboard: true })).toEqual([]);
  expect(deadButton("Open", { ...none, dom: true })).toEqual([]);
  expect(deadButton("Send", { ...none, rpc: ["session/prompt"] })).toEqual([]);
  expect(deadButton("Sign in", { ...none, host: ["harness.login"] })).toEqual([]);
  expect(deadButton("Docs", { ...none, popup: true })).toEqual([]);
});

test("dead-button: a disabled control needs a reason a person can see", () => {
  const [bare] = body(`<button disabled>Update</button>`).children;
  expect(disabledWithoutReason(bare!)).toHaveLength(1);
  const [titled] = body(`<button disabled title="Already up to date">Update</button>`).children;
  expect(disabledWithoutReason(titled!)).toEqual([]);
  const [enabled] = body(`<button>Update</button>`).children;
  expect(disabledWithoutReason(enabled!)).toEqual([]);
  // The row's status says why: an environment that is Ready has nothing to build.
  const row = body(
    `<div class="row"><b>web</b> Ready <span class="row-control"><button disabled>Build</button></span></div>`,
  );
  expect(disabledWithoutReason(row.querySelector("button")!)).toEqual([]);
  // A control named by aria-labelledby is reported by that name.
  const named = body(
    `<span id="t">Rotate Favorites</span><button role="switch" aria-labelledby="t" disabled></button>`,
  );
  expect(disabledWithoutReason(named.querySelector("button")!)[0]?.detail).toContain("Rotate Favorites");
  // Undo with no history and Reset at the default say "nothing to do" by their own name.
  for (const label of ["Undo", "Redo", "Reset appearance"]) {
    const [control] = body(`<button disabled>${label}</button>`).children;
    expect(disabledWithoutReason(control!)).toEqual([]);
  }
});

test("permanent-spinner: loading indicators and Loading… words are found, and reported after the grace", () => {
  const page = body(`<div role="progressbar" aria-label="Loading models"></div><span>Loading…</span><p>Loaded</p>`);
  const found = spinners(page);
  expect(found).toContain("Loading models");
  expect(found).toContain("Loading…");
  expect(permanentSpinners(found)[0]?.rule).toBe("permanent-spinner");
  expect(spinners(body(`<p>All set</p>`))).toEqual([]);
  // A heading that names a setting is not a status.
  expect(spinners(body(`<h3>Loading Indicator</h3>`))).toEqual([]);
  expect(spinners(body(`<span>Checking for updates…</span>`))).toEqual(["Checking for updates…"]);
});

test("console-error: the page's own errors count, dev-server chatter does not", () => {
  expect(consoleErrors(["[vite] connecting...", "uncaught: x is not a function"])).toEqual([
    { rule: "console-error", detail: "uncaught: x is not a function" },
  ]);
});
