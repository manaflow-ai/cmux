// l10n-allow-file: test fixtures and expected English words, not shipped UI.
//
// The Cloud ergonomics measurement (measure.tsx) that cmuxterm-hq's `cloud-ergonomics-linux` probe publishes:
// its classifier on hand-made cards, its fixtures still reading as the failure they stand for, and a whole run
// in which every state renders, so a refactor that moves a card shows up here instead of as a quiet zero.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { failureKind } from "../failureCopy";
import { classifyError, controlsIn, controlWay, etaIn, outOfAppWords, waitReason } from "./classify";
import { measureCloudErgonomics } from "./measure";
import { cloudErgonomicsStates, KINDS, NOT_ON_CLOUD, TURN_FAILURE_FIXTURES, turnFailureRoute } from "./states";

const html = (body: string) => new JSDOM(`<!doctype html><body>${body}</body>`).window.document.body;

test("an error's class: a click that goes on in the pane wins, then words or links out of it, else a dead end", () => {
  expect(classifyError(["out-of-app", "in-place"], false, true)).toBe("next-step");
  expect(classifyError([], true, false)).toBe("next-step");
  expect(classifyError(["out-of-app"], false, false)).toBe("out-of-app");
  expect(classifyError(["dismiss", "inert"], false, true)).toBe("out-of-app");
  expect(classifyError(["dismiss", "inert"], false, false)).toBe("dead-end");
});

test("a click's way: in the pane, out of it, Not now, or nothing at all", () => {
  expect(
    controlWay(
      [
        { kind: "out-of-app", what: "open" },
        { kind: "in-place", what: "wait" },
      ],
      false,
    ),
  ).toBe("in-place");
  expect(controlWay([{ kind: "out-of-app", what: "open" }], false)).toBe("out-of-app");
  expect(controlWay([{ kind: "dismiss", what: "not now" }], false)).toBe("dismiss");
  expect(controlWay([], true)).toBe("in-place");
  expect(controlWay([], false)).toBe("inert");
});

test("controls leave out Details, disclosures, disabled and hidden buttons", () => {
  const body = html(`<div class="card">
    <button>Retry</button>
    <button disabled>Busy</button>
    <button aria-expanded="false">Show steps</button>
    <details><summary>Details</summary><button>Copy error</button></details>
    <span aria-hidden="true"><button>Hidden</button></span>
    <a href="https://github.com/apps/cmux">Install</a>
  </div>`);
  expect(controlsIn([body.querySelector(".card")!]).map((node) => node.textContent)).toEqual(["Retry", "Install"]);
});

test("words that send the person out of the pane: a command, a terminal, Settings; never the raw details", () => {
  expect(outOfAppWords([html("<p>Sign in: run `cmux cloud sign-in`.</p>")])).toBe("`cmux cloud sign-in`");
  expect(outOfAppWords([html("<p>Open System Settings to allow it.</p>")])).toBe("System Settings");
  expect(outOfAppWords([html("<p>Claude Code stopped.</p><details>run `claude /login`</details>")])).toBeUndefined();
});

test("a wait's reason is any words but a bare Thinking, and its ETA is the element marked as one", () => {
  const generic = new Set(["thinking"]);
  const bare = html(
    `<div class="cv-worked"><output class="cv-thinking">Thinking</output><span class="cv-worked__time">4s</span></div>`,
  );
  expect(waitReason([bare], generic)).toBeUndefined();
  expect(etaIn([bare])).toBeUndefined();
  const staged = html(`<div><output class="cv-thinking">Starting your Cloud machine</output>
    <span class="cv-worked__time">12s</span>
    <span class="cv-worked__count acpmux-cloud-start__eta"><span>·</span><span>usually under a minute</span></span></div>`);
  expect(waitReason([staged], generic)).toBe("Starting your Cloud machine");
  expect(etaIn([staged])).toBe("· usually under a minute");
  expect(etaIn([html(`<p>Waiting <span data-wait-eta>about 30 s</span></p>`)])).toBe("about 30 s");
});

test("each turn failure fixture reads as its kind on a Cloud route, and every Cloud kind has one", () => {
  for (const fixture of TURN_FAILURE_FIXTURES)
    expect(failureKind(fixture.error, turnFailureRoute(fixture), fixture.code), fixture.id).toBe(fixture.kind);
  const covered = new Set(TURN_FAILURE_FIXTURES.map((fixture) => fixture.kind));
  for (const kind of Object.keys(KINDS) as (keyof typeof KINDS)[])
    if (!NOT_ON_CLOUD.has(kind)) expect(covered.has(kind), kind).toBe(true);
});

test("a whole run renders every state and adds up", async () => {
  const states = cloudErgonomicsStates();
  expect(new Set(states.map((state) => state.id)).size).toBe(states.length);
  const report = await measureCloudErgonomics(states);
  expect(report.missing).toEqual([]);
  expect(report.errors_total + report.waits_total).toBe(states.length);
  expect(report.errors_with_next_step + report.errors_out_of_app + report.errors_dead_end).toBe(report.errors_total);
  expect(report.waits_total).toBeGreaterThan(0);
  const byId = new Map(report.states.map((reading) => [reading.id, reading]));
  // Anchors that hold whatever the counts are: a retryable start offers Retry in the pane, a signed-out start
  // signs in from the card, Cloud off by policy offers nothing, a rate limit leads with Retry.
  expect(byId.get("cloud-start.cloud_start_failed.retryable")?.class).toBe("next-step");
  expect(byId.get("cloud-start.not_signed_in.timed-out")?.class).toBe("next-step");
  expect(byId.get("cloud-start.cloud_disabled")?.class).toBe("dead-end");
  expect(byId.get("turn-failure.rate-limited")?.class).toBe("next-step");
  expect(byId.get("repo-recovery.ambiguous")?.class).toBe("next-step");
  // A start that is signing in says so; it gives no time, since that is the person's.
  expect(byId.get("cloud-start-wait.signing-in")?.reason).toBeDefined();
});
