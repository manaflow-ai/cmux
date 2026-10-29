// Tasks the room hears. A task goes to Chief by itself only when the speaker spoke to the AI and
// the quote really names it (a model's `addressed: true` alone never starts work); every other ask
// waits as a proposal until someone in the room presses Send.

import { similarity } from "./dedupe.ts";
import type { ProposedTask } from "./digest.ts";

export type TaskState = "proposed" | "sent" | "dismissed" | "failed";

export interface RoomTask extends ProposedTask {
  id: number;
  state: TaskState;
  at: number;
  error?: string;
}

const ADDRESS = /\b(chief|cmux|hey (ai|claude|computer))\b/i;

export function isAddressed(task: ProposedTask): boolean {
  return task.addressed && ADDRESS.test(task.quote);
}

export type SendToChief = (task: RoomTask) => Promise<void>;

export function chiefMessage(task: RoomTask, roomUrl: string): string {
  return [
    `${task.title}`,
    "",
    `Task from the Voice Room (said by ${task.speaker || "someone"}):`,
    task.ask,
    "",
    `Their words: "${task.quote}"`,
    `Room: ${roomUrl}`,
  ].join("\n");
}

/** Sends with `cmux chief -p`; the CLI is told not to wait for the subagents it starts. */
export function cliSendToChief(roomUrl: string, cli = "cmux"): SendToChief {
  return async (task) => {
    const child = Bun.spawn([cli, "chief", "--no-wait-agents", "--timeout", "120", "-p", chiefMessage(task, roomUrl)], {
      stdout: "ignore",
      stderr: "pipe",
    });
    const code = await child.exited;
    // 124: the CLI stopped waiting for the reply; the message was delivered.
    if (code !== 0 && code !== 124) {
      throw new Error(`cmux chief exited ${code}: ${(await new Response(child.stderr).text()).slice(0, 200)}`);
    }
  };
}

export class TaskBoard {
  readonly tasks: RoomTask[] = [];

  constructor(
    private readonly send: SendToChief,
    private readonly onChange: () => void = () => {},
  ) {}

  /** Adds the model's proposals, skipping repeats of a task already on the board. */
  async add(proposed: ProposedTask[], at = Date.now()): Promise<RoomTask[]> {
    const added: RoomTask[] = [];
    for (const proposal of proposed) {
      const repeat = this.tasks.some(
        (task) => similarity(task.ask, proposal.ask) >= 0.6 || similarity(task.quote, proposal.quote) >= 0.8,
      );
      if (repeat) continue;
      const task: RoomTask = { ...proposal, id: this.tasks.length + 1, state: "proposed", at };
      this.tasks.push(task);
      added.push(task);
    }
    this.onChange();
    for (const task of added) if (isAddressed(task)) await this.dispatch(task.id);
    return added;
  }

  async dispatch(id: number): Promise<RoomTask | undefined> {
    const task = this.tasks.find((candidate) => candidate.id === id);
    if (!task || task.state === "sent") return task;
    try {
      await this.send(task);
      task.state = "sent";
      task.error = undefined;
    } catch (error) {
      task.state = "failed";
      task.error = error instanceof Error ? error.message : String(error);
    }
    this.onChange();
    return task;
  }

  dismiss(id: number): void {
    const task = this.tasks.find((candidate) => candidate.id === id);
    if (task && task.state !== "sent") task.state = "dismissed";
    this.onChange();
  }
}
