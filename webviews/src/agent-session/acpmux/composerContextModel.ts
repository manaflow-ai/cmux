export const CONTEXT_LABELS = {
  computer: "composer.computer",
  folder: "composer.folder",
  local: "composer.thisMac",
  chooseComputer: "composer.chooseComputer",
  chooseFolder: "composer.chooseFolder",
  chooseFolderMenu: "composer.addFolder",
  folderSearch: "composer.folderSearch",
  cloud: "composer.cloud",
  connectSSH: "composer.connectSSH",
  addComputer: "composer.addComputer",
  newCloudMachine: "composer.newCloudMachine",
  newChatHere: "composer.newChatHere",
  machine: "composer.machine",
  chooseMachine: "composer.chooseMachine",
  noProject: "project.noFolder",
  environment: "composer.environment",
} as const;

/// A name split for a cut in the middle: the head takes the ellipsis, the tail always shows. Names
/// under 7 characters are not split (they fit, or a cut would leave nothing to read). The tail is
/// the name's last word when that word is 3 to 10 characters ("atlas-web-checkout-service" reads
/// "atlas-we…service", never "…ervice"); otherwise a third of the name, 3 to 6 characters.
export function splitForMiddleTruncation(value: string): [string, string] {
  const chars = Array.from(value);
  if (chars.length < 7) return [value, ""];
  const separator = Math.max(...["-", "_", ".", " "].map((mark) => chars.lastIndexOf(mark)));
  const word = chars.length - 1 - separator;
  const tail = separator > 0 && word >= 3 && word <= 10 ? word : Math.min(6, Math.max(3, Math.floor(chars.length / 3)));
  return [chars.slice(0, -tail).join(""), chars.slice(-tail).join("")];
}
