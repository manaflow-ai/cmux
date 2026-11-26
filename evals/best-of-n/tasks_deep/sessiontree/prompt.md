Fix the session tree in `sessiontree.py`.

Bug report: "Under `work` I had two sessions, `Tests` and `build`. I renamed `build` to `tests` and it went through,
so now `work` has two children with the same name. Creating a second `tests` there is refused, as it should be."

Contract. Sibling sessions never share a name, where names are compared case-insensitively (`str.casefold`); root
sessions are siblings of each other. A session never becomes its own ancestor. Every public call either succeeds
completely or raises `SessionError` and leaves the tree unchanged. Path lookup (`find`) matches names the same way
uniqueness compares them. `close(sid)` removes the session and all of its descendants and returns every closed id
(in no particular order). A session may be renamed to a different spelling of its own name. Sessions can have many siblings: `create`, `rename`, `move` and `find` must take time independent of the
number of siblings (a parent with tens of thousands of children stays fast), and `close` time proportional to the
number of sessions it closes.
