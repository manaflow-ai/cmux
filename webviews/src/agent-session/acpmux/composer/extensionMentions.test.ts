// l10n-allow-file: synthetic extension mention labels.
import { describe, expect, test } from "bun:test";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { type MentionItem, mentionInsert, mentionItems, mentionSelection } from "../mentionItems";
import {
  ExtensionMentionProviders,
  extensionMentionsFrom,
  mentionAsk,
  mentionPrefixesFrom,
  type ExtensionMention,
} from "./extensionMentions";

const PR: ExtensionMention = {
  app: "local/team-flow",
  extension: "Team flow",
  prefix: "pr",
  id: "441",
  label: "#441 Fix the login redirect",
  insert: "PR #441 (https://github.com/o/r/pull/441)",
};

describe("extension @ mentions (cmux.composer.mention/1)", () => {
  test("a provider's prefix as the word, or prefix:query, asks only that provider", () => {
    expect(mentionAsk("pr", ["pr"])).toEqual({ prefix: "pr", query: "" });
    expect(mentionAsk("PR:441", ["pr"])).toEqual({ prefix: "pr", query: "441" });
    expect(mentionAsk("login", ["pr"])).toEqual({ query: "login" });
    expect(mentionAsk("jira:12", ["pr"])).toEqual({ query: "jira:12" });
  });

  test("replies are read defensively: no id or label drops the entry, no insert writes the label", () => {
    expect(mentionPrefixesFrom({ mentions: [{ prefix: "pr" }, { prefix: "pr" }, { prefix: "" }, {}] })).toEqual(["pr"]);
    expect(mentionPrefixesFrom(null)).toEqual([]);
    const read = extensionMentionsFrom({ mentions: [{ id: "1", label: "One" }, { id: "2" }, null, { label: "x" }] });
    expect(read).toEqual([{ app: "", extension: "", prefix: "", id: "1", label: "One", insert: "One" }]);
  });

  test("the providers are read from the page host and again when the installed apps change", async () => {
    const client = new MockAppPanelsClient();
    const owner = new ExtensionMentionProviders(client);
    owner.start();
    await owner.refresh();
    expect(owner.getSnapshot()).toEqual(["pr"]);
    let told = 0;
    owner.subscribe(() => told++);
    client.composerMentions = [];
    client.setComposerCommands([]);
    await owner.refresh();
    expect(owner.getSnapshot()).toEqual([]);
    expect(told).toBe(1);
    owner.stop();
  });

  test("the page asks the daemon's matcher through cmux.apps.panels.mentions", async () => {
    const client = new MockAppPanelsClient();
    const reply = await client.call("cmux.apps.panels.mentions", mentionAsk("pr:450", ["pr"]));
    expect(extensionMentionsFrom(reply).map((m) => m.id)).toEqual(["450"]);
    expect(client.mentionAsks).toEqual([{ prefix: "pr", query: "450" }]);
  });

  test("the @ menu lists extension rows after the chats, first when the word names their prefix", () => {
    const base = { query: "pr", files: [], sessions: [], extension: [PR] };
    expect(mentionItems(base).map((item) => item.kind)).toEqual(["extension"]);
    expect(mentionItems({ ...base, extensionFirst: true })[0]?.kind).toBe("extension");
  });

  test("while files are on their way, Return prefers a row that is not an extension's unless the word named its provider", () => {
    const after = mentionItems({ query: "app", files: [], sessions: [], extension: [PR] });
    // A listed row is always chosen (#47787): with only the extension's row, it is the one.
    expect(mentionSelection(after, undefined, true)).toBe(0);
    const harness: MentionItem = { kind: "harness", key: "harness:codex", harnessId: "codex", name: [] };
    expect(mentionSelection([after[0]!, harness], undefined, true)).toBe(1);
    expect(mentionSelection([after[0]!, harness], undefined, true, true)).toBe(0);
    const first = mentionItems({ query: "pr", files: [], sessions: [], extension: [PR], extensionFirst: true });
    expect(mentionSelection(first, undefined, true, true)).toBe(0);
  });

  test("an insert that starts like a Markdown block is escaped at the start of a line", () => {
    const quote = { ...PR, insert: "> quoted" };
    const numbered = { ...PR, insert: "1. first" };
    const [q] = mentionItems({ query: "pr", files: [], sessions: [], extension: [quote] });
    const [n] = mentionItems({ query: "pr", files: [], sessions: [], extension: [numbered] });
    expect(mentionInsert(q!).markdown).toBe("\\> quoted ");
    expect(mentionInsert(n!).markdown).toBe("1\\. first ");
  });

  test("a stopped then restarted owner keeps one watch of the installed apps", async () => {
    const client = new MockAppPanelsClient();
    let watches = 0;
    const subscribe = client.subscribe.bind(client);
    client.subscribe = (async (...args: Parameters<typeof subscribe>) => {
      const stop = await subscribe(...args);
      watches++;
      return () => {
        watches--;
        stop();
      };
    }) as typeof client.subscribe;
    const owner = new ExtensionMentionProviders(client);
    owner.start();
    owner.stop();
    owner.start();
    await owner.refresh();
    await Promise.resolve();
    expect(watches).toBe(1);
    owner.stop();
  });

  test("picking an extension row writes its insert text, not an @ path", () => {
    const [row] = mentionItems({ query: "pr", files: [], sessions: [], extension: [PR] });
    expect(mentionInsert(row!)).toEqual({
      shown: "PR #441 (https://github.com/o/r/pull/441) ",
      markdown: "PR #441 (https://github.com/o/r/pull/441) ",
    });
  });
});
