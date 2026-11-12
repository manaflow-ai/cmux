const quote = (text: string) => `'${text.replace(/'/g, `'"'"'`)}'`;

/** Guest shell line that runs a variant instruction with the image's pinned
 * codex. The Run VM is the sandbox, so codex runs without approvals; the
 * pinned release rejects the retired `--full-auto` flag. `--` keeps an
 * instruction like `-h` or `review` a prompt, not an option or subcommand. The JSONL event
 * stream stays in the guest for the attempt's retention window. */
export function variantAgentCommand(instruction: string, attemptId: string, outputDir = "/tmp"): string {
  if (!/^[0-9a-f-]{36}$/i.test(attemptId)) throw new Error("Invalid attempt identity");
  const output = `${outputDir}/cmux-agent-output-${attemptId}.jsonl`;
  return `codex exec --json --dangerously-bypass-approvals-and-sandbox -- ${quote(instruction)} >${quote(output)}\n`;
}

/** Insert the variant's agent step at the source verifier's marker. A
 * replacer function keeps `$&`, `$'` and friends in instruction text literal. */
export function withVariantExecution(source: string, instruction: string | undefined, attemptId: string): string {
  const work = instruction ? `\n${variantAgentCommand(instruction, attemptId)}` : "";
  return source.replace("# CMUX_VARIANT_EXECUTION", () => work);
}
