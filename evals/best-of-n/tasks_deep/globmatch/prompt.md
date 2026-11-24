Fix the ignore matching in `globmatch.py`, the gitignore-style rules behind the file tree, quick-open and the
agent's file watcher.

Bug report: "Our monorepo's `.cmuxignore` has `build/`. The top-level `build` directory disappears from the file
tree, but `packages/app/build` is still there, and quick-open keeps offering its 4,000 generated files."

Contract: `IgnoreRules` answers exactly as git would for the same patterns in a top-level `.gitignore`, for the
features the module docstring lists, and those rules are precise as written there: for instance a trailing `/`
only limits a pattern to directories and never by itself makes it relative to the root, and `/**/` also matches
zero directories. `ignored(path, is_dir)` and `filter_paths` must agree on every path, for files and directories
at any depth, whether or not the caller also asks about the path's parent directories.
