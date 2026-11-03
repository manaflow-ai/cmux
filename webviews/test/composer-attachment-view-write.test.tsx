import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const replacements = { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true };
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const settings = await import("../src/agent-session/acpmux/composerSettings");

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

function pending() {
  let resolve!: () => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<void>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  // A deliberately rejected host promise must not become an unrelated unhandled rejection on red.
  void promise.catch(() => undefined);
  return { promise, resolve, reject };
}

async function withView(run: (shown: () => string) => Promise<void>) {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  function View() {
    return <output>{settings.useComposerSettings().attachmentView}</output>;
  }
  try {
    settings.setComposerSettings(settings.DEFAULT_COMPOSER);
    await act(async () => root.render(<View />));
    await run(() => host.textContent ?? "");
  } finally {
    settings.registerAttachmentViewHost(undefined);
    await act(async () => {
      settings.setComposerSettings(settings.DEFAULT_COMPOSER);
      root.unmount();
    });
  }
}

test("a refused attachment view restores the host's choice", async () => {
  await withView(async (shown) => {
    const write = pending();
    settings.registerAttachmentViewHost(() => write.promise);
    await act(async () => settings.setAttachmentView("strip"));
    expect(shown()).toBe("strip");
    await act(async () => write.reject(new Error("managed setting")));
    expect(shown()).toBe("inline");
  });
});

test("a delayed rejection cannot undo an authoritative host push", async () => {
  await withView(async (shown) => {
    const write = pending();
    settings.registerAttachmentViewHost(() => write.promise);
    await act(async () => settings.setAttachmentView("strip"));
    await act(async () => settings.setComposerSettings({ attachmentView: "inline" }));
    await act(async () => write.reject(new Error("write refused")));
    expect(shown()).toBe("inline");
  });
});

test("a failed later choice settles to an earlier write that eventually succeeds", async () => {
  await withView(async (shown) => {
    const first = pending(),
      second = pending();
    settings.registerAttachmentViewHost((view) => (view === "strip" ? first.promise : second.promise));
    await act(async () => {
      settings.setAttachmentView("strip");
      settings.setAttachmentView("inline");
    });
    await act(async () => second.reject(new Error("second write refused")));
    await act(async () => first.resolve());
    expect(shown()).toBe("strip");
  });
});

test("an older rejection cannot undo a newer successful choice", async () => {
  await withView(async (shown) => {
    const first = pending(),
      second = pending();
    settings.registerAttachmentViewHost((view) => (view === "strip" ? first.promise : second.promise));
    await act(async () => {
      settings.setAttachmentView("strip");
      settings.setAttachmentView("inline");
    });
    await act(async () => second.resolve());
    await act(async () => first.reject(new Error("old write refused")));
    expect(shown()).toBe("inline");
  });
});

test("an authoritative host push wins over an older successful write", async () => {
  await withView(async (shown) => {
    const write = pending();
    settings.registerAttachmentViewHost(() => write.promise);
    await act(async () => settings.setAttachmentView("strip"));
    await act(async () => settings.setComposerSettings({ attachmentView: "inline" }));
    await act(async () => write.resolve());
    expect(shown()).toBe("inline");
  });
});

test("a synchronous host failure also restores its choice", async () => {
  await withView(async (shown) => {
    settings.registerAttachmentViewHost(() => {
      throw new Error("bridge unavailable");
    });
    await act(async () => settings.setAttachmentView("strip"));
    expect(shown()).toBe("inline");
  });
});
