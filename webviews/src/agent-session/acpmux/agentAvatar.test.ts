import { afterEach, describe, expect, test } from "bun:test";
import { agentAvatarChanged, hasAgentAvatar, loadAgentAvatar, removeAgentAvatar, setAgentAvatar, setAgentAvatarHost } from "./agentAvatar";
import { avatarRows } from "./header/avatarRow";

const PNG = "data:image/png;base64,AAAA";

afterEach(() => setAgentAvatarHost(undefined));

describe("agent avatars", () => {
  test("Set Avatar… keeps the host's picture, Remove forgets it, and a non-image answer is ignored", async () => {
    const asked: [string, Record<string, unknown>][] = [];
    let answer: unknown = { src: PNG };
    setAgentAvatarHost(async (method, params) => {
      asked.push([method, params]);
      return method === "agent.avatar.set" ? answer : {};
    });
    await setAgentAvatar("s1");
    expect(hasAgentAvatar("s1")).toBe(true);
    await removeAgentAvatar("s1");
    expect(hasAgentAvatar("s1")).toBe(false);
    answer = { src: "javascript:alert(1)" };
    await setAgentAvatar("s1");
    expect(hasAgentAvatar("s1")).toBe(false);
    expect(asked.map(([method]) => method)).toEqual(["agent.avatar.set", "agent.avatar.remove", "agent.avatar.set"]);
    expect(asked[0]?.[1]).toEqual({ sessionId: "s1" });
  });

  test("a read that started before Remove or Set keeps nothing", async () => {
    const reads: ((reply: unknown) => void)[] = [];
    setAgentAvatarHost((method) =>
      method === "agent.avatar"
        ? new Promise((resolve) => reads.push(resolve))
        : Promise.resolve(method === "agent.avatar.set" ? { src: `${PNG}B` } : {}),
    );
    const stale = loadAgentAvatar("s1");
    await Promise.resolve();
    await removeAgentAvatar("s1");
    reads[0]?.({ src: PNG });
    await stale;
    expect(hasAgentAvatar("s1")).toBe(false);
    const older = loadAgentAvatar("s1");
    await Promise.resolve();
    await setAgentAvatar("s1");
    reads[1]?.({ src: PNG });
    expect(await older).toBe(`${PNG}B`);
    expect(hasAgentAvatar("s1")).toBe(true);
  });

  test("a change in another pane is asked for again; the old picture stays until the answer, and a failed answer keeps none", async () => {
    let stored: string | null = PNG;
    let connected = true;
    setAgentAvatarHost(async (method) => {
      if (!connected) throw new Error("page not connected");
      return method === "agent.avatar" ? { src: stored } : {};
    });
    expect(await loadAgentAvatar("s2")).toBe(PNG);
    stored = null;
    agentAvatarChanged("s2");
    expect(hasAgentAvatar("s2")).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(hasAgentAvatar("s2")).toBe(false);
    stored = PNG;
    expect(await loadAgentAvatar("s3")).toBe(PNG);
    connected = false;
    agentAvatarChanged("s3");
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(hasAgentAvatar("s3")).toBe(false);
    agentAvatarChanged("never-drawn");
    expect(hasAgentAvatar("never-drawn")).toBe(false);
  });

  test("the menu offers Set Avatar…, Remove Avatar only with one, and nothing without a session", () => {
    const t = (key: string) => key;
    const actions = { set: () => undefined, remove: () => undefined };
    expect(avatarRows({ sessionId: undefined, hasAvatar: false }, actions, t)).toEqual([]);
    expect(avatarRows({ sessionId: "s", hasAvatar: false }, actions, t).map((row) => row.key)).toEqual(["setAvatar"]);
    expect(avatarRows({ sessionId: "s", hasAvatar: true }, actions, t).map((row) => row.key)).toEqual([
      "setAvatar",
      "removeAvatar",
    ]);
  });
});
