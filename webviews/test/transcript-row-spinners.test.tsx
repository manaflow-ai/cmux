// l10n-allow-file: synthetic transcript fixtures.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { CommandRow } from "../src/agent-session/acpmux/conversation/CommandRow";
import { MessageCard } from "../src/agent-session/acpmux/conversation/MessageCard";
import { SentMessageLine } from "../src/agent-session/acpmux/conversation/SentMessageLine";
import { ToolGroupRow } from "../src/agent-session/acpmux/conversation/ToolGroupRow";
import { resetTranscriptDisclosure } from "../src/agent-session/acpmux/conversation/transcriptDisclosure";

const activity = (n: number, background = false): AcpmuxActivity => ({
  kind: "tool",
  text: `echo ${n}`,
  tool: {
    id: `spinner-call-${n}`,
    title: `echo ${n}`,
    kind: "execute",
    command: `echo ${n}`,
    status: background ? "completed" : "in_progress",
    ...(background && { background: { state: "running" as const } }),
  },
});

function markup(node: ReactNode) {
  return JSDOM.fragment(renderToStaticMarkup(node));
}

afterEach(() => resetTranscriptDisclosure());

for (const background of [false, true]) {
  test(`three running commands have only the group header activity mark (background=${background})`, () => {
    const items = [1, 2, 3].map((n) => activity(n, background && n > 1));
    const view = markup(<ToolGroupRow kind="commands" items={items} disclosureKey="spinner-group" />);
    expect(view.querySelectorAll(".cv-step")).toHaveLength(3);
    expect(view.querySelectorAll("[data-tool-group] .cv-spinner")).toHaveLength(1);
    expect(view.querySelectorAll("[data-tool-group-items] .cv-spinner")).toHaveLength(0);
    expect(view.querySelectorAll(".cv-spinner")).toHaveLength(1);
  });
}

test("a standalone running command retains its activity mark", () => {
  expect(markup(<CommandRow item={activity(1)} />).querySelectorAll(".cv-spinner")).toHaveLength(1);
});

test("a sending message row has no spinner", () => {
  const item = activity(1);
  const view = markup(
    <SentMessageLine
      tool={item.tool!}
      state="sending"
      target="reviewer"
      text="Please review this change."
      disclosureKey="spinner-send"
      raw={() => null}
    />,
  );
  expect(view.textContent).toContain("reviewer");
  expect(view.querySelector(".cv-sent.is-live")).not.toBeNull();
  expect(view.querySelectorAll(".cv-spinner")).toHaveLength(0);
});

test("a Claude SendMessage row has no spinner while sending", () => {
  const view = markup(
    <MessageCard item={activity(2)} message={{ channel: "agent", to: "reviewer", text: "Please review." }} />,
  );
  expect(view.querySelector('[data-delivery="sending"]')).not.toBeNull();
  expect(view.querySelectorAll(".cv-spinner")).toHaveLength(0);
});
