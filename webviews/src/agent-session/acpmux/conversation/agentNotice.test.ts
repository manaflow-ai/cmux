// l10n-allow-file: test fixtures.
// A tool's or reconciler's notice to a chat (manaflow-ai/cmuxterm-hq#6380): acpmux's `notice`
// provenance, the CLI's rendered head an older acpmux kept no provenance for, and tell-coordinator's
// page, read as a notice (its sender, machine, severity, title and links) and never as the person's
// own words.
import { expect, test } from "bun:test";
import { incomingPrompt } from "./incomingMessage";
import {
  legacyNotice,
  noticeBody,
  noticeLinkLabel,
  noticeMarkdown,
  noticeRowText,
  renderedNotice,
} from "./agentNotice";
import { laneNotice } from "./laneReport";

const PR = "https://github.com/manaflow-ai/cmux/pull/32827";
const RUN = "https://github.com/manaflow-ai/cmux/actions/runs/19022341987/job/5412";

/// The prompt's text as `acpmux send --notice` renders it.
const RENDERED = [
  "[notice from base-red-watch on ci-mini-3 · FIRE] cmux-next fast tier failed on 3 PRs",
  "Failed steps: Run the fast tier. Owner: the coordinator.",
  "",
  "Check it against base and land the fix first.",
  `Links: ${PR} (#32827), ${RUN}`,
].join("\n");

const provenance = {
  kind: "notice",
  from: "fromAgent",
  fromName: "base-red-watch",
  to: "s-coord",
  notice: {
    sender: "base-red-watch",
    host: "ci-mini-3",
    severity: "fire",
    title: "cmux-next fast tier failed on 3 PRs",
    links: [{ url: PR, label: "#32827" }, { url: RUN }],
  },
};

test("a notice provenance is the sender's notice: its title, machine, severity and links, the body alone", () => {
  expect(incomingPrompt(RENDERED, { client: "acpmux-cli#1@ci-mini-3", _meta: { provenance } })).toEqual({
    kind: "message",
    message: {
      name: "base-red-watch",
      notice: {
        sender: "base-red-watch",
        host: "ci-mini-3",
        severity: "fire",
        title: "cmux-next fast tier failed on 3 PRs",
        links: [{ url: PR, label: "#32827" }, { url: RUN }],
      },
      // Neither the rendered head nor the Links line: the row draws both itself.
      text: "Failed steps: Run the fast tier. Owner: the coordinator.\n\nCheck it against base and land the fix first.",
      raw: RENDERED,
    },
  });
});

test("a notice is never a lane report or an inbox notice, whatever its text says", () => {
  const read = incomingPrompt("lane report: turn 3 ended, ok.", { _meta: { provenance } });
  expect(read?.kind === "message" && laneNotice(read.message)).toBeUndefined();
});

test("a notice provenance with fields that do not read is its sender's message, not the person's", () => {
  for (const notice of [undefined, { sender: "x", severity: "boom", title: "t" }, { severity: "fire" }]) {
    const read = incomingPrompt("Body.", { _meta: { provenance: { ...provenance, notice } } });
    expect(read).toEqual({ kind: "message", message: { name: "base-red-watch", text: "Body.", raw: "Body." } });
  }
  // A non-https link and an over-long label are dropped, the notice kept.
  const read = incomingPrompt("Body.", {
    _meta: {
      provenance: {
        ...provenance,
        notice: { ...provenance.notice, links: [{ url: "javascript:alert(1)" }, { url: PR, label: "x".repeat(65) }] },
      },
    },
  });
  expect(read?.kind === "message" && read.message.notice?.links).toEqual([{ url: PR }]);
});

test("an unknown future provenance kind from an agent is its message, never the person's bubble", () => {
  for (const from of ["fromAgent", "acp:s-9"]) {
    expect(
      incomingPrompt("Rolled back.", { _meta: { provenance: { kind: "nightly_page", from, fromName: "rollback" } } }),
    ).toEqual({ kind: "message", message: { name: "rollback", text: "Rolled back.", raw: "Rolled back." } });
  }
  // A person's kinds and a kind with no sender stay the person's.
  expect(
    incomingPrompt("hi", { _meta: { provenance: { kind: "person_message", from: "s-1", fromName: "Ana" } } }),
  ).toBeUndefined();
  expect(
    incomingPrompt("hi", { _meta: { provenance: { kind: "nightly_page", from: "s-1", fromName: "Ana" } } }),
  ).toBeUndefined();
  expect(incomingPrompt("hi", { _meta: { provenance: { kind: "nightly_page", from: "fromAgent" } } })).toBeUndefined();
});

test("the rendered head alone (an older acpmux) reads as the notice, from a shell's send only", () => {
  const read = incomingPrompt(RENDERED, { client: "acpmux-cli#01a2@ci-mini-3" });
  expect(read?.kind === "message" && read.message.notice).toEqual({
    sender: "base-red-watch",
    host: "ci-mini-3",
    severity: "fire",
    title: "cmux-next fast tier failed on 3 PRs",
    links: [{ url: PR, label: "#32827" }, { url: RUN }],
  });
  expect(read?.kind === "message" && read.message.text).toStartWith("Failed steps:");
  const info = incomingPrompt("[notice from next-autoland] Landed #32827 as 4f1c2a9", { client: "acpmux-outbox#7" });
  expect(info?.kind === "message" && info.message.notice).toEqual({
    sender: "next-autoland",
    severity: "info",
    title: "Landed #32827 as 4f1c2a9",
    links: [],
  });
  // Typed in the pane, or with no client: the person's own words.
  expect(incomingPrompt(RENDERED, undefined)).toBeUndefined();
  expect(incomingPrompt(RENDERED, { client: "cmux-react-agent-pane#01a16f" })).toBeUndefined();
});

test("tell-coordinator's FIRE or WARN page reads as a notice; its other messages as the sender's", () => {
  const page =
    "[tell-coordinator from base-red-watch on ci-mini-3] FIRE cmux-next fast tier failed on 3 PRs (#32801, #32827) since 02:07Z. Failed steps: Run the fast tier. Owner claude-coord (coordinator fallback).";
  const read = incomingPrompt(page, { client: "acpmux-outbox#01a16e@ci-mini-3" });
  expect(read).toEqual({
    kind: "message",
    message: {
      name: "base-red-watch",
      notice: {
        sender: "base-red-watch",
        host: "ci-mini-3",
        severity: "fire",
        title: "cmux-next fast tier failed on 3 PRs (#32801, #32827) since 02:07Z",
        links: [],
      },
      text: "Failed steps: Run the fast tier. Owner claude-coord (coordinator fallback).",
      raw: page,
    },
  });
  expect(legacyNotice("[tell-coordinator from w on h, sent to coord, re #12] WARN: queue is 40 min deep")).toEqual({
    notice: { sender: "w", host: "h", severity: "warn", title: "queue is 40 min deep", links: [] },
    body: "",
  });
  const plain = incomingPrompt("[tell-coordinator from ux-lane on box-1] Merged #2210.", { client: "acpmux-cli#1" });
  expect(plain).toEqual({
    kind: "message",
    message: { name: "ux-lane", text: "Merged #2210.", raw: "[tell-coordinator from ux-lane on box-1] Merged #2210." },
  });
  // A FIREwall is no FIRE.
  expect(legacyNotice("[tell-coordinator from a on b] FIREwall rules changed")).toEqual({
    sender: "a",
    host: "b",
    text: "FIREwall rules changed",
  });
});

test("noticeBody keeps text that has no rendered head or Links line", () => {
  expect(noticeBody("Just a body.\nLinks are below")).toBe("Just a body.\nLinks are below");
});

test("a link's chip label: #N for a pull request or issue, run N for an Actions run, else label or host and tail", () => {
  expect(noticeLinkLabel({ url: PR, label: "PR" })).toBe("#32827");
  expect(noticeLinkLabel({ url: "https://github.com/o/r/issues/12#issuecomment-1" })).toBe("#12");
  expect(noticeLinkLabel({ url: RUN })).toBe("run 1902234…");
  expect(noticeLinkLabel({ url: "https://github.com/o/r/actions/runs/123456" })).toBe("run 123456");
  expect(noticeLinkLabel({ url: "https://grafana.example.com/d/abc/fleet", label: "Fleet board" })).toBe("Fleet board");
  expect(noticeLinkLabel({ url: "https://grafana.example.com/d/abc/fleet?x=1" })).toBe("grafana.example.com/…/fleet");
  expect(noticeLinkLabel({ url: "https://example.com/" })).toBe("example.com");
});

test("a notice's row text keeps its title, so a title alone is no empty row and Find and export read it", () => {
  const read = legacyNotice("[tell-coordinator from w on h] FIRE fast tier failed");
  expect(read && "notice" in read && noticeRowText(read.notice, read.body)).toBe("fast tier failed");
  const page = legacyNotice("[tell-coordinator from w on h] FIRE fast tier failed. Repair now.");
  expect(page && "notice" in page && noticeRowText(page.notice, page.body)).toBe("fast tier failed\n\nRepair now.");
});

test("a link's destination can never close its Markdown link early, and a URL keeps its parentheses", () => {
  expect(noticeMarkdown("", [{ url: "https://good.example/)[Other](https://other.example/" }])).toBe(
    "[good.example/…/other.example](https://good.example/%29[Other]%28https://other.example/)",
  );
  expect(noticeMarkdown("B", [{ url: "https://e.example/a>b c", label: "x]y" }])).toBe(
    "B\n\n[x\\]y](https://e.example/a%3Eb%20c)",
  );
  const read = renderedNotice(
    "[notice from s] T\nBody\nLinks: https://example.com/foo_(bar) (Docs), https://example.com/a,b",
  );
  expect(renderedNotice("[notice from s] T\nLinks: https://example.com/docs (Docs (v2))")?.notice.links).toEqual([
    { url: "https://example.com/docs", label: "Docs (v2)" },
  ]);
  expect(read?.notice.links).toEqual([
    { url: "https://example.com/foo_(bar)", label: "Docs" },
    { url: "https://example.com/a,b" },
  ]);
});
