/// Pure optimistic running-limit history shared by the web stepper and the native Session Info
/// model. A second click may happen before React paints the first one.
export type SubagentLimitAsk = { chat?: string; over: readonly number[]; value: number };

export function nextSubagentLimitAsk(
  asked: SubagentLimitAsk | undefined,
  chatId: string | undefined,
  current: number,
  value: number,
): SubagentLimitAsk {
  const standing = asked !== undefined && asked.chat === chatId && asked.over.includes(current);
  return { chat: chatId, over: standing && asked ? [...asked.over, asked.value] : [current], value };
}
