# Xcode Project Normalization

cmux is pinned to Xcode 26.x. `.xcode-version` records the major version. `cmux.xcodeproj/project.pbxproj` carries `objectVersion = 60`, which is what Xcode 26 writes by default.

`objectVersion = 77` is reserved for projects that adopt synchronized folder groups. cmux does not use synchronized folder groups yet.

## Pre-commit hook

`scripts/setup.sh` installs:

```text
scripts/git-hooks/pre-commit
```

The hook runs:

```bash
scripts/normalize-pbxproj.py
```

on staged `cmux.xcodeproj/project.pbxproj` changes. This sorts high-churn sections so Xcode's nondeterministic reordering does not reach commits.

## CI guard

CI runs:

```bash
scripts/check-pbxproj.sh
```

It enforces both:

- the `.xcode-version` / `objectVersion` pin
- pbxproj normalization

## Bumping Xcode

To bump the pin:

1. Edit `.xcode-version`.
2. Open `cmux.xcodeproj` in the new Xcode so it rewrites `objectVersion`.
3. Add a case in `scripts/check-pbxproj.sh` mapping the new Xcode major to the objectVersion that Xcode writes.
4. Normalize the project file.
5. Treat the bump as a deliberate team decision.

Do not change `objectVersion` opportunistically as part of unrelated project edits.
