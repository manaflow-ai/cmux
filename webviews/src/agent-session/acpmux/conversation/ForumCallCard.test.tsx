// The forum card draws an agent-forum call's thread as a link to it (https only), a search's hits with
// the rest counted, and a cut answer without a count; the "line" look keeps it to one row.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../i18n";
import { ForumCallCard } from "./ForumCallCard";
import { forumShellCall } from "./forumShellCalls";
import { jsonSearchCall, manyHitsCall, showCall } from "./forumShellCalls.fixtures";

const draw = (item: ReturnType<typeof showCall>, look: "line" | "card" | "quote" = "card") =>
  renderToStaticMarkup(<ForumCallCard item={item} call={forumShellCall(item.tool!)!} look={look} />);

test("a thread it read is a link to the thread", () => {
  const html = draw(showCall());
  expect(html).toContain('data-forum-call="show"');
  expect(html).toContain('href="https://github.com/manaflow-ai/cmuxterm-hq/issues/24871"');
  expect(html).toContain(translate("forumCall.read", { ref: "#24871" }));
});

test("a list shows five hits and counts the rest", () => {
  const html = draw(manyHitsCall());
  expect(html.match(/cv-forum-call__hit"/g)).toHaveLength(5);
  expect(html).toContain(`cv-forum-call__more"><span class="ui-sign">+</span>3 `);
});

test("only https links draw", () => {
  const html = draw(jsonSearchCall());
  expect(html).toContain('href="https://forum.example.com/t/41"');
  expect(html).not.toMatch(/href="(?!https:)/);
});

test("the line look draws no thread block", () => {
  expect(draw(showCall(), "line")).not.toContain("cv-forum-call__thread");
});
