import { describe, expect, test } from "bun:test";

const variants = () => import("../src/agent-session/acpmux/modelVariants");

describe("groupVariants", () => {
  test("case-distinct bare IDs remain separate selectable models", async () => {
    const { groupVariants } = await variants();
    const models = [
      { id: "custom-A", name: "Custom A" },
      { id: "custom-a", name: "Custom a" },
      { id: "custom-A", name: "Custom A", unavailable: "offline" },
    ];
    expect(groupVariants(models).map((group) => group.model.id)).toEqual(["custom-A", "custom-a"]);
  });
  const rows = [
    { id: "opencode/deepseek-v4-pro", name: "DeepSeek V4 Pro [New]" },
    { id: "openrouter/deepseek/deepseek-v4-pro", name: "OpenRouter/DeepSeek V4 Pro" },
    { id: "deepseek/deepseek-v4-pro", name: "DeepSeek/DeepSeek V4 Pro" },
    { id: "openrouter/deepseek/deepseek-chat", name: "OpenRouter/DeepSeek Chat" },
    { id: "claude-opus-5-5", name: "Opus 5.5" },
    { id: "claude-opus-5-5-copy", name: "Opus 5.5" },
  ];

  test("a provider's row names its provider, its model and its note", async () => {
    const { providerOf } = await variants();
    expect(providerOf(rows[0]!)).toEqual({
      provider: "OpenCode",
      key: "deepseek-v4-pro",
      name: "DeepSeek V4 Pro",
      tag: "New",
    });
    expect(providerOf(rows[1]!)).toEqual({
      provider: "OpenRouter",
      key: "deepseek-v4-pro",
      name: "DeepSeek V4 Pro",
    });
    expect(providerOf(rows[4]!)).toEqual({ key: "claude-opus-5-5", name: "Opus 5.5" });
  });

  test("the rows of one model are one, in first-row order; a bare id is its own model", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants(rows);
    expect(groups.map((group) => [group.name, group.offers.map((offer) => offer.provider)])).toEqual([
      ["DeepSeek V4 Pro", ["OpenCode", "OpenRouter", "DeepSeek"]],
      ["DeepSeek Chat", ["OpenRouter"]],
      ["Opus 5.5", [""]],
      ["Opus 5.5", [""]],
    ]);
    expect(groups[0]!.model.id).toBe("opencode/deepseek-v4-pro");
    expect(groups[0]!.tag).toBe("New");
  });

  test("one provider's two rows with the same last id part are two models", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
      { id: "openrouter/mistral/coder-3", name: "OpenRouter/Coder 3" },
      { id: "together/qwen/coder-3", name: "Together/Coder 3" },
    ]);
    expect(groups.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3", "together/qwen/coder-3"],
      ["openrouter/mistral/coder-3"],
    ]);
  });

  // Primary review at 68a5f69a: the third row joined the Qwen model, so its Together row would land
  // Mistral's model in place of Qwen's.
  test("a provider's row joins the model of its own owner, not the first with the same last id part", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
      { id: "openrouter/mistral/coder-3", name: "OpenRouter/Coder 3" },
      { id: "together/mistral/coder-3", name: "Together/Coder 3" },
    ]);
    expect(groups.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3"],
      ["openrouter/mistral/coder-3", "together/mistral/coder-3"],
    ]);
  });

  test("a row that names no owner joins only the one model it can be", async () => {
    const { groupVariants } = await variants();
    // Two owners serve a coder-3: a bare row names neither, so it stays its own model.
    const ambiguous = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
      { id: "together/mistral/coder-3", name: "Together/Coder 3" },
      { id: "groq/coder-3", name: "Groq/Coder 3" },
    ]);
    expect(ambiguous.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3"],
      ["together/mistral/coder-3"],
      ["groq/coder-3"],
    ]);
    // An owner's own bare row ("mistral/coder-3") is that owner's model.
    const owned = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
      { id: "together/mistral/coder-3", name: "Together/Coder 3" },
      { id: "mistral/coder-3", name: "Mistral/Coder 3" },
    ]);
    expect(owned.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3"],
      ["together/mistral/coder-3", "mistral/coder-3"],
    ]);
    // One owner: every provider's row is that model, bare rows included, whichever comes first.
    const one = groupVariants([
      { id: "opencode/deepseek-v4-pro", name: "DeepSeek V4 Pro" },
      { id: "openrouter/deepseek/deepseek-v4-pro", name: "OpenRouter/DeepSeek V4 Pro" },
      { id: "deepseek/deepseek-v4-pro", name: "DeepSeek/DeepSeek V4 Pro" },
    ]);
    expect(one.map((group) => group.offers.map((offer) => offer.provider))).toEqual([
      ["OpenCode", "OpenRouter", "DeepSeek"],
    ]);
  });

  test("the running provider's row is the one its model lands", async () => {
    const { groupVariants } = await variants();
    expect(groupVariants(rows, "deepseek/deepseek-v4-pro")[0]!.model.id).toBe("deepseek/deepseek-v4-pro");
  });

  test("a bare model's bracketed tag is not repeated in its group name", async () => {
    const { groupVariants } = await variants();
    expect(groupVariants([{ id: "claude-opus-5-5", name: "Opus 5.5 [New]" }])).toMatchObject([
      { name: "Opus 5.5", tag: "New" },
    ]);
  });

  test("duplicate provider rows stay one offer and preserve the running row", async () => {
    const { groupVariants } = await variants();
    const rows = [
      { id: "openrouter/qwen/Coder-3", name: "OpenRouter/Coder 3" },
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
    ];
    const groups = groupVariants(rows, rows[1]!.id);
    expect(groups).toHaveLength(1);
    expect(groups[0]!.offers).toHaveLength(1);
    expect(groups[0]!.offers[0]!.model.id).toBe(rows[1]!.id);
    expect(groups[0]!.model.id).toBe(rows[1]!.id);
  });

  test("duplicate provider retention chooses an available row in either order", async () => {
    const { groupVariants } = await variants();
    const available = { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" };
    const unavailable = {
      id: "openrouter/qwen/Coder-3",
      name: "OpenRouter/Coder 3",
      unavailable: "offline",
    };
    for (const rows of [
      [available, unavailable],
      [unavailable, available],
    ]) {
      const groups = groupVariants(rows, unavailable.id);
      expect(groups[0]!.offers[0]!.model.id).toBe(available.id);
    }
  });

  test("ambiguous owner aliases stay grouped by provider and preserve distinct providers", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "Qwen/Coder 3" },
      { id: "together/mistral/coder-3", name: "Mistral/Coder 3" },
      { id: "groq/Coder-3", name: "Groq/Coder 3" },
      { id: "groq/coder-3", name: "Groq/Coder 3" },
    ]);
    expect(groups).toHaveLength(3);
    expect(groups.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3"],
      ["together/mistral/coder-3"],
      ["groq/Coder-3"],
    ]);
  });

  test("provider identity deduplicates by path while retaining distinct routes", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "Qwen/Coder 3" },
      { id: "together/qwen/coder-3", name: "Qwen/Coder 3" },
      { id: "openrouter/qwen/Coder-3", name: "Qwen/Coder 3" },
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0]!.offers.map((offer) => offer.model.id)).toEqual([
      "openrouter/qwen/coder-3",
      "together/qwen/coder-3",
    ]);
  });

  test("provider labels follow the route when names carry an owner", async () => {
    const { providerOf } = await variants();
    expect(providerOf({ id: "openrouter/qwen/coder-3", name: "Qwen/Coder 3" }).provider).toBe("OpenRouter");
    expect(providerOf({ id: "together/mistral/coder-3", name: "Mistral/Coder 3" }).provider).toBe("Together");
  });
});
