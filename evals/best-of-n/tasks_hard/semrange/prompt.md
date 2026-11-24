Implement `satisfies(version: str, range_: str) -> bool` in `semrange.py`: does a version match an npm-style range.

Versions: `MAJOR.MINOR.PATCH` with an optional `-PRERELEASE` (dot-separated identifiers of `[0-9A-Za-z-]`) and an
optional `+BUILD` that is ignored; an optional leading `v` or `=`. Numbers have no leading zeros (`01` is invalid).
Precedence is SemVer 2.0: compare major, minor, patch numerically; a version with a prerelease is lower than the same
version without; prerelease identifiers compare left to right, numeric ones numerically, alphanumeric ones in ASCII
order, numeric lower than alphanumeric, and a shorter list is lower when all its identifiers equal the longer's prefix.

Ranges: sets separated by `||`; a version satisfies the range when it satisfies any set. A set is comparators
separated by whitespace, all of which must hold. An empty set, or `*`, matches every version (prerelease rule below).
A comparator is an optional operator (`<`, `<=`, `>`, `>=`, `=`, `~`, `^`) followed by optional spaces and a version
that may be partial: `1`, `1.2`, or with `x`, `X` or `*` for missing parts (`1.x`, `1.2.*`). A hyphen range
`A - B` (spaces around the hyphen required) is one set member too.

- `1.2.3` or `=1.2.3`: exactly (build ignored). A partial `1.2` or `1.2.x` alone: `>=1.2.0 <1.3.0`; `1`: `>=1.0.0 <2.0.0`.
- `>1.2` means `>=1.3.0`; `>1` means `>=2.0.0`; `>=1.2` means `>=1.2.0`; `<1.2` means `<1.2.0`; `<=1.2` means `<1.3.0`;
  `<=1` means `<2.0.0`. An operator with `*` (`>=*`) matches every version.
- `~1.2.3`: `>=1.2.3 <1.3.0`; `~1.2`: `>=1.2.0 <1.3.0`; `~1`: `>=1.0.0 <2.0.0`.
- `^1.2.3`: `>=1.2.3 <2.0.0`; `^0.2.3`: `>=0.2.3 <0.3.0`; `^0.0.3`: `>=0.0.3 <0.0.4`; `^1.2`: `>=1.2.0 <2.0.0`;
  `^0.0`: `>=0.0.0 <0.1.0`; `^0`: `>=0.0.0 <1.0.0`. A prerelease on the version is kept on the lower bound
  (`^1.2.3-beta.2`: `>=1.2.3-beta.2 <2.0.0`).
- `A - B`: `>=A <=B`; a partial A fills zeros (`1.2 - 2.3.4`: `>=1.2.0 <=2.3.4`); a partial B is an exclusive bound on
  the next one up (`1.2.3 - 2.3`: `>=1.2.3 <2.4.0`; `1.2.3 - 2`: `>=1.2.3 <3.0.0`).

Prerelease rule: a version with a prerelease satisfies a set only when every comparator holds AND some comparator of
that set (after the expansions above) has a version with a prerelease and the same major.minor.patch. So
`1.2.4-alpha` does not satisfy `>=1.2.3`, `2.0.0-rc.1` does not satisfy `^1.0.0`, and `1.2.3-beta.4` satisfies
`>=1.2.3-beta.2 <1.3.0`. An empty set or `*` matches no prerelease version.

Raise ValueError for an invalid version or range (bad syntax, leading zeros, an unknown operator, `1.2.3 -2.0.0`).
