// Where each tick sits in a rail list, by key (and by row id: `idIndexOf`), counted from the list's
// end: a page of older turns put in front of the list moves no entry, so a page adds only its own
// (model.ts minimapTurns' page path, foldIncoming). One map is shared down a run of such pages; a
// list reads it only while it is the last list that wrote it, and checks every hit against its own
// items, so a list a newer page (or a render React dropped) has written past reads a map of its own.

type Keyed = { readonly key: string; readonly id?: string; readonly members?: readonly string[] };
type Index = { map: Map<string, number>; owner: readonly Keyed[] };
type Field = {
  indexes: WeakMap<readonly Keyed[], Index>;
  /// The names an item is found by.
  names(item: Keyed, add: (name: string) => void): void;
  holds(item: Keyed | undefined, name: string): boolean;
};

const byKey: Field = {
  indexes: new WeakMap(),
  names: (item, add) => add(item.key),
  holds: (item, name) => item?.key === name,
};
/// A tick's row id, and every member's for a tick that folds other chats' messages (foldIncoming).
const byId: Field = {
  indexes: new WeakMap(),
  names(item, add) {
    if (item.id !== undefined) add(item.id);
    for (const member of item.members ?? []) add(member);
  },
  holds: (item, name) => item !== undefined && (item.id === name || item.members?.includes(name) === true),
};

function build(field: Field, list: readonly Keyed[]): Index {
  const map = new Map<string, number>();
  for (let at = 0; at < list.length; at += 1) field.names(list[at]!, (name) => map.set(name, list.length - at));
  const index = { map, owner: list };
  field.indexes.set(list, index);
  return index;
}

function lookup(field: Field, list: readonly Keyed[], name: string): number | undefined {
  let index = field.indexes.get(list);
  if (index) {
    const distance = index.map.get(name);
    if (distance !== undefined) {
      const at = list.length - distance;
      if (field.holds(list[at], name)) return at;
    }
    // Every name in the list that last wrote the map is in it: a miss there is a miss.
    if (index.owner === list) return undefined;
  }
  index = build(field, list);
  const distance = index.map.get(name);
  return distance === undefined ? undefined : list.length - distance;
}

/// The index of the item keyed `key` in `list`, or undefined. O(1) once the list's map is built.
export const keyIndexOf = (list: readonly Keyed[], key: string) => lookup(byKey, list, key);
/// The index of the item whose row id, or one of whose members' (a folded run), is `id`.
export const idIndexOf = (list: readonly Keyed[], id: string) => lookup(byId, list, id);

/// Notes that `list` is its first `front` items followed by a suffix of `kept`: each map `kept` owns
/// passes to `list` with the front's names added (O(front)). A `kept` with no map, or one a newer
/// list wrote since, leaves `list` to build its own when it is first read.
export function keysInFront(list: readonly Keyed[], front: number, kept: readonly Keyed[]): void {
  for (const field of [byKey, byId]) {
    const index = field.indexes.get(kept);
    if (!index || index.owner !== kept) continue;
    for (let at = 0; at < front; at += 1) field.names(list[at]!, (name) => index.map.set(name, list.length - at));
    index.owner = list;
    field.indexes.set(list, index);
  }
}

/// Builds `list`'s key map now, as a pass that already walks every item does (model.ts ticksOf).
export const indexKeys = (list: readonly Keyed[]): void => void build(byKey, list);
