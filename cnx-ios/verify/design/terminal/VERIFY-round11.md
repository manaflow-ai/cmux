# Terminal verify round 11 (fresh adversarial verifier, 2026-10-15 07:00 PT onward)

**Status: in progress (partial push).** Criteria: `ACCEPTANCE.md` on `origin/feat-cnx-ios-termqa` 319b2c60, verbatim.
Claims in `qa-round-11.md` were read as claims only. Evidence: `verify11/`. Raw videos: `~/cnx-ios-e2e/termqa-raw/tv11/` on the laptop.

## Build

- `origin/feat-cnx-ios-termqa` 319b2c603c35, built by this verifier with `cnx-ios/scripts/demo-build.sh --ref 319b2c603c35 --tag tq10 --skip-device --skip-mac`
  (Demo, `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, bundle `dev.cmux.cnx.tq10`). CnxFFI was built from source (key 3459f1856b078e80; no cache hit).
- Zip sha256 `e76df0da5ecb99ce31814b9610e91bc263e5b90f03e3c59afaa760c5a025af4e`; `CnxApp` binary sha256
  `24f924aa8982c15de9106356d2cbf4f49228905f0d8cde05830690effcfe1375`, equal to the installed copy on `cnx-termqa-1` (C906E217-...).
- Launched with `-CnxFrameLog YES` via `verify/termqa/v11.py install` (a copy of `q11.py` with evidence to `verify11/`).
- Mac: `cnx-e2e-604fc689` on mini-cmuxs-mac-mini-2 (unchanged). Mac side used only for hostd kills and oracle reads.

## Partial results

(see sections below; filled in as runs finish)
