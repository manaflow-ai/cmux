export type TerminalInputQueueScheduler = {
  setTimeout(callback: () => void, delay: number): number;
  clearTimeout(timer: number): void;
};

export type TerminalInputQueueOptions = {
  debounceMs?: number;
  scheduler?: TerminalInputQueueScheduler;
  targetEquals: (lhs: TerminalInputTarget, rhs: TerminalInputTarget) => boolean;
  sendText: (target: TerminalInputTarget, text: string) => Promise<void>;
  sendKey: (target: TerminalInputTarget, key: string) => Promise<void>;
  afterMutation?: (target: TerminalInputTarget, kind: TerminalInputMutationKind) => Promise<void>;
  handleError: (error: unknown) => void;
};

export type TerminalInputTarget = {
  workspaceID: string;
  surfaceID: string;
};

export type TerminalInputMutationKind = "text" | "key" | "enter";

export class TerminalInputQueue {
  private readonly debounceMs: number;
  private readonly scheduler: TerminalInputQueueScheduler;
  private readonly targetEquals: (lhs: TerminalInputTarget, rhs: TerminalInputTarget) => boolean;
  private readonly sendText: (target: TerminalInputTarget, text: string) => Promise<void>;
  private readonly sendKey: (target: TerminalInputTarget, key: string) => Promise<void>;
  private readonly afterMutation?: (target: TerminalInputTarget, kind: TerminalInputMutationKind) => Promise<void>;
  private readonly handleError: (error: unknown) => void;
  private buffer = "";
  private bufferTarget: TerminalInputTarget | null = null;
  private flushTimer: number | null = null;
  private mutationChain = Promise.resolve();
  private generation = 0;

  constructor(options: TerminalInputQueueOptions) {
    this.debounceMs = options.debounceMs ?? 50;
    this.scheduler = options.scheduler ?? {
      setTimeout: (callback, delay) => window.setTimeout(callback, delay),
      clearTimeout: (timer) => window.clearTimeout(timer),
    };
    this.targetEquals = options.targetEquals;
    this.sendText = options.sendText;
    this.sendKey = options.sendKey;
    this.afterMutation = options.afterMutation;
    this.handleError = options.handleError;
  }

  appendText(target: TerminalInputTarget, text: string) {
    if (!text) return;
    if (this.bufferTarget && !this.targetEquals(this.bufferTarget, target)) {
      this.flushBuffer();
    }
    this.bufferTarget = target;
    this.buffer += text;
    this.scheduleFlush();
  }

  sendMappedKey(target: TerminalInputTarget, key: string) {
    if (key === "enter" || key === "return") {
      this.sendEnter(target);
      return;
    }
    this.flushBuffer();
    this.enqueueMutation(target, "key", () => this.sendKey(target, key));
  }

  sendEnter(target: TerminalInputTarget) {
    if (this.bufferTarget && !this.targetEquals(this.bufferTarget, target)) {
      this.flushBuffer();
    }
    this.clearFlushTimer();
    const text = this.buffer;
    this.buffer = "";
    this.bufferTarget = null;
    this.enqueueMutation(target, "enter", () => this.sendText(target, `${text}\r`));
  }

  flushBuffer() {
    this.clearFlushTimer();
    const text = this.buffer;
    const target = this.bufferTarget;
    this.buffer = "";
    this.bufferTarget = null;
    if (!text || !target) return;
    this.enqueueMutation(target, "text", () => this.sendText(target, text));
  }

  dispose() {
    this.generation += 1;
    this.clearFlushTimer();
    this.buffer = "";
    this.bufferTarget = null;
  }

  waitForIdle() {
    return this.mutationChain;
  }

  private scheduleFlush() {
    this.clearFlushTimer();
    this.flushTimer = this.scheduler.setTimeout(() => {
      this.flushTimer = null;
      this.flushBuffer();
    }, this.debounceMs);
  }

  private clearFlushTimer() {
    if (this.flushTimer === null) return;
    this.scheduler.clearTimeout(this.flushTimer);
    this.flushTimer = null;
  }

  private enqueueMutation(target: TerminalInputTarget, kind: TerminalInputMutationKind, operation: () => Promise<void>) {
    const generation = this.generation;
    this.mutationChain = this.mutationChain
      .then(async () => {
        if (this.generation !== generation) return;
        await operation();
      })
      .catch(this.handleError);
    this.scheduleAfterMutation(target, kind, generation, this.mutationChain);
  }

  private scheduleAfterMutation(
    target: TerminalInputTarget,
    kind: TerminalInputMutationKind,
    generation: number,
    chainSnapshot: Promise<void>,
  ) {
    if (!this.afterMutation) return;
    queueMicrotask(() => {
      chainSnapshot
        .then(async () => {
          if (this.mutationChain !== chainSnapshot) return;
          if (this.generation !== generation) return;
          await this.afterMutation?.(target, kind);
        })
        .catch(this.handleError);
    });
  }
}
