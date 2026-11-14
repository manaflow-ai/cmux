import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { EnvironmentStore } from "./environmentStore";
import type { CloudEnvironment, EnvironmentPatch, EnvironmentSection } from "./environmentModel";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  DocumentFragment: dom.window.DocumentFragment,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const [{ createRoot }, { EnvironmentSheet }] = await Promise.all([
  import("react-dom/client"),
  import("./EnvironmentSheet"),
]);
const strings = createStrings(table, ["en"]);
const settle = async () => {
  for (let i = 0; i < 12; i++) await Promise.resolve();
};

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
});

const sample: CloudEnvironment = {
  id: "env_example",
  scope: "personal",
  name: "Default",
  is_default: true,
  setup_script: null,
  env_vars: [],
  secrets: [{ name: "PACKAGE_TOKEN", updated_at: "2026-11-01T00:00:00Z" }],
  network: { mode: "full", package_managers: true, domains: [] },
  created_at: "2026-11-01T00:00:00Z",
  updated_at: "2026-11-01T00:00:00Z",
  updated_by: "user_example",
};
async function mount(
  section: EnvironmentSection = "overview",
  environment: CloudEnvironment = sample,
  refusal?: string,
) {
  const writes: EnvironmentPatch[] = [];
  const store = new EnvironmentStore({
    list: async () => [environment],
    get: async () => environment,
    update: async (_id, patch) => {
      writes.push(patch);
      // The daemon forwards a refusal's code only, with a message of its own.
      if (refusal) throw Object.assign(new Error("Could not save or load the cloud environment."), { code: refusal });
      return environment;
    },
    derive: async () => ({ setup: { script: "#!/bin/bash\nnpm ci\n" } }),
  });
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => {
    root.render(<EnvironmentSheet store={store} strings={strings} />);
    await store.open({ section, repo: "example/project" });
    await settle();
  });
  return {
    store,
    writes,
    async dispose() {
      await act(async () => root.unmount());
      container.remove();
    },
  };
}
const button = (label: string) =>
  Array.from(document.querySelectorAll<HTMLButtonElement>("button")).find(
    (node) => node.getAttribute("aria-label") === label || node.textContent?.includes(label),
  );

test("summary rows drill in and back to the same draft; Cancel never writes", async () => {
  const mounted = await mount();
  try {
    expect(document.querySelector<HTMLInputElement>(".env-field input")?.readOnly).toBe(true);
    for (const label of ["Network access", "Network secrets", "Setup script", "Environment variables"]) {
      await act(async () => {
        button(label)!.click();
      });
      expect(document.querySelector(".env-heading h2")?.textContent).toBe(label);
      if (label === "Network secrets") {
        const secret = document.querySelector<HTMLInputElement>('input[type="password"]');
        expect(secret?.value).toBe("");
        expect(document.querySelector<HTMLInputElement>('input[aria-label="Secret name"]')?.value).toBe(
          "PACKAGE_TOKEN",
        );
      }
      await act(async () => {
        button("Back to environment")!.click();
      });
      expect(document.querySelector(".env-heading h2")?.textContent).toBe("Edit cloud environment");
    }
    await act(async () => {
      mounted.store.edit({ script: "echo unsaved" });
      button("Cancel")!.click();
    });
    expect(mounted.store.getSnapshot().open).toBe(false);
    expect(mounted.writes).toEqual([]);
  } finally {
    await mounted.dispose();
  }
});

test("the checklist entry displays the derived Bash script and backs into the cog overview", async () => {
  const mounted = await mount("script");
  try {
    expect(document.querySelector<HTMLTextAreaElement>(".env-code textarea")?.value).toBe("#!/bin/bash\nnpm ci\n");
    expect(document.querySelector(".env-code pre")?.textContent).toBe("1\n2\n3");
    expect(document.querySelector(".env-editor-foot")?.textContent).toBe("Files up to 64 KB");
    expect(document.querySelector(".env-note")?.textContent).toContain("before the agent launches");
    await act(async () => {
      button("Back to environment")!.click();
    });
    expect(document.querySelector(".env-heading h2")?.textContent).toBe("Edit cloud environment");
    await act(async () => {
      button("Save changes")!.click();
      await settle();
    });
    expect(mounted.writes).toEqual([]);
    expect(mounted.store.getSnapshot().open).toBe(false);
  } finally {
    await mounted.dispose();
  }
});

test("without the service's support for secret routes, a secret row has no delivery controls", async () => {
  const mounted = await mount("secrets");
  try {
    expect(document.querySelector('input[aria-label="Secret name"]')).not.toBeNull();
    expect(document.querySelector('input[aria-label="Sent to"]')).toBeNull();
    expect(document.querySelector(".env-secret")).toBeNull();
  } finally {
    await mounted.dispose();
  }
});

test("a secret stored without hosts loads invalid and blocks Save; one host makes it valid", async () => {
  const mounted = await mount("secrets", { ...sample, secret_routes: true });
  try {
    const hosts = document.querySelector<HTMLInputElement>('input[aria-label="Sent to"]');
    expect(hosts?.value).toBe("");
    expect(hosts?.getAttribute("aria-invalid")).toBe("true");
    const sentence = "A secret needs at least one host. For a value the machine reads itself, use a variable.";
    expect(document.querySelector(".env-secret .env-error")?.textContent).toBe(sentence);
    // Every secret has hosts, so its header line is always there, closed.
    const disclosure = document.querySelector<HTMLButtonElement>(".env-secret > .env-disclosure");
    expect(disclosure?.getAttribute("aria-expanded")).toBe("false");
    await act(async () => {
      button("Save changes")!.click();
      await settle();
    });
    expect(mounted.writes).toEqual([]);
    expect(mounted.store.getSnapshot().error).toBe("hostless");
    expect(document.querySelectorAll(".env-error")).toHaveLength(2);
    expect([...document.querySelectorAll(".env-error")].every((node) => node.textContent === sentence)).toBe(true);
    // Not flagged while Sent to has focus: a half-typed list is not an error yet.
    await act(async () => hosts!.focus());
    expect(hosts?.getAttribute("aria-invalid")).toBeNull();
    await act(async () => hosts!.blur());
    await act(async () => {
      mounted.store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "tok", hosts: "registry.example.com" }] });
    });
    expect(hosts?.getAttribute("aria-invalid")).toBeNull();
    expect(document.querySelector(".env-secret .env-error")).toBeNull();
  } finally {
    await mounted.dispose();
  }
});

test("a new blank secret row is not flagged yet; named without a host it is, and Save refuses it", async () => {
  const stored = { name: "PACKAGE_TOKEN", updated_at: "2026-11-01T00:00:00Z", hosts: ["registry.example.com"] };
  const mounted = await mount("secrets", { ...sample, secret_routes: true, secrets: [stored] });
  try {
    await act(async () => document.querySelector<HTMLButtonElement>(".env-add")!.click());
    const fields = () => document.querySelectorAll<HTMLInputElement>('input[aria-label="Sent to"]');
    expect(fields()).toHaveLength(2);
    expect(fields()[1]?.getAttribute("aria-invalid")).toBeNull();
    await act(async () => {
      mounted.store.edit({
        secrets: [
          { name: "PACKAGE_TOKEN", value: "", hosts: "registry.example.com" },
          { name: "DEPLOY_KEY", value: "key" },
        ],
      });
    });
    expect(fields()[0]?.getAttribute("aria-invalid")).toBeNull();
    expect(fields()[1]?.getAttribute("aria-invalid")).toBe("true");
    await act(async () => {
      button("Save changes")!.click();
      await settle();
    });
    expect(mounted.writes).toEqual([]);
    expect(mounted.store.getSnapshot().error).toBe("hostless");
  } finally {
    await mounted.dispose();
  }
});

test("a secret's header opens under its hosts, and an invalid host shows inline and blocks Save", async () => {
  const mounted = await mount("secrets", { ...sample, secret_routes: true });
  try {
    const hosts = document.querySelector<HTMLInputElement>('input[aria-label="Sent to"]');
    await act(async () => {
      mounted.store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "tok", hosts: "registry.example.com" }] });
    });
    expect(document.querySelector(".env-header-summary")?.textContent).toBe("authorization: Bearer {value}");
    const disclosure = document.querySelector<HTMLButtonElement>(".env-disclosure");
    const fields = document.querySelector(".env-secret > .env-fold");
    expect(disclosure?.getAttribute("aria-expanded")).toBe("false");
    expect(fields?.hasAttribute("inert")).toBe(true);
    await act(async () => disclosure!.click());
    expect(disclosure?.getAttribute("aria-expanded")).toBe("true");
    expect(fields?.hasAttribute("data-open")).toBe(true);
    expect(document.querySelector<HTMLInputElement>('input[aria-label="Header name"]')?.value).toBe("authorization");
    await act(async () => {
      mounted.store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "tok", hosts: "https://registry.example.com" }] });
    });
    expect(hosts?.getAttribute("aria-invalid")).toBe("true");
    expect(document.querySelector(".env-secret .env-error")?.textContent).toContain("up to 8 host names");
    await act(async () => {
      button("Save changes")!.click();
      await settle();
    });
    expect(mounted.writes).toEqual([]);
    expect(mounted.store.getSnapshot().error).toBe("hosts");
  } finally {
    await mounted.dispose();
  }
});

test("removing a secret row keeps every other row's open header with its own secret", async () => {
  const route = (name: string, host: string) => ({ name, updated_at: "2026-11-01T00:00:00Z", hosts: [host] });
  const mounted = await mount("secrets", {
    ...sample,
    secret_routes: true,
    secrets: [route("PACKAGE_TOKEN", "registry.example.com"), route("GITHUB_TOKEN", "api.github.com")],
  });
  try {
    const secretRows = () => [...document.querySelectorAll<HTMLElement>(".env-secret")];
    const nameOf = (row: HTMLElement) => row.querySelector<HTMLInputElement>('input[aria-label="Secret name"]')?.value;
    const disclosureOf = (row: HTMLElement) => row.querySelector<HTMLButtonElement>(":scope > .env-disclosure");
    expect(secretRows().map(nameOf)).toEqual(["PACKAGE_TOKEN", "GITHUB_TOKEN"]);
    await act(async () => disclosureOf(secretRows()[1]!)!.click());
    expect(secretRows().map((row) => disclosureOf(row)?.getAttribute("aria-expanded"))).toEqual(["false", "true"]);
    await act(async () => button("Remove PACKAGE_TOKEN")!.click());
    expect(secretRows().map(nameOf)).toEqual(["GITHUB_TOKEN"]);
    expect(disclosureOf(secretRows()[0]!)?.getAttribute("aria-expanded")).toBe("true");
    // A row added after it starts closed.
    await act(async () => document.querySelector<HTMLButtonElement>(".env-add")!.click());
    expect(secretRows().map((row) => disclosureOf(row)?.getAttribute("aria-expanded"))).toEqual(["true", "false"]);
    expect(mounted.store.getSnapshot().draft?.secrets.map((row) => row.name)).toEqual(["GITHUB_TOKEN", ""]);
  } finally {
    await mounted.dispose();
  }
});

// A secret sent to hosts is written to the secret store on save (cmux-platform#1046); its refusals reach the sheet as
// vault.* codes, and the alert at the foot says why in a plain sentence.
const unavailable = "Secrets can't be saved right now. Try again in a moment.";
const refused = "The secret couldn't be stored. Your edits are kept; check its name and hosts, or try again later.";
const vaultSentences: Record<string, string> = {
  "vault.unavailable": unavailable,
  "vault.unreachable": unavailable,
  "vault.upstream_failed": unavailable,
  "vault.not_configured": unavailable,
  "vault.pin_public_suffix":
    "A host can't cover every site under a public suffix like .com or .co.uk. Name the exact host, such as api.example.com.",
  "vault.secret_not_ascii":
    "A secret sent as Basic credentials must be plain text: ASCII letters, numbers and symbols only.",
  "vault.secret_unreadable": "A saved secret can't be read anymore. Type its value again, then save.",
  "vault.grant_refused": refused,
  "vault.request_rejected": refused,
  // Only a machine's start gives these, or the platform adds one later: the generic save sentence.
  "vault.boot_superseded": "Could not save changes. Your edits are kept; try again.",
  "vault.something_new": "Could not save changes. Your edits are kept; try again.",
};

for (const [code, sentence] of Object.entries(vaultSentences)) {
  test(`a save the secret store refuses with ${code} says why at the foot and keeps the edits`, async () => {
    const mounted = await mount("overview", sample, code);
    try {
      await act(async () => {
        mounted.store.edit({ script: "echo unsaved" });
        button("Save changes")!.click();
        await settle();
      });
      expect(mounted.writes).toHaveLength(1);
      expect(mounted.store.getSnapshot().open).toBe(true);
      expect(mounted.store.getSnapshot().draft?.script).toBe("echo unsaved");
      expect(document.querySelector('[role="alert"]')?.textContent).toBe(sentence);
    } finally {
      await mounted.dispose();
    }
  });
}
