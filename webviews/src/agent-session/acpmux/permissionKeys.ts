import type { AcpmuxPermission } from "./model";

type PermissionOption = AcpmuxPermission["options"][number];

const ALWAYS = /always/i;
const always = (option: PermissionOption) => ALWAYS.test(option.id) || ALWAYS.test(option.name);

/// The key shown on each option of a permission ask, by option id: y allows once, a always
/// allows, n denies. Agents name options their own way, so the allow flag and "always" in the id
/// or name decide; an option left over shows its position, 1 to 9.
export function permissionKeys(options: readonly PermissionOption[]): Map<string, string> {
  const keys = new Map<string, string>();
  const take = (key: string, matches: (option: PermissionOption) => boolean) => {
    const option = options.find((candidate) => !keys.has(candidate.id) && matches(candidate));
    if (option) keys.set(option.id, key);
  };
  take("y", (option) => option.allow && !always(option));
  take("a", (option) => option.allow && always(option));
  take("n", (option) => !option.allow && !always(option));
  options.slice(0, 9).forEach((option, index) => {
    if (!keys.has(option.id)) keys.set(option.id, String(index + 1));
  });
  return new Map(options.filter((option) => keys.has(option.id)).map((option) => [option.id, keys.get(option.id)!]));
}

/// The option `key` answers with: its letter, or any option's position (1 to 9).
export function permissionOption(
  options: readonly PermissionOption[],
  keys: ReadonlyMap<string, string>,
  key: string,
): PermissionOption | undefined {
  const position = /^[1-9]$/.test(key) ? Number(key) - 1 : -1;
  return position >= 0 ? options[position] : options.find((option) => keys.get(option.id) === key);
}
