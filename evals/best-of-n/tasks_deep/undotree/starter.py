"""The undo tree behind the composer and the notes pane.

Undo never throws history away: committing after an undo starts a new branch, and every state stays reachable.

- Node 0 holds the starting text. `commit(text)` adds a child of the current node holding `text` and moves to
  it, unless `text` equals the current text, in which case nothing happens. Either way it returns the current
  node id. Ids count up from 1 in commit order and are never reused.
- Every node remembers a preferred child: the child you were at most recently. `commit` makes the new node its
  parent's preferred child; `undo()` moves to the parent and makes the node it left the parent's preferred
  child; `redo()` moves to the preferred child. A node with children always has a preferred child.
  `undo()` at node 0 and `redo()` at a node without children do nothing. Both return whether they moved.
- `goto(node_id)` moves to any node. Afterwards every node on the path from node 0 to it prefers the child on
  that path, so undoing all the way and redoing all the way comes back to it. Unknown ids raise KeyError.
- `earlier(n)` and `later(n)` walk history in commit order, like vim's g- and g+: they `goto` the node whose id
  is the current id minus (plus) n, clamped to [0, last id].
- `children(node_id)` lists child ids in commit order; `parent(node_id)` is None for node 0.
"""


class _Node:
    __slots__ = ("id", "parent", "text", "preferred")

    def __init__(self, node_id, parent, text):
        self.id = node_id
        self.parent = parent
        self.text = text
        self.preferred = None


class UndoTree:
    def __init__(self, text=""):
        self._nodes = [_Node(0, None, text)]
        self.current = 0

    @property
    def text(self):
        return self._nodes[self.current].text

    @property
    def last_id(self):
        return len(self._nodes) - 1

    def _node(self, node_id):
        if not isinstance(node_id, int) or not 0 <= node_id < len(self._nodes):
            raise KeyError(node_id)
        return self._nodes[node_id]

    def parent(self, node_id):
        return self._node(node_id).parent

    def children(self, node_id):
        self._node(node_id)
        return [n.id for n in self._nodes if n.parent == node_id]

    def commit(self, text):
        if text == self.text:
            return self.current
        node = _Node(len(self._nodes), self.current, text)
        self._nodes.append(node)
        self._nodes[self.current].preferred = node.id
        self.current = node.id
        return self.current

    def undo(self):
        parent = self._nodes[self.current].parent
        if parent is None:
            return False
        self.current = parent
        return True

    def redo(self):
        kids = self.children(self.current)
        if not kids:
            return False
        pref = self._nodes[self.current].preferred
        self.current = pref if pref in kids else kids[-1]
        return True

    def goto(self, node_id):
        self._node(node_id)
        self.current = node_id

    def earlier(self, n=1):
        self.goto(max(0, min(self.last_id, self.current - n)))

    def later(self, n=1):
        self.goto(max(0, min(self.last_id, self.current + n)))
