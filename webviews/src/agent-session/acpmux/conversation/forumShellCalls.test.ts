// An `agent-forum` shell call becomes the forum row's group (toolGroups.ts `forum`) only when the
// `forum-call-card` experiment is on and the call is one forum command; its text and JSON answers read
// into threads, hits and links (https only).
import { expect, test } from "bun:test";
import { tool } from "../../../gallery/fixtures/acpmux";
import { forumCommand, forumShellCall, forumShellCallShown } from "./forumShellCalls";
import { experimentArm } from "../../../experiments/experiment";
import { settingArms } from "../../../experiments/hostSettings";
import { setExperimentSwitches } from "../../../experiments/switches";
import { translate } from "../i18n";
import { forumCallLook } from "./forumCall.experiment";
import { headLine } from "./ForumCallCard";
import { toolGroups } from "./toolGroups";
import {
  SEARCH_OUTPUT,
  SHOW_OUTPUT,
  askRefusedCall,
  chainedCall,
  closeCall,
  emptySearchCall,
  failedSearchCall,
  jsonSearchCall,
  postCall,
  replyCall,
  searchCall,
  showCall,
} from "./forumShellCalls.fixtures";

const read = (item: ReturnType<typeof tool>) => forumShellCall(item.tool!);

test("off keeps the shell row; on draws the forum row", () => {
  const item = searchCall();
  expect(forumShellCallShown(item, "off")).toBeUndefined();
  expect(forumShellCallShown(item, "card")?.tool).toBe("search");
  expect(toolGroups([item], "off").some((g) => g.type === "forum")).toBe(false);
  const groups = toolGroups([item], "card");
  expect(groups).toHaveLength(1);
  expect(groups[0]).toMatchObject({ type: "forum", look: "card" });
});

test("only one forum command claims the row", () => {
  expect(forumCommand("agent-forum show 12")?.action).toBe("show");
  expect(forumCommand("cd ~/Projects/leo-workspace && agent-forum show 12 | head -40")?.action).toBe("show");
  expect(forumCommand("python3 tools/agent_forum.py search cargo 2>&1 | tail -5")?.query).toBe("cargo");
  expect(forumCommand("FOO=1 ~/.local/bin/agent-forum list --open --limit 5")?.action).toBe("list");
  expect(forumCommand("cd ~; agent-forum show 16774 2>&1 | head -80")?.thread?.number).toBe(16774);
  expect(forumCommand("timeout 60 tools/agent-forum list --open --limit 5 2>&1 | head -12")?.action).toBe("list");
  expect(forumCommand("timeout 60 ~/Projects/leo-workspace/tools/agent_forum.py search pool")?.query).toBe("pool");
  expect(forumCommand("timeout agent-forum show 1")).toBeUndefined();
  expect(forumCommand("agent-forum list --json | python3 -c 'print(1)'")).toBeUndefined();
  expect(forumCommand("agent-forum show 12; git log")).toBeUndefined();
  expect(forumCommand("agent-forum show 12 && agent-forum show 13")).toBeUndefined();
  expect(forumCommand("agent-forum show 12 | xargs echo")).toBeUndefined();
  expect(forumCommand("agent-forum show $(cat n)")).toBeUndefined();
  expect(forumCommand("agent-forum show 12 &")).toBeUndefined();
  expect(forumCommand("agent-forum --weird show 12")).toBeUndefined();
  expect(forumCommand("ls agent-forum")).toBeUndefined();
  expect(forumCommand("echo agent-forum show 1")).toBeUndefined();
  expect(read(chainedCall())).toBeUndefined();
});

test("a search lists its hits with snippets and stops at agent-memory", () => {
  const call = read(searchCall())!;
  expect(call).toMatchObject({ tool: "search", status: "done", query: "cargo cache" });
  expect(call.hits.map((h) => [h.mark, h.number])).toEqual([
    [undefined, 24871],
    ["hosted", 41],
    [undefined, 24102],
  ]);
  expect(call.hits[1]).toMatchObject({ kind: "question", state: "answered", updated: "2026-11-23" });
  expect(call.hits[0]!.snippet).toStartWith("Two pushes");
});

test("a running search has no hits yet; an empty one finds none", () => {
  expect(read(searchCall("in_progress"))).toMatchObject({ status: "running", hits: [] });
  expect(read(emptySearchCall())).toMatchObject({ status: "done", hits: [], query: "warm image tailscale" });
});

test("show reads the thread, its link, its replies and its opening", () => {
  const call = read(showCall())!;
  expect(call.thread).toMatchObject({ number: 24871, kind: "finding", state: "open", comments: 2 });
  expect(call.thread!.url).toBe("https://github.com/manaflow-ai/cmuxterm-hq/issues/24871");
  expect(call.body).toStartWith("Two pushes inside a minute");
  expect(call.body!.split("\n")).toHaveLength(2);
  expect(read(showCall("in_progress"))!.thread).toEqual({ number: 24871, mark: undefined });
});

test("post reads the heredoc body and the posted thread", () => {
  const running = read(postCall("in_progress"))!;
  expect(running.thread).toMatchObject({
    title: "Compile pool drains in 40 s when a lane pushes twice",
    kind: "finding",
  });
  expect(running.body).toStartWith("Two pushes");
  const done = read(postCall())!;
  expect(done.thread).toMatchObject({ number: 24871, kind: "finding" });
  expect(done.thread!.url).toStartWith("https://");
});

test("a topic that went to an open thread is a reply", () => {
  const item = tool("Run", "execute", "completed", {
    command: "agent-forum topic fleet-pool 'Pool drains'",
    output: "replied on #24871 (topic fleet-pool): https://github.com/o/r/issues/24871#issuecomment-1",
    exitCode: 0,
  });
  expect(read(item)).toMatchObject({ tool: "reply", thread: { number: 24871 } });
});

test("reply and close name their thread", () => {
  expect(read(replyCall())).toMatchObject({ tool: "reply", thread: { number: 24871 } });
  expect(read(replyCall())!.body).toStartWith("Fixed by");
  expect(read(closeCall())).toMatchObject({ tool: "close", thread: { number: 24555, state: "closed" } });
  const open = tool("Run", "execute", "completed", {
    command: "agent-forum close 9 'answer'",
    output: "answered #9; not closed: not this lane's thread",
    exitCode: 0,
  });
  expect(read(open)).toMatchObject({ stillOpen: true, thread: { number: 9 } });
});

test("a refused ask points at the open thread", () => {
  const call = read(askRefusedCall())!;
  expect(call).toMatchObject({ refused: true, status: "failed", thread: { number: 24555 } });
  expect(call.thread!.title).toStartWith("Does the Linux pool");
});

test("a failed call says why in the CLI's words", () => {
  expect(read(failedSearchCall())).toMatchObject({
    status: "failed",
    error: "the hosted forum did not answer (timed out after 10 s)",
  });
});

test("--json answers read the same, and only https links draw", () => {
  const call = read(jsonSearchCall())!;
  expect(call.hits[0]).toMatchObject({
    number: 41,
    mark: "hosted",
    url: "https://forum.example.com/t/41",
    updated: "2026-11-23",
  });
  expect(call.hits[1]!.url).toBeUndefined();
});

test("an answer a filter may have cut names no count", () => {
  const cut = (command: string, output: string) =>
    read(tool("Run", "execute", "completed", { command, output, exitCode: 0 }));
  const lines = SEARCH_OUTPUT.split("\n");
  // `head -2` printed 2 lines: there may be more.
  expect(cut("agent-forum search cache | head -2", lines.slice(0, 2).join("\n"))!.partial).toBe(true);
  // `head -40` printed fewer than 40: that is the whole answer, counted.
  const whole = cut("agent-forum search cache | head -40", SEARCH_OUTPUT)!;
  expect(whole.partial).toBeUndefined();
  expect(whole.hits).toHaveLength(3);
  // `grep` drops any line it likes.
  const grepped = cut("agent-forum search cache | grep open", lines[0]!)!;
  expect(grepped.partial).toBe(true);
  expect(headLine(translate, grepped)).toBe(translate("forumCall.searched", { query: "cache" }));
  expect(headLine(translate, whole)).toBe(translate("forumCall.found.other", { count: "3", query: "cache" }));
  const show = cut("agent-forum show 24871 | head -2", SHOW_OUTPUT.split("\n").slice(0, 2).join("\n"))!;
  expect(show).toMatchObject({ partial: true, thread: { number: 24871 } });
  expect(show.thread!.comments).toBeUndefined();
});

test("Settings > Customize > Forum Tool Calls turns on the card arm", () => {
  try {
    expect(experimentArm(forumCallLook, { overrides: {}, stored: {} })).toBe("off");
    setExperimentSwitches({ forumCallCard: true });
    expect(settingArms()).toMatchObject({ "forum-call-card": "card" });
    expect(experimentArm(forumCallLook, { overrides: {}, stored: {} })).toBe("card");
  } finally {
    setExperimentSwitches({});
  }
});
