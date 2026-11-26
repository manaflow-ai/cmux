// A sent prompt draws `@computer-use` and `@browser-use` as the badges the composer drew them as
// (chips/ToolBadge.tsx): the tool's icon and name, with what it does on hover. Other
// text around them stays as typed; a file named after a tool stays text.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { PromptTyped } from "./PromptText";

const draw = (text: string) => renderToStaticMarkup(<PromptTyped text={text} show={(shown) => shown} />);

test("a sent prompt draws each tool word as its badge, and the rest as typed", () => {
  const html = draw("open the settings app with @computer-use, then check it with @browser-use");
  expect(html.match(/cv-tool-badge/g)).toHaveLength(2);
  expect(html).toContain('data-tool="computer-use"');
  expect(html).toContain('data-tool="browser-use"');
  // The hover says what it does, as the @ menu row does.
  expect(html).toContain('title="Agents can use your apps when you ask them to"');
  expect(html).toContain('title="Agents can use the cmux browser when you ask them to"');
  expect(html).toContain("open the settings app with ");
  expect(html).toContain(", then check it with ");
  expect(html).not.toContain(">@computer-use<");
});

test("a file named after a tool, or a tool word in another word, stays text", () => {
  expect(draw("review @computer-use.md and me@browser-use")).not.toContain("cv-tool-badge");
});

test("a prompt drawn as Markdown draws its tool words as badges too, never inside code", () => {
  const html = draw("Use @browser-use to check `localhost`\n- then **@computer-use**\n- and `@computer-use` literally");
  expect(html).toContain("cv-user__markdown");
  expect(html).toContain('data-tool="browser-use"');
  expect(html.match(/data-tool="computer-use"/g)).toHaveLength(1);
  expect(html).toContain("<code");
  expect(html).toContain("@computer-use</code>");
});
