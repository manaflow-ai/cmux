# App interfaces

Versioned contracts between apps and the shell (plans/cmux-next/app-platform.md section 12, V2). One file per major version: `<name>/<major>.json`. A manifest names them in `implements` and `consumes`. Shapes are drafts until the first implementing app proves them; then they freeze and change only by a new major.
