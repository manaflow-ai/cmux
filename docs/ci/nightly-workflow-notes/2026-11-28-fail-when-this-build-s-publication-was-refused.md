# 2026-11-28-fail-when-this-build-s-publication-was-refused

Where: `.github/workflows/nightly.yml`, Fail when this build's publication was refused.

A refused publication is red, not green: run 45607031207 built and signed, its shelf check died (ENOSPC), the gate refused, and the job showed green with nothing published, so a 3.5 h stall read as healthy (2026-11-25). A stand-down (writer linux or none, a known-bad commit), a superseded build and a left slot publish nothing on purpose and stay green.
