/// The argv as the person reads it: `sudo` and each argument, quoted when it holds a space or a
/// shell character, so what runs is exactly what the card shows (sudo gets the argv, no shell).
export function commandLine(argv: readonly string[]): string {
  const quote = (arg: string) =>
    arg !== "" && /^[\w@%+=:,./-]+$/.test(arg) ? arg : `'${arg.replaceAll("'", `'\\''`)}'`;
  return ["sudo", ...argv.map(quote)].join(" ");
}
