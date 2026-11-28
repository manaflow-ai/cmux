# Release checklist

1. Bump the version
   - `Info.plist` and `package.json`
   - the changelog entry
2. Tag the release
   1. Run the pretag guard
   2. Push the tag
3. Watch CI

- [x] Signing certificates renewed
- [ ] Notarization tested on macOS 14
- [ ] Release notes reviewed

> **Note:** the guard refuses a tag on a dirty tree.
>
> Run `git status` first.

| Lane | Owner | Status | Notes |
| :--- | :---: | ---: | --- |
| Build | CI | green | Universal binary, both slices verified with `lipo -info` on the produced app bundle |
| Sign | Release bot | pending | Waits on the certificate rotation that lands Thursday |
| Notarize | Release bot | blocked | Apple's service returned 503 twice in the last hour; retry after the status page clears |
| Publish | Human | not started | |

---

See [the release docs](https://github.com/manaflow-ai/cmux/blob/main/docs/release.md) for more.
