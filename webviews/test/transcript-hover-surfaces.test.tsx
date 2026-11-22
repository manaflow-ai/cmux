// l10n-allow-file: transcript fixtures, not shipped UI.
// Leo-Ask-Trace: ask-e1768ff161
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { teardownDom } from "./support/domTeardown";
import { MessageRow } from "../src/pages/home-channels/MessageRow";
import { RunSteps } from "../src/pages/home-channels/RunSteps";
import { TranscriptRowView } from "../src/pages/home-messages/transcript/TranscriptRows";
import { SubagentTranscript } from "../src/agent-session/acpmux/backgroundTasks/SubagentTranscript";
import { UserBubble } from "../src/agent-session/acpmux/conversation/UserBubble";
import type { HomeMessage, HomeRun, HomeRunStep } from "../src/pages/home-channels/types";
import type { Strings } from "../src/pages/shared/i18n";

const at = Date.UTC(2026, 10, 19, 10, 30);
const strings = { t: (key: string) => key, format: (key: string) => key } as unknown as Strings;
const message: HomeMessage = {
  id: "hover-message",
  conversation: "hover-chat",
  seq: 1,
  author: "agent",
  createdAt: at,
  retracted: false,
  reactions: [],
  parts: [{ type: "text", text: "Finished at 10:20 UTC.", mentions: [] }],
};
const run: HomeRun = {
  id: "hover-run",
  conversation: "hover-chat",
  author: "agent",
  status: "done",
  startedAt: at,
  updatedAt: at,
  rev: 1,
  stepCount: 1,
  answers: [],
};
const step: HomeRunStep = {
  id: "hover-step",
  seq: 1,
  at,
  rev: 1,
  kind: "talk",
  text: "Finished at 10:20 UTC.",
  attachments: [],
  links: [{ label: "Reference", url: "https://example.com/reference" }],
};

// The channel's action menu subscribes to a client-only store: mount the real row
// instead of asking React's server renderer for a nonexistent server snapshot.
async function mountedMarkup(node: ReactNode): Promise<string> {
  const dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", { url: "http://localhost/" });
  const scope = globalThis as Record<string, unknown>;
  const values: Record<string, unknown> = { IS_REACT_ACT_ENVIRONMENT: true };
  for (const key of ["window", "document", "navigator", "HTMLElement", "Element", "Node", "getComputedStyle"])
    values[key] = (dom.window as unknown as Record<string, unknown>)[key];
  const saved = Object.keys(values).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, values);
  const host = dom.window.document.querySelector("main")!;
  const root = createRoot(host);
  try {
    await act(async () => root.render(node));
    return host.innerHTML;
  } finally {
    await act(async () => root.unmount());
    await teardownDom(saved, { window: dom.window });
  }
}

test("channel transcript timestamps retain their message date", async () => {
  const html = await mountedMarkup(
    <MessageRow
      message={message}
      head
      people={new Map()}
      strings={strings}
      timeFormat={new Intl.DateTimeFormat("en")}
      editing={false}
      onReact={() => {}}
    />,
  );
  expect(html).toContain('class="cv-time-hover"');
  expect(html).toContain('datetime="2026-11-19T10:20:00.000Z"');
});

test("message transcript timestamps retain their message date", () => {
  const html = renderToStaticMarkup(
    <TranscriptRowView
      row={{
        kind: "bubble",
        key: "hover-row",
        gap: 0,
        message,
        parts: message.parts,
        partIndex: 0,
        outgoing: false,
        tail: true,
        indent: false,
        reactions: [],
        markdown: true,
      }}
      me="reader"
      strings={strings}
      now={at}
      people={new Map()}
      actions={{}}
    />,
  );
  expect(html).toContain('class="cv-time-hover"');
  expect(html).toContain('dateTime="2026-11-19T10:20:00.000Z"');
});

test("run transcript timestamps retain their step date", () => {
  const html = renderToStaticMarkup(<RunSteps run={run} steps={[step]} agentNames={new Map()} />);
  expect(html).toContain('class="cv-time-hover"');
  expect(html).toContain('dateTime="2026-11-19T10:20:00.000Z"');
});

test("run transcript links use the shared preview trigger", () => {
  const html = renderToStaticMarkup(<RunSteps run={run} steps={[step]} agentNames={new Map()} />);
  expect(html).toMatch(/<a[^>]*class="[^"]*cv-chip[^"]*"[^>]*href="https:\/\/example.com\/reference"/);
});

test("nested agent transcript timestamps retain their row date", () => {
  const html = renderToStaticMarkup(
    <SubagentTranscript
      running={false}
      rows={[{ id: "nested-reply", kind: "assistant", version: 1, at, text: "Finished at 10:20 UTC." }]}
    />,
  );
  expect(html).toContain('class="cv-time-hover"');
  expect(html).toContain('dateTime="2026-11-19T10:20:00.000Z"');
});

for (const inline of [false, true])
  test(`sent Markdown prompt retains its date (${inline ? "inline" : "legacy"})`, () => {
    const text = "**Finished** at 10:20 UTC.";
    const html = renderToStaticMarkup(
      <UserBubble
        row={{
          id: "hover-prompt",
          kind: "user",
          version: 1,
          at,
          text,
          ...(inline
            ? {
                inlineParts: [
                  { kind: "file" as const, name: "reference.txt", placed: true as const },
                  { kind: "text" as const, text },
                ],
              }
            : {}),
        }}
        text={text}
      />,
    );
    expect(html).toContain('class="cv-time-hover"');
    expect(html).toContain('dateTime="2026-11-19T10:20:00.000Z"');
  });
