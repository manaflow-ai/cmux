import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8");
const gallery = readFileSync(join(import.meta.dir, "transcript.gallery.ts"), "utf8");

test("background activity has one secondary tone and lifts on hover or focus; a step row only on focus; a received message never", () => {
  expect(css).toContain("--cv-activity-text: color-mix(in srgb, var(--cv-fg) 58%, transparent);");
  // The lift skips a row whose session link chip has the focus: the chip lights alone (AgentTag.css).
  // A tool run's or group's summary line (`is-run`) is left out: it lights on hover only. A sent
  // message's row keeps one steady tone, as a received one's does.
  expect(css).toContain(
    ".cv-tool:not(.is-run, .cv-sent, .cv-agent-activity__control):focus-within:not(:has(.cv-agent-tag.is-open:focus)),",
  );
  expect(css).not.toContain(".cv-tool:focus-within");
  expect(css).toMatch(/\.cv-tool\.is-run:hover > \.cv-tool__text \{\s*color: var\(--cv-text\);/);
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
