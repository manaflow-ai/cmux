/** Appends a checkable outcome to an ask when the experiment's field has text. */
export function withOutcomeAsk(ask: string, doneWhen: string): string {
  const outcome = doneWhen.trim();
  if (!outcome) return ask;
  const prompt = ask.trim();
  return prompt ? `${prompt}\n\nDone when:\n${outcome}` : `Done when:\n${outcome}`;
}
