import type { Translate } from "../i18n";
import type { SenderProgram } from "./incomingMessage";

/// The program mark's accessible name, and its tooltip's lines (the path last, when acpmux read one).
export function programMarkText(t: Translate, program: SenderProgram): { label: string; title: string } {
  const who = program.host
    ? t("message.senderProgramOnHost", { name: program.name, host: program.host })
    : program.name;
  const label = t("message.senderProgram", { program: who });
  const title = [label, t("message.senderProgramNotAgent"), program.path].filter(Boolean).join("\n");
  return { label, title };
}
