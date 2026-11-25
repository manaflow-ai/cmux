import type { AcpmuxPermission } from "./model";
import type { PermissionClientState } from "./permissions/protocol";

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

/// Whether the single permission card answers the permission shortcuts: not while a permission
/// group waits (pending, or still collecting), whose panel answers them, so one ⌥⌘1 never allows
/// a group and an ungrouped ask at once.
export function cardTakesShortcuts(groups: PermissionClientState | undefined): boolean {
  return (
    !groups?.supported || !groups.groups.some((group) => group.state === "pending" || group.state === "collecting")
  );
}

/// Whether `permission` draws as the single card: a grouped ask only while no permission group on
/// screen holds it. One whose group is not read yet (a peer's read waits on its attach) is the single
/// card at once, and the group's panel takes it when the read lands; one restored groups already
/// hold is the panel's only, never on both. An ask acpmux did not group stays the single card.
export function askOnSingleCard(
  permission: { pending?: boolean; permissionId: string; groupId?: string } | undefined,
  groups: PermissionClientState | undefined,
): boolean {
  if (!permission?.pending) return false;
  if (!groups?.supported || !permission.groupId) return true;
  return !groups.groups.some((group) => group.items.some((item) => item.permissionId === permission.permissionId));
}

/// The ask kept on its single card while the person writes a deny's instructions on it (`held`, from
/// the card's draft), even after a group read hands it to the group's panel: the card unmounting would
/// lose what they typed, and the panel takes no instructions. It goes once it is no longer pending.
export function heldOnCard<P extends { pending?: boolean; permissionId: string }>(
  held: P | undefined,
  permission: P | undefined,
  groups: PermissionClientState | undefined,
): P | undefined {
  if (!held) return undefined;
  if (permission?.permissionId === held.permissionId) return permission.pending ? permission : undefined;
  const pending = groups?.groups.some((group) =>
    group.items.some((item) => item.permissionId === held.permissionId && item.state === "pending"),
  );
  return pending ? held : undefined;
}
