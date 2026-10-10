/** A Chief subagent's first message (optchat-chief `prompt::subagent_blocks`): the Chief's view,
 * `<chat>` … `</chat>`, then `Your task:` and the task. The pane shows the view as one collapsed
 * line and the task as the message; the session keeps the whole text (the agent read it all). */
export type ChiefEnvelope = {
  /** The view as the agent got it, `<chat>` to `</chat>`. */
  context: string;
  /** Its lines, without the `<chat>` markers. */
  lines: number;
  /** From `Your task:` on. */
  task: string;
};

const OPEN = "<chat>";
const CLOSE = "</chat>";
const TASK = "Your task:";

/** The envelope of `text`, or undefined when it is not one: it starts with the view's `<chat>`
 * marker and `Your task:` follows its `</chat>` (only whitespace between). */
export function chiefEnvelope(text: string | undefined): ChiefEnvelope | undefined {
  if (!text?.startsWith(OPEN)) return undefined;
  const close = text.indexOf(`\n${CLOSE}`);
  if (close < 0) return undefined;
  const end = close + 1 + CLOSE.length;
  const rest = text.slice(end);
  const start = rest.search(/\S/);
  if (start < 0 || !rest.startsWith(TASK, start)) return undefined;
  const context = text.slice(0, end);
  const lines = context.split("\n").filter((line) => line.trim() !== "" && line !== OPEN && line !== CLOSE).length;
  return { context, lines, task: rest.slice(start) };
}
