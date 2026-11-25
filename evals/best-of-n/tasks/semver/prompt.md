Implement `compare(a: str, b: str) -> int` in `semver.py`: compare two Semantic Versioning 2.0.0 strings and return -1, 0 or 1.
Follow the spec exactly: MAJOR.MINOR.PATCH are non-negative integers without leading zeros; an optional pre-release
after `-` is dot-separated identifiers; optional build metadata after `+` is ignored for precedence. A version with a
pre-release is lower than the same version without one. Pre-release identifiers compare left to right: numeric ones
numerically, alphanumeric ones in ASCII order, a numeric identifier is always lower than an alphanumeric one, and a
shorter set is lower when all earlier identifiers are equal. Raise ValueError for an invalid version (leading zeros in
a numeric part or numeric pre-release identifier, empty identifiers, missing parts, a leading `v`).
