# Review desk

A layout for reviewing what an agent did. The chat stays the main pane, and everything it opens
(a diff, a file, a link) lands in a column on its right, so the chat, the change and a terminal
sit side by side instead of stacking as tabs.

- The chat is the main pane (`layout.mainPane`); links and files open to its right
  (`layout.linkPlacement: split-right`); a new terminal splits the pane in half instead of adding
  a tab (`layout.newPanePlacement: split`, `layout.splitSizing: halve`); panes get borders.
- The tab bar gets four buttons: Split Right, Split Down, Open Diff Viewer and Zoom
  (`tabs.toolbarButtons`).
- The edited-files card stays open and lists the whole chat's files, not one turn's
  (`agentPane.editedFiles.*`); Session Info pushes the chat aside instead of covering it.
- Two Command Palette actions: **Review: Branch Against Main** (the branch's commits and a
  file-by-file `git diff --stat` against the remote's default branch, in a new tab) and
  **Review: Start Claude Here** (Claude in a new tab, in this folder).
- Keys: Shift-Command-D opens the diff viewer. In the diff viewer, where letters are not typing,
  `] F` and `[ F` step files, `N` and `Shift-N` step hunks and `G G` goes to the top. `J`, `K`,
  `Shift-G` and `/` are the viewer's own already.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | The layout and chat settings, and the two actions (`cmuxConfig.review-branch`, `cmuxConfig.review-claude`) |
| `keybindings.json` | Shift-Command-D and the diff viewer keys |

The look's `keybindings.json` takes the place of yours while it is installed; `remove` puts yours
back, and your own actions with the same names.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/review-desk@feat-cmux-next
cmux action run cmuxConfig.review-branch
cmux setup remove manaflow-ai/review-desk
```

Or try it as a preview: `cmux customize recipes --open`, then the Review desk recipe's Run button.
