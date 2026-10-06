// Every site write goes through the loader's commit protocol
// (docs/browser-repl/site-tools.md, "Drafts and the commit protocol"): the
// draft records a typed intent (the account by stable ids, the target by
// stable ids, every field the preview shows), and the confirmation reads
// all of it back from the site right before the write and writes only when
// it matches. This file enumerates every site tool method: a method must be
// a declared write (which returns a draft and commits through the
// protocol) or be listed below as a read or a local action, so a new
// method cannot skip the protocol unnoticed.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";

// Methods that do not change what other people see.
const READS = {
  googleAccounts: ["list"],
  googleDocs: ["structure", "read", "export"],
  googleSheets: ["info", "read", "readAll", "cells", "find", "export"],
  googleSlides: ["slides", "read", "export"],
  googleDrive: ["download", "recent", "search", "export"],
  gmail: ["search", "inbox", "thread", "attachment"],
  googleCalendar: ["events"],
  googleSearch: ["search"],
  youtube: ["videoId", "search", "metadata", "captions", "transcript", "comments"],
  slack: ["workspaces", "channels", "history", "replies", "search", "user", "call"],
  notion: ["pageId", "accounts", "search", "read"],
  linkedin: ["me", "profile", "search", "feed"],
  x: ["user", "userTweets", "timeline", "search", "tweet"],
  github: ["issue", "pull", "diff", "issues", "assigned", "file"],
  linear: ["viewer", "issue", "search", "assigned", "query"],
  jira: ["issue", "search", "sites", "me"],
  pageAssets: ["list", "bundle"],
  webmcp: ["tools"],
  browserAuth: [],
};
// Methods that act without a draft, and why nobody else is reached.
const LOCAL = {
  "googleDrive.create": "makes a new file private to the signed-in account",
  "browserAuth.request": "the user fills a cmux sheet; the values never reach the agent",
};

const DOC_ID = "1docPRIVATE000000000000000000000x";
const DOC = `https://docs.google.com/document/d/${DOC_ID}/edit`;
const SHEET_ID = "1sheetSHARED00000000000000000000x";
const SHEET = `https://docs.google.com/spreadsheets/d/${SHEET_ID}/edit#gid=0`;
const DECK_ID = "1deckPRIVATE00000000000000000000x";
const DECK = `https://docs.google.com/presentation/d/${DECK_ID}/edit`;
const NOTION_PAGE_URL = "https://www.notion.so/acme/Team-Handbook-1a2b3c4d00004000800000000000abcd";

// One draft per declared write: `draft` is REPL code returning the draft,
// `sent` the content fields the write sends from the draft itself (every
// other preview field must be read back from the site).
const WRITES = {
  "googleDocs.replace": { draft: `sites.googleDocs.replace(${JSON.stringify(DOC)}, "Closing line.", "Closing line.")`, sent: ["find", "replace"] },
  "googleDocs.insertAfter": { draft: `sites.googleDocs.insertAfter(${JSON.stringify(DOC)}, "Closing line.", " Fin.")`, sent: ["anchor", "text"] },
  "googleDocs.append": { draft: `sites.googleDocs.append(${JSON.stringify(DOC)}, "Appendix.")`, sent: ["text"] },
  "googleSheets.write": { draft: `sites.googleSheets.write(${JSON.stringify(SHEET)}, "E1", [["x"]])`, sent: ["range", "values"] },
  "googleSheets.append": { draft: `sites.googleSheets.append(${JSON.stringify(SHEET)}, [["Misc", "5"]])`, sent: ["values"] },
  "googleSheets.clear": { draft: `sites.googleSheets.clear(${JSON.stringify(SHEET)}, "E1")`, sent: ["range"] },
  "googleSlides.setNotes": { draft: `sites.googleSlides.setNotes(${JSON.stringify(DECK)}, 1, "Protocol notes")`, sent: ["notes"] },
  "googleSlides.replace": { draft: `sites.googleSlides.replace(${JSON.stringify(DECK)}, "Time", "Time")`, sent: ["find", "replace"] },
  "googleDrive.trash": { draft: `(async () => { const f = await sites.googleDrive.create("document", "cmux REPL protocol trash"); return sites.googleDrive.trash(f.url); })()`, sent: [] },
  "gmail.send": { draft: 'sites.gmail.send({ to: "bob@example.com", subject: "Protocol", body: "Read back before Send." })', sent: [] },
  "googleCalendar.create": { draft: 'sites.googleCalendar.create({ title: "Protocol", start: "2026-10-08T17:00:00Z", guests: ["bob@example.com"] })', sent: ["timeZone"] },
  "slack.post": { draft: 'sites.slack.post({ team: "T01ACME", channel: "#eng", text: "Read back before posting" })', sent: ["threadTs", "text"] },
  "notion.append": { draft: `sites.notion.append(${JSON.stringify(NOTION_PAGE_URL)}, "Read back before writing.")`, sent: ["blocks", "markdown"] },
  "linkedin.post": { draft: 'sites.linkedin.post({ text: "Read back before posting.", audience: "anyone" })', sent: [] },
  "x.post": { draft: 'sites.x.post("Read back before posting.")', sent: [] },
  "webmcp.call": { draft: '(async () => { await page.goto("https://tools.example/"); return sites.webmcp.call("add_to_cart", { sku: "P-1" }); })()', sent: ["input"] },
};

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("commit-protocol");

test("every site tool method is a declared write, a read, or a local action", async () => {
  const tools = await s.value("sites.list()");
  const unclassified = [];
  const writes = [];
  for (const tool of tools) {
    assert.equal(tool.error, undefined, `${tool.name} failed to load`);
    const methods = (await s.value(`sites.help(${JSON.stringify(tool.name)})`)).split("\n").map((l) => l.slice(`sites.${tool.name}.`.length));
    for (const m of methods) {
      const key = `${tool.name}.${m}`;
      if (tool.writes.includes(m)) writes.push(key);
      else if (!(READS[tool.name] || []).includes(m) && !LOCAL[key]) unclassified.push(key);
    }
    for (const w of tool.writes) assert.ok(methods.includes(w), `${tool.name} declares a write ${w} it does not have`);
  }
  assert.deepEqual(unclassified, [], "classify each new method: a declared write (meta.writes) or, if nobody else is reached, a read or a local action in this file");
  assert.deepEqual(writes.sort(), Object.keys(WRITES).sort(), "each declared write needs a fixture here");
});

for (const [key, fixture] of Object.entries(WRITES)) {
  test(`${key}: returns a draft, and its confirmation reads every bound field back before the write`, async () => {
    const files = env.state.editors.files;
    const saved = [DOC_ID, SHEET_ID, DECK_ID].map((id) => [id, structuredClone(Object.fromEntries(["blocks", "slides", "sheets"].filter((k) => files.get(id)[k] !== undefined).map((k) => [k, files.get(id)[k]])))]);
    try {
      await s.run(`var __protocolDraft = await (${fixture.draft})`);
      const d = await s.value("__protocolDraft");
      assert.equal(d.status, "draft", `${key} acted without a draft: ${JSON.stringify(d)}`);
      assert.equal(`${d.site}.${d.action}`, key);
      assert.deepEqual(d.checked, []);
      await s.value(`sites.${key}(__protocolDraft.id, { confirm: true })`);
      const after = await s.value("sites.drafts.get(__protocolDraft.id)");
      assert.equal(after.status, "sent");
      const want = Object.keys(d.preview).filter((k) => !fixture.sent.includes(k)).sort();
      assert.deepEqual([...after.checked].sort(), want, `${key} must read back every preview field it does not send itself`);
    } finally {
      for (const [id, v] of saved) Object.assign(files.get(id), v);
    }
  });
}

// The protocol itself, on a tool registered for this test: an undeclared
// write, a commit that writes without reading back, a field the site does
// not give and a field that differs all fail closed before the write.
test("the commit protocol fails closed: undeclared writes, no read-back, unread and differing fields", async () => {
  const S = globalThis.CmuxBrowserRepl.sites;
  const acts = [];
  globalThis.__protocolPage = { account: "ada", target: "T1", body: "hi" };
  S.register(
    "protocolProbe",
    (t) => ({
      send(input, options) {
        return t.write("protocolProbe", "send", input, options, (m) => ({
          category: "[9] test",
          summary: "probe",
          account: { who: "ada" },
          target: { id: "T1" },
          content: { body: m.body, note: "n" },
          sent: m.sendAccount ? ["who"] : ["note"],
          commit: (c) => (m.skip ? (acts.push("skipped"), "done") : c.write(() => ({ who: globalThis.__protocolPage.account, id: globalThis.__protocolPage.target, ...(globalThis.__protocolPage.body === undefined ? {} : { body: globalThis.__protocolPage.body }) }), (press) => press.input(() => acts.push(m.body)), { account: () => ({ who: globalThis.__protocolPage.account }) })),
        }));
      },
      other(input, options) {
        return t.write("protocolProbe", "other", input, options, () => ({ category: "x", summary: "x", account: { who: "ada" }, commit: (c) => c.write(() => ({ who: "ada" }), (press) => press.input(() => acts.push("other")), { account: () => ({ who: "ada" }) }) }));
      },
    }),
    { summary: "test", writes: ["send"] },
  );
  const p = env.session("commit-protocol-probe");
  try {
    assert.match(await p.error('sites.protocolProbe.other({})'), /not a declared write/);
    assert.match(await p.error('sites.protocolProbe.send({ body: "hi", sendAccount: true })'), /only content may be sent/);
    await p.run('var pD = await sites.protocolProbe.send({ body: "hi" }); var pSkip = await sites.protocolProbe.send({ body: "hi", skip: true }); var pGone = await sites.protocolProbe.send({ body: "hi" }); var pDiff = await sites.protocolProbe.send({ body: "hi" });');
    assert.match(await p.error("sites.protocolProbe.send(pSkip.id, { confirm: true })"), /without reading the draft back/);
    globalThis.__protocolPage.body = undefined;
    assert.match(await p.error("sites.protocolProbe.send(pGone.id, { confirm: true })"), /could not read body back/);
    globalThis.__protocolPage = { account: "mallory", target: "T2", body: "hi" };
    assert.match(await p.error("sites.protocolProbe.send(pDiff.id, { confirm: true })"), /account it acts as differs from the draft \(who is "mallory", not "ada"\)/);
    assert.deepEqual(acts, ["skipped"], "only the probe that skipped the protocol acted, and it failed");
    globalThis.__protocolPage = { account: "ada", target: "T1", body: "hi" };
    await p.value("sites.protocolProbe.send(pD.id, { confirm: true })");
    assert.deepEqual(acts, ["skipped", "hi"]);
    assert.deepEqual([...(await p.value("sites.drafts.get(pD.id)")).checked].sort(), ["body", "id", "who"]);
  } finally {
    delete globalThis.__protocolPage;
  }
});

// r14 whole#1: a read-back is plain data read once. A bound field whose
// value serializes itself (toString, toJSON), answers through a getter or
// is any other non-plain object counts as unread (`*_unverified`), even
// when the tool's canon would turn it into the drafted value; nothing is
// written.
test("the commit protocol refuses read-backs that are not plain data: toString, toJSON, getters", async () => {
  const S = globalThis.CmuxBrowserRepl.sites;
  const acts = [];
  globalThis.__plainProbe = null;
  S.register(
    "plainProbe",
    (t) => ({
      send(input, options) {
        return t.write("plainProbe", "send", input, options, () => ({
          category: "[9] test",
          summary: "plain probe",
          account: { who: "ada" },
          target: { to: ["bob@example.com"] },
          canon: { who: (v) => String(v).toLowerCase(), to: (v) => [...v].map(String) },
          commit: (c) => c.write(() => globalThis.__plainProbe(), (press) => press.input(() => acts.push("sent")), { account: () => ({ who: "ada" }) }),
        }));
      },
    }),
    { summary: "test", writes: ["send"] },
  );
  const p = env.session("commit-protocol-plain");
  const forged = {
    toString: () => ({ who: { toString: () => "ADA" }, to: ["bob@example.com"] }),
    toJSON: () => ({ who: { toJSON: () => "ada", toString: () => "ada" }, to: ["bob@example.com"] }),
    getter: () => ({ get who() { return "ada"; }, to: ["bob@example.com"] }),
    nestedGetter: () => ({ who: "ada", to: Object.defineProperty([], 0, { get: () => "bob@example.com", enumerable: true }) }),
    date: () => ({ who: "ada", to: [new Date(0)] }),
  };
  try {
    for (const [name, make] of Object.entries(forged)) {
      await p.run("var plD = await sites.plainProbe.send({})");
      globalThis.__plainProbe = make;
      assert.match(await p.error("sites.plainProbe.send(plD.id, { confirm: true })"), /could not read (who|to) back from the site/, `${name} passed as a read-back`);
    }
    assert.deepEqual(acts, [], "a non-plain read-back was written");
    globalThis.__plainProbe = () => ({ who: "Ada", to: ["bob@example.com"] });
    await p.run("var plOk = await sites.plainProbe.send({})");
    await p.value("sites.plainProbe.send(plOk.id, { confirm: true })");
    assert.deepEqual(acts, ["sent"]);
  } finally {
    delete globalThis.__plainProbe;
  }
});

// r21 sites#1: the account is read again right before every write, in the
// loader's commit path, not only where a site tool remembers to ask for
// it. A commit without an { account } reader writes nothing; an act that
// writes without press() or press.input() (each reads the account last)
// fails as unverified; an account that changed before the input sends
// nothing.
test("the commit protocol reads the account again before every write: no reader, no guarded input, or a switched account fails closed", async () => {
  const S = globalThis.CmuxBrowserRepl.sites;
  const acts = [];
  globalThis.__accountNow = "ada";
  S.register(
    "accountProbe",
    (t) => ({
      send(input, options) {
        return t.write("accountProbe", "send", input, options, (m) => ({
          category: "[9] test",
          summary: "account probe",
          account: { who: "ada" },
          content: { mode: m.mode },
          sent: ["mode"],
          commit: (c) => {
            const observe = () => ({ who: "ada" });
            const account = () => ({ who: globalThis.__accountNow });
            if (m.mode === "noReader") return c.write(observe, () => acts.push("noReader"));
            if (m.mode === "unguarded") return c.write(observe, () => acts.push("unguarded"), { account });
            return c.write(observe, (press) => press.input(() => acts.push(m.mode)), { account });
          },
        }));
      },
    }),
    { summary: "test", writes: ["send"] },
  );
  const p = env.session("commit-protocol-account");
  try {
    await p.run('var aNo = await sites.accountProbe.send({ mode: "noReader" }); var aUn = await sites.accountProbe.send({ mode: "unguarded" }); var aSw = await sites.accountProbe.send({ mode: "switched" }); var aOk = await sites.accountProbe.send({ mode: "ok" });');
    assert.match(await p.error("sites.accountProbe.send(aNo.id, { confirm: true })"), /\{ account \} reader/);
    assert.match(await p.error("sites.accountProbe.send(aUn.id, { confirm: true })"), /commit_unverified|without press\(\) or press\.input\(\)/);
    globalThis.__accountNow = "mallory";
    assert.match(await p.error("sites.accountProbe.send(aSw.id, { confirm: true })"), /account it acts as differs from the draft \(who is "mallory", not "ada"\)/);
    globalThis.__accountNow = "ada";
    await p.value("sites.accountProbe.send(aOk.id, { confirm: true })");
    assert.deepEqual(acts, ["unguarded", "ok"], "only the reader-less write was stopped before it acted, and the switched account sent nothing");
    assert.equal((await p.value("sites.drafts.get(aUn.id)")).status, "failed");
  } finally {
    delete globalThis.__accountNow;
  }
});
