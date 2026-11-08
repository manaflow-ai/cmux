import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8");
const gallery = readFileSync(join(import.meta.dir, "transcript.gallery.ts"), "utf8");

test("background activity has one secondary tone; a row's words light on hover or keyboard focus, never its glyph; a received message never", () => {
  expect(css).toContain("--cv-activity-text: color-mix(in srgb, var(--cv-fg) 58%, transparent);");
  // Codex parity (Lucas, 2026-11-06): only the words light, under the pointer or keyboard focus; a
  // click or an opened row leaves no white behind. A sent message's row keeps one steady tone.
  expect(css).toMatch(
    /button\.cv-tool:not\(\.cv-sent, \.cv-agent-activity__control\):is\(:hover, :focus-visible\)\s*> :is\(\.cv-tool__text, \.cv-command__text\) \{\s*color: var\(--cv-text\);/,
  );
  expect(css).not.toContain(".cv-tool:focus-within");
  expect(css).not.toMatch(/\.cv-tool:not\([^)]*\):focus-within:not/);
  expect(css).toMatch(/\.cv-tool\.is-run:hover > \.cv-tool__text \{\s*color: var\(--cv-text\);/);
  // A thought's button ends with its chevron: the pointer on the empty line after an opened
  // thought's words is not on the button, so the words go back to their rest tone (Lucas, 2026-11-06).
  expect(css).toMatch(/\.cv-thought\.is-toggle \{[^}]*width: fit-content;\s*max-width: 100%;/);
  // A step row draws nothing more on hover (agent-pane-step-rows.test.ts).
  expect(css).not.toMatch(/\.cv-tool:hover(,| \.cv-tool__(chevron|detail))/);
  // Only the "Worked for" button lifts; the live line has nothing behind it (transcript-row-hover-scope.test.ts).
  expect(css).toContain("button.cv-worked:hover,");
  // A received message keeps one tone under the pointer and focus (Leo, 2026-11-03).
  expect(css).not.toMatch(/\.cv-received:is\(:hover/);
  expect(css).toContain(".cv-received__text :is(.cv-md, .cv-h),");
  expect(css).toContain(".cv-message:hover .cv-agentmsg__card,");
  expect(css).toContain("color: var(--cv-text);");
});

test("tone gallery includes readable alternatives on the same fixture", () => {
  expect(gallery).toContain('"activity-tone-secondary"');
  expect(gallery).toContain('"activity-tone-tertiary"');
  expect(gallery).toContain('"activity-tone-readable"');
  expect(gallery).toContain('"transcript-activity-tone": "tertiary"');
  expect(gallery).toContain('"transcript-activity-tone": "readable"');
});

test("message lines rest in the activity tone and light to the text tone only on hover or focus", () => {
  // Leo, 2026-11-03, on "Received 6 messages" / "Sent 2 messages" after #34464 drew them in the
  // text tone at rest: "these are now too lit up by default? they should only be this bright when
  // u hover over it".
  const rows = readFileSync(join(import.meta.dir, "AgentMessageRow.css"), "utf8");
  const lines = ".acpmux-row .cv-tool:is(.cv-sent, .cv-agentmsg__line, .cv-message-group__head, [data-message-run])";
  const received = ".acpmux-row .cv-received > .cv-disclosure__line";
  const rest = new RegExp(`${escape(lines)},\\s*${escape(received)} \\{\\s*color: var\\(--cv-activity-text\\);\\s*\\}`);
  expect(rows).toMatch(rest);
  expect(rows).toContain(`${lines}:is(:hover, :focus-visible, :has(:focus-visible))`);
  expect(rows).toContain(`${received}:is(:hover, :has(:focus-visible))`);
  // No rule draws a message line in the text tone at rest.
  expect(rows).not.toMatch(
    new RegExp(`${escape(lines)}(,\\s*\\.acpmux-row \\.cv-agentmsg__card)? \\{\\s*color: var\\(--cv-text\\)`),
  );
});

function escape(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
