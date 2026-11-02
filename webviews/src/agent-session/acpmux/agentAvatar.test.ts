import { afterEach, describe, expect, test } from "bun:test";
import {
  agentAvatarChanged,
  drawAgentAvatar,
  hasAgentAvatar,
  loadAgentAvatar,
  removeAgentAvatar,
  setAgentAvatar,
  setAgentAvatarHost,
} from "./agentAvatar";
import { avatarRows } from "./header/avatarRow";

const PNG = "data:image/png;base64,AAAA";

afterEach(() => setAgentAvatarHost(undefined));

/// A host that keeps one picture per session, as AgentAvatars does: Set stores the chosen one, Remove
/// deletes it, and `agent.avatar` answers what is kept. `hold` delays the named method's replies.
function host(choose: () => unknown = () => ({ src: PNG })) {
  const kept = new Map<string, string>();
  const held: (() => void)[] = [];
  const state = { hold: "" as string, connected: true, asked: [] as string[] };
  const reply = async (method: string, params: Record<string, unknown>) => {
    state.asked.push(method);
    if (!state.connected) throw new Error("page not connected");
    const id = String(params.sessionId);
    if (method === "agent.avatar.set") {
      const picked = choose() as { src?: unknown } | undefined;
      if (typeof picked?.src === "string") kept.set(id, picked.src);
      return picked;
    }
    if (method === "agent.avatar.remove") {
      kept.delete(id);
      return {};
    }
    return { src: kept.get(id) ?? null };
  };
  setAgentAvatarHost((method, params) => {
    const answer = reply(method, params);
    if (method !== state.hold) return answer;
    return new Promise((resolve) => held.push(() => resolve(answer)));
  });
  return { kept, held, state };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("agent avatars", () => {
  test("Set Avatar… draws what the host keeps, Remove forgets it, and a non-image answer is ignored", async () => {
    let answer: unknown = { src: PNG };
    const { state } = host(() => answer);
    await setAgentAvatar("s1");
    expect(hasAgentAvatar("s1")).toBe(true);
    await removeAgentAvatar("s1");
    expect(hasAgentAvatar("s1")).toBe(false);
    answer = { src: "javascript:alert(1)" };
    await setAgentAvatar("s1");
    expect(hasAgentAvatar("s1")).toBe(false);
    expect(state.asked).toEqual([
      "agent.avatar.set",
      "agent.avatar",
      "agent.avatar.remove",
      "agent.avatar",
      "agent.avatar.set",
    ]);
  });

  test("a read that started before Remove or Set keeps nothing", async () => {
    const { kept, held, state } = host(() => ({ src: `${PNG}B` }));
    kept.set("s1", PNG);
    state.hold = "agent.avatar";
    const stale = loadAgentAvatar("s1");
    await tick();
    state.hold = "";
    await removeAgentAvatar("s1");
    held.shift()?.();
    await stale;
    expect(hasAgentAvatar("s1")).toBe(false);
    kept.set("s1", PNG);
    state.hold = "agent.avatar";
    const older = loadAgentAvatar("s1");
    await tick();
    state.hold = "";
    await setAgentAvatar("s1");
    held.shift()?.();
    expect(await older).toBe(`${PNG}B`);
    expect(hasAgentAvatar("s1")).toBe(true);
  });

  test("a slow Set reply after another pane's Remove, or a slow Remove after a Set, never undoes the newer change", async () => {
    const { kept, held, state } = host(() => ({ src: PNG }));
    state.hold = "agent.avatar.set";
    const slowSet = setAgentAvatar("s4");
    await tick();
    state.hold = "";
    kept.delete("s4");
    agentAvatarChanged("s4");
    held.shift()?.();
    await slowSet;
    await tick();
    expect(hasAgentAvatar("s4")).toBe(false);

    kept.set("s5", PNG);
    expect(await loadAgentAvatar("s5")).toBe(PNG);
    state.hold = "agent.avatar.remove";
    const slowRemove = removeAgentAvatar("s5");
    await tick();
    state.hold = "";
    kept.set("s5", `${PNG}C`);
    agentAvatarChanged("s5");
    await tick();
    held.shift()?.();
    await slowRemove;
    await tick();
    expect(hasAgentAvatar("s5")).toBe(true);
    expect(await loadAgentAvatar("s5")).toBe(`${PNG}C`);
  });

  test("a change in another pane is asked for again; the old picture stays until the answer, and a failed answer keeps none", async () => {
    const { kept, state } = host();
    kept.set("s2", PNG);
    expect(await loadAgentAvatar("s2")).toBe(PNG);
    kept.delete("s2");
    agentAvatarChanged("s2");
    expect(hasAgentAvatar("s2")).toBe(true);
    await tick();
    expect(hasAgentAvatar("s2")).toBe(false);
    kept.set("s3", PNG);
    expect(await loadAgentAvatar("s3")).toBe(PNG);
    state.connected = false;
    agentAvatarChanged("s3");
    await tick();
    expect(hasAgentAvatar("s3")).toBe(false);
    agentAvatarChanged("never-drawn");
    expect(hasAgentAvatar("never-drawn")).toBe(false);
  });

  test("a card still drawing a session after a failed read gets a later Set from another pane", async () => {
    const { kept, state } = host();
    const stop = drawAgentAvatar("s6");
    state.connected = false;
    expect(await loadAgentAvatar("s6")).toBe(null);
    expect(hasAgentAvatar("s6")).toBe(false);
    state.connected = true;
    kept.set("s6", PNG);
    agentAvatarChanged("s6");
    await tick();
    expect(hasAgentAvatar("s6")).toBe(true);
    stop();
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
