// l10n-allow-file: test fixture tool titles and server names, not shipped UI.
// Home's folds move as one state transition on the settle (Leo, 2026-11-07: "they dont overshoot but
// they decelerate at the end. i think that might be the key"): a run card's steps, a grouped tool
// run's details, and the MCP card's Details and connected tools each open and close with their box's
// height and opacity, drawn until the box has closed over them and nothing drawn after, and in one
// frame under Reduce Motion.
import { afterAll, beforeAll, expect, test } from "bun:test";
import paneTable from "../src/pages/home-channels/generated/pane-strings.json";
import table from "../src/pages/home-channels/generated/strings.json";
import { HomeToolGroup } from "../src/pages/home-channels/HomeToolGroup";
import { RunCard } from "../src/pages/home-channels/RunCard";
import type { HomeRunStep } from "../src/pages/home-channels/types";
import { McpConnectCard } from "../src/pages/home-messages/cards/mcp/McpConnectCard";
import { McpConnectFlow, type McpConnectCardData } from "../src/pages/home-messages/cards/mcp/mcpConnect";
import { cardStrings } from "../src/pages/home-messages/cards/strings";
import { createStrings } from "../src/pages/shared/i18n";
import { click, expectSettle, fold, reduceMotion, render, useFoldPage, type Animated } from "./foldSettleHarness";

useFoldPage();
// The run card's tool rows read the agent pane's strings, as the Home page provides them.
const scope = globalThis as Record<string, unknown>;
const paneStrings = scope.__cmuxPaneStrings;
beforeAll(() => {
  scope.__cmuxPaneStrings = paneTable;
});
afterAll(() => {
  if (paneStrings === undefined) delete scope.__cmuxPaneStrings;
  else scope.__cmuxPaneStrings = paneStrings;
});

/// The fold a toggle ran: the one Web Animation whose keyframes move a height.
const heightFolds = () => fold.animations.filter((animation) => "height" in animation.keyframes[0]!);

/// Opens and closes one fold through `toggle`, checking the settle, the held close and that nothing
/// mounts or runs after the motion ends; `body` finds what the fold shows.
function foldsOnTheSettle(toggle: () => Element, body: () => Element | null) {
  expect(body()).toBeNull();
  click(toggle());
  expect(body()).not.toBeNull();
  const opening: Animated | undefined = heightFolds()[0];
  expectSettle(opening);
  expect(opening!.keyframes[0]).toEqual({ height: "0px", opacity: 0 });
  expect(opening!.target.contains(body())).toBe(true);
  opening!.finish();

  click(toggle());
  const closing = heightFolds()[1];
  expectSettle(closing);
  expect(closing!.keyframes.at(-1)).toEqual({ height: "0px", opacity: 0 });
  expect(body()).not.toBeNull();
  const count = fold.animations.length;
  closing!.finish();
  expect(body()).toBeNull();
  expect(fold.animations.length).toBe(count);
}

function foldsInOneFrame(toggle: () => Element, body: () => Element | null) {
  click(toggle());
  expect(body()).not.toBeNull();
  click(toggle());
  expect(body()).toBeNull();
  expect(heightFolds()).toEqual([]);
}

// A run card's steps.
const strings = createStrings(table, ["en"]);
const step = (id: string, seq: number): HomeRunStep => ({
  id,
  kind: "tool",
  seq,
  at: seq,
  rev: 1,
  text: id,
  links: [],
  attachments: [],
  status: "done",
  tool: { name: "Bash", input: { command: `echo ${id}` }, files: [] },
});
const run = {
  id: "r1",
  conversation: "c1",
  author: "chief",
  status: "done",
  startedAt: 0,
  endedAt: 60_000,
  updatedAt: 60_000,
  rev: 1,
  stepCount: 2,
  turn: "t1",
  answers: [],
};
const runCard = () =>
  render(
    <RunCard
      entry={{ run: run as never, steps: [step("one", 1), step("two", 2)], complete: true }}
      strings={strings}
      onOpen={() => {}}
      onLoad={() => {}}
    />,
  );
const runToggle = () => fold.container.querySelector(".lg-run-toggle")!;
const runSteps = () => fold.container.querySelector(".lg-run-steps");

test("a run card's steps open and close on the settle", () => {
  runCard();
  foldsOnTheSettle(runToggle, runSteps);
});

test("a run card's steps open and close in one frame under Reduce Motion", () => {
  reduceMotion();
  runCard();
  foldsInOneFrame(runToggle, runSteps);
});

// A grouped tool run.
const toolGroup = () =>
  render(
    <HomeToolGroup
      row={{ kind: "tools", id: "g", items: [] } as never}
      steps={[step("one", 1)]}
      agentNames={new Map()}
      collapsed
    />,
  );
const toolSummary = () => fold.container.querySelector(".lg-home-tool-summary")!;
/// A closed <details> draws only its summary: the details show while it is open.
const toolDetails = () =>
  fold.container.querySelector("details.lg-home-tool-group[open]")?.querySelector(".lg-home-tool-details") ?? null;

test("a grouped tool run's details open and close on the settle", () => {
  toolGroup();
  foldsOnTheSettle(toolSummary, toolDetails);
});

test("a grouped tool run's details open and close in one frame under Reduce Motion", () => {
  reduceMotion();
  toolGroup();
  foldsInOneFrame(toolSummary, toolDetails);
});

// The MCP connect card.
const cardText = cardStrings(["en"]);
const actions = { choose() {}, connect() {}, cancel() {}, submitKey() {} };
const linear: McpConnectCardData = {
  requestID: "r1",
  agent: "Chief",
  reason: "to file the issues you mention",
  title: "Linear",
  publisher: "linear.app",
  verified: true,
  transport: { kind: "remote", url: "https://mcp.linear.app/mcp" },
  auth: { kind: "oauth", scopes: ["read", "write"] },
  proposedScope: "chief",
};
const compact = () =>
  render(
    <McpConnectCard flow={McpConnectFlow.start(linear)} style="compactRow" strings={cardText} actions={actions} />,
  );
const detailsLink = () => fold.container.querySelector(".hm-mcp__link")!;
const facts = () => fold.container.querySelector(".hm-mcp__facts");

test("the MCP card's Details open and close on the settle", () => {
  compact();
  foldsOnTheSettle(detailsLink, facts);
});

test("the MCP card's Details open and close in one frame under Reduce Motion", () => {
  reduceMotion();
  compact();
  foldsInOneFrame(detailsLink, facts);
});

const connected = () => {
  const flow = McpConnectFlow.start(linear)
    .connect()[0]
    .signedIn()
    .connected([
      { name: "list_issues", kind: "read" },
      { name: "create_issue", kind: "write" },
    ]);
  render(<McpConnectCard flow={flow} style="factsTable" strings={cardText} actions={actions} />);
};
const connectedLine = () => fold.container.querySelector(".hm-mcp__connected")!;
const toolList = () => fold.container.querySelector(".hm-mcp__tool-list");

test("the MCP card's connected tools open and close on the settle, the chevron one glyph that turns", () => {
  connected();
  const glyph = connectedLine().querySelector("svg:last-of-type")!.outerHTML;
  foldsOnTheSettle(connectedLine, toolList);
  // The same glyph open and closed: CSS turns it on aria-expanded, on the settle.
  click(connectedLine());
  expect(connectedLine().querySelector("svg:last-of-type")!.outerHTML).toBe(glyph);
});

test("the MCP card's connected tools open and close in one frame under Reduce Motion", () => {
  reduceMotion();
  connected();
  foldsInOneFrame(connectedLine, toolList);
});
