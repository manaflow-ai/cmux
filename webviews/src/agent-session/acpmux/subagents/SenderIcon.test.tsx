// l10n-allow-file: test fixtures.
// One sender icon (SenderIcon.tsx): the family's mark with the session's badge in its tone, the
// look the chat's keys name (senderIconLook.ts), and the subagent rows that follow it.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { badgeCut, badgeGeometry, SenderIcon } from "./SenderIcon";
import {
  configureSenderIconLook,
  DEFAULT_SENDER_ICON_LOOK,
  resolveSenderIconLook,
  SENDER_ICON_BADGE_KEY,
  SENDER_ICON_CORNER_KEY,
  SENDER_ICON_LEAD_KEY,
} from "./senderIconLook";
import { foreignHarness } from "./agentIdentityModel";
import { rememberHarnessIcons } from "../../shared/harnessIcons";
import { SubagentsSection } from "../session-info/SubagentsSection";
import type { Subagent } from "./subagentFold";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "MutationObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  configureSenderIconLook({});
});

test("a session of a known family draws the family's mark big and its diamond badge at the bottom right", async () => {
  const container = await render(<SenderIcon harness="claude" tone={3} size={12} />);
  const icon = container.querySelector(".cv-sender-icon")!;
  expect(icon.getAttribute("data-badged")).toBe("true");
  expect(icon.querySelector(".cv-sender-icon__main [data-agent='claude']")).not.toBeNull();
  const badge = icon.querySelector<HTMLElement>(".cv-sender-icon__badge")!;
  expect(badge.dataset.badge).toBe("diamond");
  expect(badge.dataset.corner).toBe("bottom-right");
  expect(badge.querySelector("[data-agent-tone='3']")).not.toBeNull();
});

test("two sessions of one family share the mark and differ by their badge's tone", async () => {
  const container = await render(
    <>
      <SenderIcon harness="claude" tone={0} size={12} />
      <SenderIcon harness="claude" tone={4} size={12} />
    </>,
  );
  const tones = [...container.querySelectorAll(".cv-sender-icon__badge [data-agent-tone]")].map((node) =>
    node.getAttribute("data-agent-tone"),
  );
  expect(tones).toEqual(["0", "4"]);
  expect(container.querySelectorAll(".cv-sender-icon__main [data-agent='claude']")).toHaveLength(2);
});

test("a sender with no family mark draws its badge glyph alone, big, in its tone", async () => {
  const container = await render(<SenderIcon tone={1} size={12} fallback="agent.bot" />);
  expect(container.querySelector(".cv-sender-icon__badge")).toBeNull();
  expect(container.querySelector("[data-agent-tone='1'] [data-icon='task.ai']")).not.toBeNull();
});

test("a harness whose icon is only a glyph has no drawable mark, so its session glyph stays full size (review F3)", async () => {
  rememberHarnessIcons([{ id: "glyphy", iconSpec: { kind: "glyph", name: "terminal", source: "default" } }]);
  const container = await render(<SenderIcon harness="glyphy" tone={2} size={12} fallback="agent.bot" />);
  expect(container.querySelector(".cv-sender-icon__badge")).toBeNull();
  expect(container.querySelector("[data-agent-tone='2'] [data-icon='task.ai']")).not.toBeNull();
});

test("the reversed look draws the session's glyph big and the family's mark as the badge", async () => {
  configureSenderIconLook({
    [SENDER_ICON_LEAD_KEY]: "session",
    [SENDER_ICON_BADGE_KEY]: "robot",
    [SENDER_ICON_CORNER_KEY]: "top-left",
  });
  const container = await render(<SenderIcon harness="codex" tone={2} size={12} />);
  expect(container.querySelector(".cv-sender-icon__main [data-icon='agent.bot']")).not.toBeNull();
  const badge = container.querySelector<HTMLElement>(".cv-sender-icon__badge")!;
  expect(badge.dataset.badge).toBe("family");
  expect(badge.dataset.corner).toBe("top-left");
  // Codex draws OpenAI's mark (agentBrands.generated.ts).
  expect(badge.querySelector("[data-agent='openai']")).not.toBeNull();
});

test("with the badge off, or no session to tell apart, the family's mark is drawn alone as before", async () => {
  configureSenderIconLook({ [SENDER_ICON_BADGE_KEY]: "none" });
  const off = await render(<SenderIcon harness="claude" tone={2} size={12} />);
  expect(off.querySelector(".cv-sender-icon__badge")).toBeNull();
  expect(off.querySelector("[data-agent='claude']")).not.toBeNull();
});

test("an unknown or missing key keeps the default look", () => {
  expect(resolveSenderIconLook({})).toEqual(DEFAULT_SENDER_ICON_LOOK);
  expect(resolveSenderIconLook({ [SENDER_ICON_BADGE_KEY]: "cloud", [SENDER_ICON_CORNER_KEY]: "right" })).toEqual(
    DEFAULT_SENDER_ICON_LOOK,
  );
  expect(resolveSenderIconLook({ [SENDER_ICON_CORNER_KEY]: "top-right" }).corner).toBe("top-right");
});

test("the badge is about half the slot and its ring is cut at its own corner", () => {
  expect(badgeGeometry(12)).toEqual({ badge: 7, overhang: 2 });
  expect(badgeCut(12, "bottom-right")).toBe("radial-gradient(circle at 10.5px 10.5px, transparent 4.5px, #000 5px)");
  expect(badgeCut(12, "top-left")).toBe("radial-gradient(circle at 1.5px 1.5px, transparent 4.5px, #000 5px)");
});

test("a subagent of the chat's own family shows its family's mark while a badge tells it apart", () => {
  expect(foreignHarness("claude", "claude", "diamond")).toBe("claude");
  expect(foreignHarness("claude", "claude", "none")).toBeUndefined();
  expect(foreignHarness("codex", "claude", "none")).toBe("codex");
});

test("a change of the badge setting redraws a mounted subagent list at once (review F1)", async () => {
  const agents: Subagent[] = [
    {
      id: "explorer",
      parent: null,
      name: "explorer",
      kind: "Explore",
      task: "t",
      state: "running",
      startedAt: 1,
      harness: "claude",
    },
  ];
  const container = await render(<SubagentsSection agents={agents} waiting={new Set()} harness="claude" />);
  const icon = () => container.querySelector(".acpmux-lineage__icon")!;
  // Badged: the chat's own family shows its mark with the subagent's diamond.
  expect(icon().querySelector(".cv-sender-icon__main [data-agent='claude']")).not.toBeNull();
  await act(async () => configureSenderIconLook({ [SENDER_ICON_BADGE_KEY]: "none" }));
  // None: the toned subagent glyph, as before the badge, with no parent render of its own.
  expect(icon().querySelector("[data-agent='claude']")).toBeNull();
  expect(icon().querySelector("[data-agent-tone] [data-icon='task.ai']")).not.toBeNull();
  await act(async () => configureSenderIconLook({}));
  expect(icon().querySelector(".cv-sender-icon__main [data-agent='claude']")).not.toBeNull();
});
