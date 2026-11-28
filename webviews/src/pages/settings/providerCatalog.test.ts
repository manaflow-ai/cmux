import { canAddProvider, cloudProviderForFamily, providerById } from "./providerCatalog";
import { expect, test } from "bun:test";
import { providerCatalog, providerGroupName, providerGroups, searchProviders } from "./providerCatalog";

test("the catalog has distinct providers and at least one entry in each group", () => {
  expect(new Set(providerCatalog.map(({ id }) => id)).size).toBe(providerCatalog.length);
  for (const group of providerGroups) expect(providerCatalog.some((provider) => provider.group === group)).toBe(true);
});

test("provider links use HTTPS except for local loopback endpoints", () => {
  for (const provider of providerCatalog) {
    for (const value of [provider.baseUrl, provider.keyUrl, provider.docsUrl]) {
      if (!value) continue;
      const url = new URL(value);
      expect(url.username).toBe("");
      expect(url.password).toBe("");
      if (provider.group === "local" && value === provider.baseUrl && url.protocol === "http:") {
        expect(url.hostname).toBe("localhost");
      } else {
        expect(url.protocol).toBe("https:");
      }
    }
  }
});

test("the Settings browser admits exactly the catalog's key pages", async () => {
  const catalogUrls = new Set(
    providerCatalog.flatMap(({ keyUrl, regions }) => [
      ...(keyUrl ? [keyUrl] : []),
      ...(regions?.map((region) => region.keyUrl) ?? []),
    ]),
  );
  const policyFile = new URL(
    "../../../../Packages/macOS/CmuxNext/Sources/CmuxNextSettingsWindow/SettingsModelKeyPages.swift",
    import.meta.url,
  );
  const swift = await Bun.file(policyFile).text();
  const nativeUrls = new Set(Array.from(swift.matchAll(/"(https:\/\/[^"]+)"/g), ([, url]) => url));
  expect([...nativeUrls].sort()).toEqual([...catalogUrls].sort());
});

test("search finds providers by name, group and host", () => {
  expect(searchProviders("API.DEEPSEEK.COM").map(({ id }) => id)).toEqual(["deepseek"]);
  expect(searchProviders("moonshot kimi").map(({ id }) => id)).toEqual(["kimi-code", "moonshot"]);
  expect(searchProviders(providerGroupName("codingPlans"))).toEqual(
    providerCatalog.filter((provider) => provider.group === "codingPlans"),
  );
  expect(searchProviders("localhost").map(({ id }) => id)).toEqual(["ollama", "lm-studio"]);
});

test("subscription families resolve to their Cloud provider", () => {
  expect(cloudProviderForFamily("codex")).toBe("chatgpt");
  expect(cloudProviderForFamily("claude")).toBe("claude");
  expect(cloudProviderForFamily("grok")).toBe("xai");
  expect(cloudProviderForFamily("github-copilot")).toBeUndefined();
  expect(cloudProviderForFamily("kimi-code")).toBeUndefined();
  expect(cloudProviderForFamily("cursor")).toBeUndefined();
  expect(cloudProviderForFamily("cursor-agent")).toBeUndefined();
});

test("Cloud Connect only offers launchable keys and plans", () => {
  const offers = (id: string, cloud: boolean) => canAddProvider(providerById(id)!, cloud);
  for (const id of [
    "grok",
    "copilot",
    "kimi-code",
    "endpoint",
    "deepseek",
    "moonshot",
    "opencode-go",
    "openrouter",
    "bedrock",
  ]) {
    expect(offers(id, false)).toBe(true);
    expect(offers(id, true)).toBe(false);
  }
  expect(offers("ollama", true)).toBe(false);
  for (const id of ["chatgpt", "claude", "anthropic", "openai", "google", "vertex-express", "xai"]) {
    expect(offers(id, true)).toBe(true);
  }
});
test("Qwen uses the international endpoint", () => {
  expect(providerById("qwen")?.baseUrl).toBe("https://dashscope-intl.aliyuncs.com/compatible-mode/v1");
});
