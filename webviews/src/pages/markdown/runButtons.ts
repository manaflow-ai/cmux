// The Run button of a shell code block (runbook.ts): mounted only once its block comes within a
// screen of the viewport, so a long runbook builds the buttons the reader can reach and none of
// the rest. The button sits in the block's language row, absolutely placed, so mounting it and its
// confirm state never moves the code. A destructive command asks first, in the same row.
import { fromTranscript, runAsks, runnableCommand } from "./runbook";

export type RunLabel = "run" | "runTitle" | "runAsk" | "runAskLines" | "runConfirm" | "runCancel" | "runSent";

export interface RunButtonHost {
  /** Sends `command` to a new terminal in the doc's repository (the host op needs this click);
   * rejects when the host refused it. */
  runBlock(command: string): Promise<void>;
  label(key: RunLabel): string;
}

/** The nearest ancestor that scrolls vertically, or null for the page itself. */
function scrollParent(element: Element): Element | null {
  for (let at = element.parentElement; at; at = at.parentElement) {
    const overflow = getComputedStyle(at).overflowY;
    if (overflow === "auto" || overflow === "scroll" || overflow === "overlay") return at;
  }
  return null;
}

/**
 * Mounts each watched block's controls once, when it first comes near the viewport, and stops
 * watching it then. `disconnect` (the editor's teardown) ends the observer.
 */
export class NearRunBlocks {
  private observer: IntersectionObserver | null = null;
  private readonly mounts = new Map<Element, () => void>();

  constructor(private readonly editor: Element) {}

  watch(element: Element, mount: () => void): void {
    if (typeof IntersectionObserver === "undefined") return mount();
    this.observer ??= new IntersectionObserver((entries) => this.seen(entries), {
      root: scrollParent(this.editor),
      rootMargin: "100% 0px",
    });
    this.mounts.set(element, mount);
    this.observer.observe(element);
  }

  forget(element: Element): void {
    this.mounts.delete(element);
    this.observer?.unobserve(element);
  }

  disconnect(): void {
    this.observer?.disconnect();
    this.observer = null;
    this.mounts.clear();
  }

  private seen(entries: IntersectionObserverEntry[]): void {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const mount = this.mounts.get(entry.target);
      this.forget(entry.target);
      mount?.();
    }
  }
}

/**
 * The controls of one block: Run, or for a destructive command or one read from several transcript
 * lines the question and its Run and Cancel. `block` reads the block at click time, so an edited
 * block runs what it shows.
 */
export function runControls(host: RunButtonHost, block: () => { language: string; text: string }): HTMLElement {
  const command = () => {
    const { language, text } = block();
    return runnableCommand(language, text);
  };
  const row = document.createElement("span");
  row.className = "md-run";
  row.contentEditable = "false";
  const button = (className: string, text: string, onPress: () => void): HTMLButtonElement => {
    const element = document.createElement("button");
    element.type = "button";
    element.className = className;
    element.textContent = text;
    // The editor keeps its selection: a press on a control never moves the caret.
    element.addEventListener("mousedown", (event) => event.preventDefault());
    element.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      onPress();
    });
    return element;
  };
  // "Sent" only once the host took the command: a refused one (too long, the page closed) leaves Run.
  // Pointer gone before the answer: nothing would clear it, so it is not shown.
  let left = false;
  const send = () => {
    const text = command();
    if (!text) return;
    left = false;
    host.runBlock(text).then(
      () => {
        if (left || !row.isConnected || row.dataset.state === "ask") return;
        row.dataset.state = "sent";
        run.textContent = host.label("runSent");
      },
      (error: unknown) => console.warn("cmux markdown run", error),
    );
  };
  const idle = () => {
    delete row.dataset.state;
    run.textContent = host.label("run");
    row.replaceChildren(run);
  };
  const run = button("md-run-button", host.label("run"), () => {
    const text = command();
    if (!text) return;
    const lines = fromTranscript(block().language, text);
    if (!runAsks(text) && !lines) return send();
    row.dataset.state = "ask";
    const ask = document.createElement("span");
    ask.className = "md-run-ask";
    ask.textContent = host.label(runAsks(text) ? "runAsk" : "runAskLines");
    // The lines that would run, on hover.
    ask.title = text;
    const confirm = button("md-run-button md-run-confirm", host.label("runConfirm"), () => {
      idle();
      send();
    });
    row.replaceChildren(ask, confirm, button("md-run-button", host.label("runCancel"), idle));
    confirm.focus();
  });
  run.title = host.label("runTitle");
  row.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && row.dataset.state === "ask") {
      event.stopPropagation();
      idle();
    }
  });
  // "Sent" reads as the button's state until the pointer leaves it: no timer to stop.
  row.addEventListener("pointerleave", () => {
    left = true;
    if (row.dataset.state === "sent") idle();
  });
  row.append(run);
  return row;
}
