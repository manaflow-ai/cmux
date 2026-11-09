/// Where a composer command that starts a chat starts it (Leo, 2026-11-06: "Shared chat commands
/// can start in cloud."). The option is the CLI's own: `cmux chat --on cloud` starts a chat in
/// Cloud, and `/cd --on cloud` in a new chat picks its folder and Cloud, so its first Send is the
/// composer's own `cloud.startChat` with the Environment chip's pick (Auto by default). `--on here`
/// (or no `--on`) keeps a command where it ran before: where the chat runs.

export type CommandPlace = "here" | "cloud";

/// The place a command's arguments name, and the arguments without it. `--on` goes first:
/// `/side --on cloud fix the tests`, `/cd --on=cloud ~/src` is refused only for its `~`.
/// `refused`: an `--on` the composer cannot start a chat in (a VM or a device: `cmux chat --on`
/// takes those, the composer's Where menu picks them).
export type PlacedArgs = { place?: CommandPlace; rest: string } | { refused: true; on: string };

export function commandPlace(args: string | undefined): PlacedArgs {
  const typed = args?.trim() ?? "";
  const match = /^--on(?:=(\S*)|\s+(\S+)|$)(?:\s+([\s\S]*))?$/.exec(typed);
  if (!match) return { rest: typed };
  const on = (match[1] ?? match[2] ?? "").toLowerCase();
  const rest = match[3]?.trim() ?? "";
  if (on === "here" || on === "cloud") return { place: on, rest };
  return { refused: true, on };
}
