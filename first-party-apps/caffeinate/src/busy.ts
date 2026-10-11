// Which terminals run a command, from their foreground program. Pure.

import { t } from "./l10n.ts"

/** Foreground programs that mean "nothing runs": the user's shell at its prompt. */
const SHELLS = new Set(["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login"])

const base = (path: string) => path.split("/").pop()!.replace(/^-/, "")

/** "cargo · api" from a foreground program and a terminal title; null when the shell is at its prompt. */
export function busyLabel(foreground: string | null | undefined, title: string): string | null {
  if (!foreground) return null
  const program = base(foreground)
  if (!program || SHELLS.has(program)) return null
  const name = title.trim()
  return name && name !== program ? t("terminal.label", "{program} · {title}", { program, title: name.slice(0, 40) }) : program
}
