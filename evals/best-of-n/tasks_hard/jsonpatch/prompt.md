Implement RFC 6902 JSON Patch in `jsonpatch.py`: `apply_patch(doc, patch) -> new_doc` and an exception class
`PatchError(Exception)`. `doc` is any JSON value (dict, list, str, int, float, bool, None); `patch` is a list of
operation dicts. Never mutate the input `doc`: on success return a new document, and on any failure raise PatchError
with the input unchanged (the patch is atomic).

- Operations: `add`, `remove`, `replace`, `move`, `copy`, `test`. Unknown `op` or a missing required member
  (`path`, `value`, `from`) is a PatchError.
- Paths are RFC 6901 JSON Pointers: `""` is the whole document, otherwise `/`-separated tokens where `~1` means `/`
  and `~0` means `~` (decode `~1` before `~0`, so `~01` is the key `~1`). A non-empty path not starting with `/` is
  an error. Any other `~` escape is an error.
- Array indexes are decimal with no leading zeros (`0` ok, `01` not); `-` means past the end and is only valid as
  the last token of an `add` (or `move`/`copy` target). `add` into an array inserts at the index (index may equal the
  length); `remove`/`replace` need an existing index. Object `add` sets or overwrites the key; `replace` and `remove`
  need an existing key. A path through a missing member or through a scalar is an error.
- `add`/`replace` with path `""` replace the whole document; `remove` of `""` is an error.
- `move`: `from` must exist; moving a location into one of its own children is an error (`from` `/a` to `/a/b`), but
  moving to the same path is a no-op. It is remove-then-add.
- `test`: compare as JSON values: objects by keys/values regardless of order, arrays in order, and numbers by value
  BUT a bool is never equal to a number (`true` is not `1`), and `1` equals `1.0`. Failure raises PatchError.
- Values added by `add`/`replace`/`copy` must be deep copies (later operations or caller mutations must not alias).
