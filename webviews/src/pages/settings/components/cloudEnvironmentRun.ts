import type { CloudEnvironmentRow, CloudEnvironmentsRun, CloudEnvironmentVariable } from "../ops";

/** What the form holds: the fields of `cloud.environment.set`, trimmed on Save. */
export type EnvironmentDraft = {
  name: string;
  repo: string;
  setup_script: string;
  env: CloudEnvironmentVariable[];
};

export const variableValue = (variable: CloudEnvironmentVariable) =>
  "secret" in variable ? variable.secret : variable.value;

/** Field by field, never by JSON text: the host's `{value, name}` and the form's `{name, value}` are
 * the same variable. */
const sameEnv = (a: CloudEnvironmentVariable[], b: CloudEnvironmentVariable[]) =>
  a.length === b.length &&
  a.every(
    (variable, index) =>
      variable.name === b[index]!.name &&
      "secret" in variable === "secret" in b[index]! &&
      variableValue(variable) === variableValue(b[index]!),
  );

/** An edit's Save names only what changed from `row` (the environment as Edit opened it): a rename
 * alone leaves the built snapshot fresh, and a teammate's newer edit to another field stays. */
export function editRun(row: CloudEnvironmentRow, draft: EnvironmentDraft): CloudEnvironmentsRun {
  const env = draft.env.filter((variable) => variable.name);
  return {
    action: "save",
    id: row.id,
    ...(draft.name !== row.name ? { name: draft.name } : {}),
    ...(draft.repo !== (row.repo ?? "") ? { repo: draft.repo } : {}),
    ...(draft.setup_script !== row.setup_script ? { setup_script: draft.setup_script } : {}),
    ...(sameEnv(env, row.env ?? []) ? {} : { env }),
  };
}
