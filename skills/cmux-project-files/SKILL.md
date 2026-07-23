---
name: cmux-project-files
description: Read, write, find, import, reference, open, and reorganize project-local cmux Notes and Artifacts. Use when an agent needs to persist plans or Markdown notes, save generated images/video/HTML/patches/text files, retrieve prior agent output, search the project's `.cmux` filesystem, or provide a prompt-ready local file reference.
---

# cmux Project Files

Use the `cmux note` and `cmux artifact` commands as the shared interface to the
project-local filesystem. Let the CLI discover the project and current agent
session; never invent or hard-code a session folder name.

## Filesystem contract

Treat live files as authoritative:

```text
<project>/.cmux/
  <agent-session>/
    _session.json
    _workspace.json
    artifacts/
    notes/
  .metadata/
```

Artifacts and Notes are ordinary local files. A user or agent may rename and
organize content with Finder or shell tools, and later CLI calls rescan the live
tree. Keep Notes under a session's `notes/` directory and Artifacts under its
`artifacts/` directory. Do not edit `_session.json`, `_workspace.json`, or
`.metadata/`.

Commands default to the nearest ancestor containing `.cmux` or `.git`. Add
`--project <path>` when the intended project is not the current one. Add
`--json` when consuming command output programmatically.

## Work with Notes

Create or replace a Markdown note:

```bash
cmux note write plan --text "# Plan"
```

Use `--stdin` instead of `--text` for multiline or generated content. Append,
read, discover, search, open, or remove Notes with:

```bash
printf '\nNext step' | cmux note append plan --stdin
cmux note read plan
cmux note list
cmux note path plan
cmux note search "next step"
cmux note open plan
cmux note rm plan
```

Names may be a filename, stem, `.cmux/...` reference, or unambiguous relative
path. Prefer the returned `reference` from JSON output when mentioning a Note in
an agent prompt.

## Work with Artifacts

Import an existing generated file through capture policy and provenance:

```bash
cmux artifact add ./output/report.html
```

Discover, resolve, open, and search Artifacts and other visible session files:

```bash
cmux artifact list
cmux artifact path report.html
cmux artifact search "report"
cmux artifact open report.html
```

Use `cmux artifact path <name> --json` to obtain an absolute path before reading
the contents with ordinary file tools. Never add whole build directories or
bypass the CLI's type and size limits.

## Move and reference files

Resolve a file with `cmux note path` or `cmux artifact path` before moving or
renaming it. Keep the file inside the project's `.cmux` filesystem and preserve
the session markers. Subsequent list, search, read, and path commands rediscover
the new live location.

Use prompt references in this form:

```text
.cmux/<agent-session>/notes/plan.md
.cmux/<agent-session>/artifacts/report.html
```

Copy the exact `.cmux/...` value returned by the CLI; do not reconstruct the
session component yourself.
