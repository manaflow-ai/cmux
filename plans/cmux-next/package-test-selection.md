# Input-keyed Swift package tests

Status: first slice landed with the package input-key receipt in PR (this change). The lane computes and reports a deterministic key for every selected package; it does not skip tests yet.

## Key contract

`scripts/ci/package_input_key.py` hashes a canonical, sorted list of repository-relative paths and SHA-256 digests. A package's inputs include:

- its `Package.swift`, sources, tests, resources, plugins, and other files in the package;
- every local path dependency named by `Package.swift`, recursively;
- the package test lane's workflow, helper scripts, Xcode pin, GhosttyKit checksum and other shared inputs listed by `select_package_tests.py`;
- the recorded `ghostty` gitlink revision, when present.

The digest is independent of checkout location and file enumeration order. The JSON receipt carries `version`, package name, key, input count, the input-list digest, and sorted paths. The lane emits `package_input_keys` through `GITHUB_OUTPUT`; a fleet invocation prints `CMUX_PACKAGE_INPUT_KEYS=` so the workflow wrapper can carry the same receipt back from the worker.

A change outside a package and its dependency closure leaves that package's key unchanged. A source, test, manifest, local dependency, test helper, workflow or toolchain change changes the key for every affected package. Missing package names fail closed.

## Follow-up cache policy

The next slice should add a write-once result store keyed by `(package, key, toolchain identity)`. A green receipt must include the exact head SHA, key, test command, runner and test count. The lane may skip a package only after an authenticated receipt is fetched from the shared store and its key and toolchain match; a cache miss, malformed receipt, failed upload or unknown input must run the test. Writes are immutable, and failed or partial runs never create a green entry. The first implementation should keep the current selection and failure semantics, then add a bounded matrix so packages with misses run in parallel.
