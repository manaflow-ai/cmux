// Which of a bench's scenarios or arms a run measures, from a comma list such as ONLY=chat_switch,restart.
// An unset or empty list means all of them: scripts/measure/settled-page-linux.sh passed ONLY="" whenever rounds=
// was given without only=, and "".split(",") is [""], which matched no scenario, so the bench measured nothing and
// printed settled_page.score_max 0 (worst "") as if every scenario had settled. A name no scenario has is an error,
// so a typo cannot score an empty set either.
export function pick<T extends string>(all: readonly T[], list: string | undefined, label: string): T[] {
  const names = (list ?? "")
    .split(",")
    .map((name) => name.trim())
    .filter(Boolean);
  if (names.length === 0) return [...all];
  const unknown = names.filter((name) => !(all as readonly string[]).includes(name));
  if (unknown.length) throw new Error(`${label}: unknown ${unknown.join(", ")} (one of ${all.join(", ")})`);
  return all.filter((name) => names.includes(name));
}
