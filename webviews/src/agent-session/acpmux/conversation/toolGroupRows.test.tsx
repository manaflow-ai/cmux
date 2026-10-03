import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity } from "../model";
import { commandMessage } from "./agentMessages";
import { CommandRow } from "./CommandRow";
import { MessageCard } from "./MessageCard";
import { ToolGroupRow } from "./ToolGroupRow";

const command = (line: string, fields: Partial<NonNullable<AcpmuxActivity["tool"]>> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: line,
  tool: { id: line, title: line, kind: "execute", status: "completed", command: line, ...fields },
});

describe("grouped tool rows", () => {
  test("a command row shows the command, its exit status and its run time", () => {
    const ok = renderToStaticMarkup(
      createElement(CommandRow, { item: command("bun test", { exitCode: 0, startedAt: 0, endedAt: 4200 }) }),
    );
    expect(ok).toContain('<code class="cv-command__line">bun test</code>');
    expect(ok).toContain("cv-command__ok");
    expect(ok).toContain("4.2s");
    const failed = renderToStaticMarkup(
      createElement(CommandRow, { item: command("make", { exitCode: 2, status: "failed" }) }),
    );
    expect(failed).toContain('<span class="cv-command__failed">Exit 2</span>');
  });

  test("a group's line counts its calls and its failures", () => {
    const html = renderToStaticMarkup(
      createElement(ToolGroupRow, { kind: "commands", items: [command("ls"), command("make", { exitCode: 1 })] }),
    );
    expect(html).toContain("Ran 2 commands");
    expect(html).toContain("1 failed");
  });

  test("a message card reads sender to recipient over the first line", () => {
    const line = `tell-coordinator --from cc-pane-transcript --to cc-next-ci "Landed #17079\\nNext: items 4+5"`;
    const html = renderToStaticMarkup(
      createElement(MessageCard, { item: command(line), message: commandMessage(line)! }),
    );
    expect(html).toContain('aria-label="Message from cc-pane-transcript to cc-next-ci"');
    expect(html).toContain("Coordinator");
    // Two lines show until the card opens; a two-line message needs no Show more.
    expect(html).toContain('<div class="cv-message__body is-clamped">Landed #17079\nNext: items 4+5</div>');
    expect(html).not.toContain("Show more");
    const long = `tell-coordinator "${"word ".repeat(40)}"`;
    expect(
      renderToStaticMarkup(createElement(MessageCard, { item: command(long), message: commandMessage(long)! })),
    ).toContain("Show more");
    expect(html).not.toContain("tell-coordinator --from");
  });
});
