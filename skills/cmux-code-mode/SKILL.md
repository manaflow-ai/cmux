---
name: cmux-code-mode
description: "Discover cmux operations progressively instead of loading a large tool list."
---

# cmux code mode

Use cmux's catalog-backed help before guessing an operation:

```sh
cmux help <area>
cmux docs search "<what you need to do>"
```

`cmux help` shows the operations for an area. `cmux docs search` returns the
matching operation names, classes, selectors, fields, and result types. Read
only the relevant entries, then invoke the normal `cmux` CLI command.
