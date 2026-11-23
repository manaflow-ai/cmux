// Settings > Agent Chat > Message Box: the dictation engine's key card under the dictation rows. Each
// engine state draws its own shape (on-device: one line; a keyless server: its URL and Check; a keyed
// provider: a password field, or Key saved with Replace and Remove); Save sends the key once, clears
// the field and checks at once; Check shows its progress and one message per error code; a state the
// app could not read says so with Try Again; the page coming back reads the state again.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockSettingsProvider } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderCard, renderPage, settle, click, changeValue, openMoreOptions, rowElement } = await import("./testing");
const { DictationProviderCard, dictationCardAnchor } = await import("./components/DictationProviderCard");
const { mockDictationState } = await import("./mockDictation");
const { t } = await import("./strings");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const SECRET = "not-a-real-key";

async function open(setup?: (provider: MockSettingsProvider) => void, values?: Record<string, unknown>) {
  page = await renderCard(<DictationProviderCard />, { setup, mock: values ? { values } : undefined });
  await settle();
  return page;
}

const card = () => page!.container.querySelector<HTMLElement>("[data-dictation-provider]");
const action = (name: string) => card()?.querySelector<HTMLButtonElement>(`[data-dictation-action="${name}"]`) ?? null;
const field = () => card()?.querySelector<HTMLInputElement>("[data-dictation-key-form] input") ?? null;
const help = () => card()!.querySelector("[data-dictation-help]")!.textContent;
const statusLine = () => card()!.querySelector<HTMLElement>("[data-dictation-status]")!;
const runs = (provider: MockSettingsProvider) => provider.dictationRuns.map((run) => run.action);

async function save(key: string) {
  await changeValue(field()!, key);
  await click(action("save")!);
  await settle();
}

test("the anchor is the last dictation row a card draws, wherever the page puts it", () => {
  expect(dictationCardAnchor([{ key: "a" }, { key: "agentPane.dictationSource" }, { key: "b" }])).toBe(
    "agentPane.dictationSource",
  );
  expect(
    dictationCardAnchor([
      { key: "agentPane.dictationEngineModel" },
      { key: "agentPane.dictationSource" },
      { key: "agentPane.dictationEngine" },
    ]),
  ).toBe("agentPane.dictationEngineModel");
  expect(dictationCardAnchor([{ key: "a" }])).toBeNull();
});

test("on this Mac: one quiet line, no key field and no Check", async () => {
  await open();
  expect(card()!.dataset.dictationView).toBe("onDevice");
  expect(help()).toBe("Speech is turned into text on this Mac. Nothing is sent.");
  expect(field()).toBeNull();
  expect(action("check")).toBeNull();
  expect(card()!.querySelector("[data-dictation-status]")).toBeNull();
});

test("a keyless server (whisper.cpp): where recordings go, and Check Connection", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
    p.dictation = mockDictationState("whisperCpp");
  });
  expect(card()!.dataset.dictationView).toBe("keyless");
  expect(help()).toBe("Recordings go to the server at http://127.0.0.1:8080.");
  expect(field()).toBeNull();
  // The status line is there before any check, so a result never moves the rows under it.
  expect(statusLine().dataset.dictationStatus).toBe("idle");
  await click(action("check")!);
  expect(runs(provider)).toEqual(["state", "check"]);
  expect(statusLine().textContent).toBe("Connected");
  expect(statusLine().querySelector('[data-status="success"]')).not.toBeNull();
});

test("a required key, none saved: a password field that never echoes, Save disabled while empty", async () => {
  await open((p) => {
    p.dictation = mockDictationState("openai");
  });
  expect(card()!.dataset.dictationView).toBe("keyForm");
  expect(card()!.querySelector(".row-title")!.textContent).toBe("API Key");
  expect(help()).toBe("Recordings are sent to api.openai.com with your key. The key is kept in your Mac's Keychain.");
  const input = field()!;
  expect(input.type).toBe("password");
  expect(input.getAttribute("autocomplete")).toBe("off");
  expect(input.getAttribute("spellcheck")).toBe("false");
  expect(action("save")!.disabled).toBe(true);
  // Nothing to check before a required key is saved.
  expect(action("check")).toBeNull();
  await changeValue(input, "   ");
  expect(action("save")!.disabled).toBe(true);
  await changeValue(input, SECRET);
  expect(action("save")!.disabled).toBe(false);
});

test("an optional key (a local server): the field says optional, and Check works without one", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
    p.dictation = mockDictationState("localServer");
  });
  expect(card()!.querySelector(".row-title")!.textContent).toBe("API Key (Optional)");
  expect(field()!.getAttribute("aria-label")).toBe("API Key (Optional)");
  expect(help()).toContain("127.0.0.1:8000");
  await click(action("check")!);
  expect(runs(provider)).toEqual(["state", "check"]);
  expect(statusLine().textContent).toBe("Connected");
});

test("a custom engine with no URL asks for the URL first", async () => {
  await open((p) => {
    p.dictation = mockDictationState("custom");
  });
  expect(card()!.dataset.dictationView).toBe("needsUrl");
  expect(help()).toBe("Enter the provider's URL above to add its key.");
  expect(field()).toBeNull();
});

test("Save sends the key once, clears the field, checks at once, and the key is never in the page again", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
    p.dictation = mockDictationState("groq");
  });
  await save(SECRET);
  expect(provider.dictationRuns).toEqual([{ action: "state" }, { action: "setKey", key: SECRET }, { action: "check" }]);
  expect(card()!.dataset.dictationView).toBe("keySaved");
  expect(card()!.querySelector("[data-dictation-saved]")!.textContent).toContain("Key saved in Keychain");
  expect(statusLine().textContent).toBe("Connected");
  expect(field()).toBeNull();
  expect(page!.container.innerHTML).not.toContain(SECRET);
  expect(document.body.innerHTML).not.toContain(SECRET);
});

test("a Save the app refused asks for the key again, with the refusal on the status line", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
    p.dictation = mockDictationState("openai");
  });
  provider.dictationFails = "cmux.protocol.closed";
  await save(SECRET);
  expect(card()!.dataset.dictationView).toBe("keyForm");
  expect(field()!.value).toBe("");
  expect(statusLine().dataset.dictationStatus).toBe("refused");
  expect(page!.container.innerHTML).not.toContain(SECRET);
});

test("a saved key: Replace opens the field with Cancel; Remove asks, then removes it", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
    p.dictation = mockDictationState("openai", { hasKey: true });
  });
  expect(card()!.dataset.dictationView).toBe("keySaved");
  expect(field()).toBeNull();
  await click(action("replace")!);
  expect(field()).not.toBeNull();
  await click(action("cancel")!);
  expect(field()).toBeNull();

  await click(action("replace")!);
  await save("sk-new");
  expect(provider.dictationRuns.at(-2)).toEqual({ action: "setKey", key: "sk-new" });
  expect(field()).toBeNull();

  await click(action("remove")!);
  expect(card()!.querySelector('[role="alertdialog"]')!.textContent).toContain("Remove the saved key?");
  expect(runs(provider)).not.toContain("removeKey");
  await click(action("confirmRemove")!);
  expect(runs(provider).at(-1)).toBe("removeKey");
  expect(card()!.dataset.dictationView).toBe("keyForm");
  expect(field()!.value).toBe("");
});

test("Check shows its progress while it runs and keeps the button from a second press", async () => {
  let provider!: MockSettingsProvider;
  let release!: () => void;
  await open((p) => {
    provider = p;
    p.dictation = mockDictationState("openai", { hasKey: true });
  });
  provider.dictationHold = new Promise<void>((resolve) => {
    release = resolve;
  });
  await click(action("check")!);
  expect(statusLine().dataset.dictationStatus).toBe("checking");
  expect(statusLine().textContent).toBe("Checking the connection…");
  expect(action("check")!.disabled).toBe(true);
  release();
  provider.dictationHold = null;
  await settle();
  expect(statusLine().textContent).toBe("Connected");
  expect(action("check")!.disabled).toBe(false);
});

const ERRORS: Array<[string, string, string]> = [
  ["key_missing", "", "No key is saved. Paste your API key and choose Save."],
  ["key_invalid", "", "The provider didn't accept the key. Save a valid API key, then check again."],
  ["offline", "", "Couldn't reach api.openai.com. Check your network connection and the URL, then try again."],
  ["timeout", "", "api.openai.com didn't answer in time. Try again in a moment."],
  ["rate_limited", "", "The provider is limiting requests. Wait a minute, then try again."],
  [
    "bad_endpoint",
    "",
    "This URL can't be used for dictation. Use an https address, or http only for a server on this Mac or your local network.",
  ],
  [
    "rejected",
    "unknown model whisper-9",
    "The provider refused the request (unknown model whisper-9). Check the model name and the URL.",
  ],
  ["rejected", "", "The provider refused the request. Check the model name and the URL."],
  ["provider_error", "", "The provider had a problem on its side. Try again later."],
  ["bad_response", "", "The server answered, but not like a transcription service. Check the URL."],
  ["not_configured", "", "Choose a dictation provider above, and its URL if it needs one, then check again."],
  ["something_new", "", "Couldn't check the connection. Try again."],
];

for (const [code, detail, words] of ERRORS) {
  test(`Check failing with ${code}${detail ? " (with detail)" : ""} says what to do`, async () => {
    await open((p) => {
      p.dictation = mockDictationState("openai", { hasKey: true });
      p.dictationCheck = { ok: false, error: { code, detail } };
    });
    await click(action("check")!);
    expect(statusLine().dataset.dictationStatus).toBe("failed");
    expect(statusLine().textContent).toBe(words);
    expect(statusLine().querySelector('[data-status="attention"]')).not.toBeNull();
  });
}

test("every error message has a translation in every shipped language", () => {
  const keys = [
    "keyMissing",
    "keyInvalid",
    "offline",
    "timeout",
    "rateLimited",
    "badEndpoint",
    "rejected",
    "rejectedNoDetail",
    "providerError",
    "badResponse",
    "notConfigured",
    "other",
  ].map((key) => `settingsPage.dictationEngine.error.${key}`);
  for (const key of keys) expect(t(key)).not.toBe(key);
});

test("a state the app could not read says so, and Try Again reads it again", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
    p.dictationFails = "cmux.protocol.closed";
  });
  expect(card()!.dataset.dictationView).toBe("unavailable");
  expect(card()!.textContent).toContain("Couldn't read the dictation provider.");
  provider.dictationFails = null;
  provider.dictation = mockDictationState("groq");
  await click(action("retry")!);
  expect(card()!.dataset.dictationView).toBe("keyForm");
});

test("the page becoming visible reads the state again (a key saved elsewhere shows)", async () => {
  let provider!: MockSettingsProvider;
  await open((p) => {
    provider = p;
    p.dictation = mockDictationState("openai");
  });
  expect(card()!.dataset.dictationView).toBe("keyForm");
  provider.dictation = mockDictationState("openai", { hasKey: true });
  document.dispatchEvent(new window.Event("visibilitychange"));
  await settle();
  expect(card()!.dataset.dictationView).toBe("keySaved");
});

test("no card while the message box dictates with another app", async () => {
  await open(undefined, { "agentPane.dictationSource": "macos" });
  expect(card()).toBeNull();
});

test("on the page: the card follows the dictation rows behind Message Box's More Options", async () => {
  page = await renderPage({
    path: "/settings/chat",
    setup: (p) => {
      p.dictation = mockDictationState("openai");
    },
  });
  await settle();
  await openMoreOptions(page.container);
  const cards = page.container.querySelectorAll<HTMLElement>("[data-dictation-provider]");
  expect(cards.length).toBe(1);
  // The last dictation row the schema export has (the engine's rows once the export lists them).
  const anchor = page.container.querySelector('[data-row-key="agentPane.dictationEngineModel"]')
    ? rowElement(page.container, "agentPane.dictationEngineModel")
    : rowElement(page.container, "agentPane.dictationSource");
  expect(anchor.nextElementSibling).toBe(cards[0]!);
  expect(cards[0]!.dataset.dictationView).toBe("keyForm");
});
