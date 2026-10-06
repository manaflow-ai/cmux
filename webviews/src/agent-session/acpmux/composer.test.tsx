import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  // The prompt is a Milkdown (ProseMirror) editor.
  Node: dom.window.Node,
  getSelection: dom.window.getSelection.bind(dom.window),
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("./Composer");

const { promptField: fieldIn, typeInto } = await import("./promptFieldTesting");
const promptField = () => fieldIn(dom.window.document);

/// Milkdown makes its editor a task after the composer mounts.
const ready = () => act(() => new Promise((resolve) => setTimeout(resolve, 10)));

const snapshot = (commands?: AcpmuxSnapshot["commands"]): AcpmuxSnapshot => ({
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
  commands,
});
const commands = [
  { name: "compact", description: "Summarize the conversation" },
  { name: "review", description: "Review changes", hint: "branch or PR" },
  { name: "pr-comments", description: "Read PR comments" },
];

describe("acpmux composer slash menu", () => {
  let root: ReturnType<typeof createRoot>;
  let sent: string[];
  let sentAttachments: { name: string; kind: string }[][];
  const textarea = () => promptField();
  const rows = () =>
    [...dom.window.document.querySelectorAll(".acpmux-slash-row")].map(
      (row) => row.querySelector(".acpmux-slash-name")!.textContent,
    );
  const active = () => dom.window.document.querySelector(".acpmux-slash-active .acpmux-slash-name")?.textContent;
  const menu = () => dom.window.document.querySelector(".acpmux-slash-menu");
  const type = async (value: string) => act(async () => typeInto(textarea(), value));
  const plusButton = () =>
    dom.window.document.querySelector(".acpmux-composer-plus .acpmux-picker-button") as HTMLButtonElement;
  /// Opens + and picks one of its rows, as a click does.
  const pickPlus = async (id: string) => {
    await act(async () => plusButton().click());
    await act(async () => {
      dom.window.document
        .querySelector(`.acpmux-composer-plus [data-value="${id}"]`)!
        .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
  };
  /// jsdom fires `select` a task after the caret moves; let it land inside act.
  const settle = async () => act(() => new Promise((resolve) => setTimeout(resolve, 0)));
  const key = async (name: string, isComposing = false) =>
    act(async () => {
      textarea().dispatchEvent(
        new dom.window.KeyboardEvent("keydown", {
          key: name,
          isComposing,
          bubbles: true,
          cancelable: true,
        }),
      );
    });
  const render = async (value: AcpmuxSnapshot) => {
    await act(async () =>
      root.render(
        createElement(Composer, {
          snapshot: value,
          chips: () => null,
          onSend: (text: string, attachments = []) => {
            sent.push(text);
            sentAttachments.push(attachments.map((attachment) => ({ name: attachment.name, kind: attachment.kind })));
          },
          onStop: () => {},
        }),
      ),
    );
    await ready();
  };

  beforeEach(() => {
    sent = [];
    sentAttachments = [];
    root = createRoot(dom.window.document.getElementById("root")!);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
  });

  test("a leading slash lists the agent's commands and narrows as the word grows", async () => {
    await render(snapshot(commands));
    expect(menu()).toBeNull();
    await type("/");
    expect(rows()).toEqual(["/compact", "/review", "/pr-comments"]);
    await type("/com");
    expect(rows()).toEqual(["/compact", "/pr-comments"]);
    expect([...dom.window.document.querySelectorAll(".acpmux-slash-row mark")].map((mark) => mark.textContent)).toEqual(
      ["com", "com"],
    );
    await type("/review ");
    expect(menu()).toBeNull();
    await type("say /com");
    expect(menu()).toBeNull();
  });

  test("arrows move the selection and Enter writes the command without sending", async () => {
    await render(snapshot(commands));
    await type("/");
    expect(active()).toBe("/compact");
    await key("ArrowDown");
    expect(active()).toBe("/review");
    await key("ArrowUp");
    await key("ArrowUp");
    expect(active()).toBe("/pr-comments");
    await key("ArrowDown");
    await key("ArrowDown");
    await key("Enter");
    expect(textarea().value).toBe("/review ");
    await settle();
    expect(textarea().selectionStart).toBe(8);
    expect(menu()).toBeNull();
    expect(sent).toEqual([]);
  });

  test("pressing a row picks it and Escape closes the menu until the prompt changes", async () => {
    await render(snapshot(commands));
    await type("/pr");
    await act(async () => {
      dom.window.document
        .querySelector(".acpmux-slash-row")!
        .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
    await settle();
    expect(textarea().value).toBe("/pr-comments ");
    await type("/c");
    await key("Escape");
    expect(menu()).toBeNull();
    await type("/co");
    expect(menu()).not.toBeNull();
  });

  test("keys go to the input method while it composes", async () => {
    await render(snapshot(commands));
    await type("/に");
    await type("/");
    await key("ArrowDown", true);
    expect(active()).toBe("/compact");
    await key("Escape", true);
    expect(menu()).not.toBeNull();
    await key("Enter", true);
    expect(textarea().value).toBe("/");
  });

  test("a live update that shrinks the list keeps a row selected", async () => {
    await render(snapshot(commands));
    await type("/");
    await key("ArrowUp");
    expect(active()).toBe("/pr-comments");
    await render(snapshot(commands.slice(0, 2)));
    expect(active()).toBe("/review");
    expect(textarea().getAttribute("aria-activedescendant")).toBe("acpmux-slash-1");
    await key("Enter");
    expect(textarea().value).toBe("/review ");
    expect(textarea().getAttribute("aria-controls")).toBeNull();
  });

  test("an agent with no commands, or no match, says so", async () => {
    await render(snapshot());
    await type("/");
    expect(menu()?.textContent).toBe("No commands");
    await render(snapshot(commands));
    await type("/zzz");
    expect(menu()?.textContent).toBe("No matching commands");
    // Nothing to pick: Enter sends what was typed, as it would a pasted path.
    await key("Enter");
    expect(sent).toEqual(["/zzz"]);
    expect(textarea().value).toBe("");
  });

  test("Enter on a command typed in full sends it unless it takes arguments", async () => {
    await render(snapshot(commands));
    await type("/compact");
    await settle();
    await key("Enter");
    expect(sent).toEqual(["/compact"]);
    await type("/review");
    await settle();
    await key("Enter");
    expect(sent).toEqual(["/compact"]);
    expect(textarea().value).toBe("/review ");
  });

  test("+ opens an add menu: Mention puts an @ at the caret, and Commands opens the command menu ahead of a draft", async () => {
    const items = async () => {
      await act(async () => plusButton().click());
      const names = [...dom.window.document.querySelectorAll(".acpmux-composer-plus [role=option]")].map((item) =>
        item.getAttribute("data-value"),
      );
      await act(async () => plusButton().click());
      return names;
    };
    await render(snapshot());
    expect(await items()).toEqual(["mention"]);
    await render(snapshot(commands));
    expect(await items()).toEqual(["mention", "commands"]);
    await type("look at");
    await pickPlus("mention");
    expect(textarea().value).toBe("look at @");
    expect(dom.window.document.activeElement).toBe(textarea().element);
    await type("look at main");
    await pickPlus("commands");
    await settle();
    expect(textarea().value).toBe("/ look at main");
    expect(rows()).toEqual(["/compact", "/review", "/pr-comments"]);
    await key("ArrowDown");
    await key("Enter");
    expect(textarea().value).toBe("/review look at main");
    expect(sent).toEqual([]);
  });

  test("keeps Mode and Plan out of the default bar while the + menu changes them", async () => {
    const modes = {
      currentModeId: "ask",
      availableModes: [
        { id: "ask", name: "Ask for approval" },
        { id: "bypassPermissions", name: "Full access" },
        { id: "plan", name: "Plan" },
      ],
    };
    const modeCalls: string[] = [];
    await act(async () =>
      root.render(
        createElement(Composer, {
          snapshot: { ...snapshot(), summary: { sessionId: "s", modes } },
          chips: () => null,
          onSend: () => {},
          onStop: () => {},
          onMode: (mode: string) => modeCalls.push(mode),
        }),
      ),
    );
    await ready();
    expect(dom.window.document.querySelector(".acpmux-mode")).toBeNull();
    expect(dom.window.document.querySelector(".acpmux-plan")).toBeNull();
    await act(async () => plusButton().click());
    expect(
      [...dom.window.document.querySelectorAll(".acpmux-composer-plus [role=option]")].map((item) => item.textContent),
    ).toEqual(["Ask for approval", "Full access", "Plan", "Mention a file or folder@"]);
    await act(async () =>
      dom.window.document
        .querySelector<HTMLElement>('.acpmux-composer-plus [data-value="mode:bypassPermissions"]')!
        .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true })),
    );
    expect(modeCalls).toEqual(["bypassPermissions"]);
  });

  test("+ keeps a pasted path whole, keeps a named command's slash, and Escape puts the draft back", async () => {
    const plus = () => pickPlus("commands");
    await render(snapshot(commands));
    await type("/Users/dev/x.txt is broken");
    await plus();
    await settle();
    expect(textarea().value).toBe("/ /Users/dev/x.txt is broken");
    await key("Escape");
    expect(textarea().value).toBe("/Users/dev/x.txt is broken");
    expect(menu()).toBeNull();
    await type("/review main");
    await plus();
    await settle();
    expect(textarea().value).toBe("/review main");
    expect(rows()).toEqual(["/compact", "/review", "/pr-comments"]);
    await key("Enter");
    expect(textarea().value).toBe("/compact main");
  });

  test("what + wrote never reaches the agent: Send and leaving the composer take the draft back", async () => {
    const plus = () => pickPlus("commands");
    const submit = async () =>
      act(async () => {
        dom.window.document
          .querySelector("form")!
          .dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
      });
    await render(snapshot(commands));
    await type("fix the bug");
    await plus();
    await settle();
    expect(textarea().value).toBe("/ fix the bug");
    await submit();
    expect(sent).toEqual(["fix the bug"]);
    await type("look again");
    await plus();
    await settle();
    // Called directly for the same reason as typeInto: react-dom may load before the DOM exists.
    const form = dom.window.document.querySelector("form")!;
    const props = (
      form as unknown as Record<string, { onBlur(event: { currentTarget: Element; relatedTarget: Element }): void }>
    )[Object.keys(form).find((key) => key.startsWith("__reactProps$"))!]!;
    await act(async () => props.onBlur({ currentTarget: form, relatedTarget: dom.window.document.body }));
    expect(textarea().value).toBe("look again");
    expect(menu()).toBeNull();
    await type("/comp");
    await plus();
    await settle();
    expect(textarea().value).toBe("/comp");
  });

  test("a leading override replaces +, and null leaves the slot empty", async () => {
    await act(async () =>
      root.render(
        createElement(Composer, {
          snapshot: snapshot(commands),
          chips: () => null,
          onSend: () => {},
          onStop: () => {},
          leading: null,
        }),
      ),
    );
    expect(dom.window.document.querySelector(".acpmux-composer-plus")).toBeNull();
    await act(async () =>
      root.render(
        createElement(Composer, {
          snapshot: snapshot(commands),
          chips: () => null,
          onSend: () => {},
          onStop: () => {},
          leading: createElement("button", { type: "button", className: "attach" }),
        }),
      ),
    );
    expect(dom.window.document.querySelector(".acpmux-composer-bar > .attach")).not.toBeNull();
  });

  test("submitting sends the trimmed prompt and clears the box", async () => {
    await render(snapshot(commands));
    await type("  /review main  ");
    await act(async () => {
      dom.window.document
        .querySelector("form")!
        .dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
    });
    expect(sent).toEqual(["/review main"]);
    expect(textarea().value).toBe("");
  });

  describe("attachments", () => {
    const settleFiles = () => act(() => new Promise((resolve) => setTimeout(resolve, 5)));
    const png = () =>
      new dom.window.File([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], "shot.png", {
        type: "image/png",
      });
    const transfer = (files: File[]) => ({
      files,
      types: files.length ? ["Files"] : ["text/plain"],
    });
    const paste = async (files: File[]) => {
      const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
      Object.defineProperty(event, "clipboardData", { value: transfer(files) });
      await act(async () => textarea().element.dispatchEvent(event));
      await settleFiles();
      return event;
    };
    const drop = async (kind: "dragover" | "drop", files: File[]) => {
      const event = new dom.window.Event(kind, { bubbles: true, cancelable: true });
      Object.defineProperty(event, "dataTransfer", { value: transfer(files) });
      await act(async () => dom.window.document.body.dispatchEvent(event));
      await settleFiles();
      return event;
    };

    test("pasted image and text files become removable chips and send with the prompt", async () => {
      await act(async () =>
        root.render(
          createElement(Composer, {
            snapshot: {
              ...snapshot(),
              summary: { sessionId: "s", promptCapabilities: { image: true } },
            },
            chips: () => null,
            onSend: (text: string, attachments = []) => {
              sent.push(text);
              sentAttachments.push(attachments.map((attachment) => ({ name: attachment.name, kind: attachment.kind })));
            },
            onStop: () => {},
          }),
        ),
      );
      await ready();
      const event = await paste([png(), new dom.window.File(["hello\n"], "notes.md", { type: "text/markdown" })]);
      expect(event.defaultPrevented).toBe(true);
      expect(
        [...dom.window.document.querySelectorAll(".acpmux-attachment")].map((chip) => chip.getAttribute("title")),
      ).toEqual(["shot.png", "notes.md"]);
      await act(async () =>
        dom.window.document.querySelector<HTMLButtonElement>('[aria-label="Remove notes.md"]')!.click(),
      );
      await act(async () =>
        dom.window.document
          .querySelector("form")!
          .dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
      );
      expect(sent).toEqual([""]);
      expect(sentAttachments).toEqual([[{ name: "shot.png", kind: "image" }]]);
      expect(dom.window.document.querySelector(".acpmux-attachments")).toBeNull();
    });

    test("a file drop is captured anywhere in the pane and unsupported images explain the refusal", async () => {
      await act(async () =>
        root.render(
          createElement(Composer, {
            snapshot: {
              ...snapshot(),
              summary: { sessionId: "s", promptCapabilities: { image: false } },
            },
            chips: () => null,
            onSend: (text: string, attachments = []) => {
              sent.push(text);
              sentAttachments.push(attachments.map((attachment) => ({ name: attachment.name, kind: attachment.kind })));
            },
            onStop: () => {},
          }),
        ),
      );
      await ready();
      const over = await drop("dragover", [png()]);
      expect(over.defaultPrevented).toBe(true);
      expect(dom.window.document.querySelector(".acpmux-attachment-note")?.textContent).toBe(
        "Drop images or text files to attach",
      );
      const dropped = await drop("drop", [png()]);
      expect(dropped.defaultPrevented).toBe(true);
      expect(dom.window.document.querySelector(".acpmux-attachment-note")?.textContent).toBe(
        "This agent does not take images",
      );
      expect(dom.window.document.querySelector(".acpmux-attachment")).toBeNull();
    });
  });
});

describe("acpmux composer draft", () => {
  test("an inherited draft fills an empty prompt once and is not sent", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const sent: string[] = [];
    const render = async (draft?: string) => {
      await act(async () =>
        root.render(
          createElement(Composer, {
            snapshot: snapshot(),
            chips: () => null,
            draft,
            onSend: (text: string) => {
              sent.push(text);
            },
            onStop: () => {},
          }),
        ),
      );
      await ready();
    };
    await render();
    const prompt = promptField();
    expect(prompt.value).toBe("");
    // The draft is markdown: its quote is a quote in the prompt (the blank lines after it are not kept).
    await render("> selected output\n\n");
    expect(prompt.value).toBe("> selected output");
    expect(prompt.element.querySelector("blockquote")?.textContent).toBe("selected output");
    expect(sent).toEqual([]);
    // What the user typed stays when another draft arrives.
    await act(async () => typeInto(prompt, "mine"));
    await render("another");
    expect(prompt.value).toBe("mine");
    await act(async () => root.unmount());
  });
});

describe("acpmux composer remote editing note", () => {
  let root: ReturnType<typeof createRoot>;
  const note = () => dom.window.document.querySelector(".acpmux-composer-remote-note");
  const render = async (value: AcpmuxSnapshot) => {
    await act(async () =>
      root.render(createElement(Composer, { snapshot: value, chips: () => null, onSend: () => {}, onStop: () => {} })),
    );
    await ready();
  };
  const showing = (remote: boolean, harness: string): AcpmuxSnapshot => ({
    ...snapshot(),
    remote,
    summary: { sessionId: "s", harness, family: harness },
  });
  beforeEach(() => {
    root = createRoot(dom.window.document.getElementById("root")!);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
  });

  test("a remote Codex or opencode chat says why editing is not offered", async () => {
    await render(showing(true, "codex"));
    expect(note()?.textContent).toBe("Editing from here needs a mode that asks before each change");
    expect(note()?.getAttribute("role")).toBe("note");
    await render(showing(true, "opencode"));
    expect(note()?.textContent).toBe("Editing from here needs a mode that asks before each change");
  });

  test("a local chat and a remote Claude chat show no note", async () => {
    await render(showing(false, "codex"));
    expect(note()).toBeNull();
    await render(showing(true, "claude"));
    expect(note()).toBeNull();
  });
});
