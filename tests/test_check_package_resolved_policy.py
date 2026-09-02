#!/usr/bin/env python3
"""Regression tests for ./scripts/check-package-resolved-policy.py.

The guard requires a Package.resolved diff whenever a manifest's dependency
calls change. It must key that requirement off the *remote* dependency calls
reachable from the manifest, not off "this manifest's graph has some remote
dependency somewhere", otherwise adding a dependency-free local-path package
demands a lockfile diff that `swift package resolve` cannot produce
(https://github.com/manaflow-ai/cmux/issues/8871).

Cases:
  (a) Adding a leaf `.package(path:)` with no remote closure to a manifest that
      already has remote pins passes (exit 0) with no lockfile diff.
  (b) Adding a `.package(url:)` still fails (exit 1) — true positives intact.
  (c) Removing a `.package(url:)` still fails (exit 1).
  (d) Bumping an existing `.package(url:)` version requirement still fails
      (exit 1), even though the URL set is unchanged.
  (e) Adding a local-path package that itself carries remote pins still fails
      (exit 1), because it changes the reachable remote set.
  (f) Case (b) passes once the matching Package.resolved diffs are included.
  (g) Removing an Xcode product linkage passes without a lockfile diff because
      product linkage does not change the resolved package graph.
  (h) Changing an Xcode remote requirement still fails without a lockfile diff.
"""

import os
import subprocess
import sys
import tempfile

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT_DIR, "scripts", "check-package-resolved-policy.py")

REMOTE_DEPENDENCY = (
    '.package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")'
)

RESOLVED_JSON = """{
  "originHash" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "pins" : [
    {
      "identity" : "swift-collections",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-collections.git",
      "state" : {
        "revision" : "1111111111111111111111111111111111111111",
        "version" : "1.1.0"
      }
    }
  ],
  "version" : 3
}
"""

XCODE_PROJECT = """// !$*UTF8*$!
{
  objects = {
    A /* Project object */ = {
      isa = PBXProject;
      packageReferences = (
        B /* XCRemoteSwiftPackageReference \"sentry-cocoa\" */,
      );
    };
    B /* XCRemoteSwiftPackageReference \"sentry-cocoa\" */ = {
      isa = XCRemoteSwiftPackageReference;
      repositoryURL = \"https://github.com/getsentry/sentry-cocoa.git\";
      requirement = {
        kind = upToNextMajorVersion;
        minimumVersion = 9.3.0;
      };
    };
    C /* Sentry */ = {
      isa = XCSwiftPackageProductDependency;
      package = B /* XCRemoteSwiftPackageReference \"sentry-cocoa\" */;
      productName = Sentry;
    };
  };
}
"""

XCODE_PROJECT_PATH = "cmux.xcodeproj/project.pbxproj"
XCODE_LOCKFILE_PATH = (
    "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)


def write_text(path, contents):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(contents)


def manifest(name, dependencies):
    joined = "".join(f"        {dependency},\n" for dependency in dependencies)
    return (
        "// swift-tools-version: 6.0\n"
        "import PackageDescription\n\n"
        "let package = Package(\n"
        f'    name: "{name}",\n'
        "    dependencies: [\n"
        f"{joined}"
        "    ]\n"
        ")\n"
    )


def git(repo, *args):
    subprocess.run(["git", *args], cwd=repo, check=True, stdout=subprocess.DEVNULL)


def workspace_data(locations):
    entries = "".join(
        f'   <FileRef location = "group:{location}"></FileRef>\n'
        for location in locations
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace version = "1.0">\n'
        f"{entries}"
        "</Workspace>\n"
    )


def make_base_repo(repo):
    """A minimal cmux-shaped repo: an iOS package with remote pins, plus the
    iOS workspace the guard always reads."""
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "test")

    write_text(
        os.path.join(repo, "Packages/iOS/CmuxMobileShellUI/Package.swift"),
        manifest("CmuxMobileShellUI", [REMOTE_DEPENDENCY]),
    )
    write_text(
        os.path.join(repo, "Packages/iOS/CmuxMobileShellUI/Package.resolved"),
        RESOLVED_JSON,
    )
    write_text(
        os.path.join(repo, "ios/cmuxPackage/Package.swift"),
        manifest(
            "cmuxPackage",
            ['.package(path: "../../Packages/iOS/CmuxMobileShellUI")'],
        ),
    )
    write_text(os.path.join(repo, "ios/cmuxPackage/Package.resolved"), RESOLVED_JSON)
    write_text(
        os.path.join(repo, "ios/cmux.xcworkspace/contents.xcworkspacedata"),
        workspace_data(["cmuxPackage", "../Packages/iOS/CmuxMobileShellUI"]),
    )
    write_text(
        os.path.join(
            repo, "ios/cmux.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        ),
        RESOLVED_JSON,
    )
    write_text(os.path.join(repo, XCODE_PROJECT_PATH), XCODE_PROJECT)
    write_text(os.path.join(repo, XCODE_LOCKFILE_PATH), RESOLVED_JSON)
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "base")


def run_guard(repo):
    env = dict(os.environ)
    env["PACKAGE_RESOLVED_POLICY_BASE_REF"] = "HEAD~1"
    return subprocess.run(
        [sys.executable, GUARD],
        cwd=repo,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def scenario(mutate):
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        os.makedirs(repo)
        make_base_repo(repo)
        mutate(repo)
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "change")
        return run_guard(repo)


def shell_ui_manifest(repo):
    return os.path.join(repo, "Packages/iOS/CmuxMobileShellUI/Package.swift")


def add_leaf_path_package(repo):
    write_text(
        os.path.join(repo, "Packages/iOS/CmuxMobileChanges/Package.swift"),
        manifest("CmuxMobileChanges", []),
    )
    write_text(
        shell_ui_manifest(repo),
        manifest(
            "CmuxMobileShellUI",
            [REMOTE_DEPENDENCY, '.package(path: "../CmuxMobileChanges")'],
        ),
    )


def add_remote_bearing_path_package(repo):
    write_text(
        os.path.join(repo, "Packages/iOS/CmuxMobileChanges/Package.swift"),
        manifest(
            "CmuxMobileChanges",
            ['.package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")'],
        ),
    )
    write_text(
        os.path.join(repo, "Packages/iOS/CmuxMobileChanges/Package.resolved"),
        RESOLVED_JSON,
    )
    write_text(
        shell_ui_manifest(repo),
        manifest(
            "CmuxMobileShellUI",
            [REMOTE_DEPENDENCY, '.package(path: "../CmuxMobileChanges")'],
        ),
    )


def add_remote_package(repo):
    write_text(
        shell_ui_manifest(repo),
        manifest(
            "CmuxMobileShellUI",
            [
                REMOTE_DEPENDENCY,
                '.package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")',
            ],
        ),
    )


def remove_remote_package(repo):
    write_text(shell_ui_manifest(repo), manifest("CmuxMobileShellUI", []))


def bump_remote_requirement(repo):
    write_text(
        shell_ui_manifest(repo),
        manifest(
            "CmuxMobileShellUI",
            [
                '.package(url: "https://github.com/apple/swift-collections.git", '
                'from: "2.0.0")'
            ],
        ),
    )


def remove_xcode_product_linkage(repo):
    project_path = os.path.join(repo, XCODE_PROJECT_PATH)
    with open(project_path, encoding="utf-8") as handle:
        project = handle.read()
    product_link = (
        '      package = B /* XCRemoteSwiftPackageReference "sentry-cocoa" */;\n'
    )
    if product_link not in project:
        raise AssertionError("Xcode product linkage fixture is missing")
    write_text(project_path, project.replace(product_link, ""))


def change_xcode_remote_requirement(repo):
    project_path = os.path.join(repo, XCODE_PROJECT_PATH)
    with open(project_path, encoding="utf-8") as handle:
        project = handle.read()
    old_requirement = "        minimumVersion = 9.3.0;"
    if old_requirement not in project:
        raise AssertionError("Xcode package requirement fixture is missing")
    write_text(
        project_path,
        project.replace(old_requirement, "        minimumVersion = 9.4.0;"),
    )


def touch_all_lockfiles(repo):
    bumped = RESOLVED_JSON.replace("1.1.0", "1.2.0")
    for lockfile in (
        "Packages/iOS/CmuxMobileShellUI/Package.resolved",
        "ios/cmuxPackage/Package.resolved",
        "ios/cmux.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ):
        write_text(os.path.join(repo, lockfile), bumped)


def expect(label, result, expected_code):
    if result.returncode == expected_code:
        print(f"ok: {label}")
        return True
    print(f"FAIL: {label}: expected exit {expected_code}, got {result.returncode}")
    print(result.stdout)
    return False


def main():
    ok = True

    ok &= expect(
        "(a) leaf local-path package needs no lockfile diff",
        scenario(add_leaf_path_package),
        0,
    )
    ok &= expect(
        "(b) added remote dependency still requires a lockfile diff",
        scenario(add_remote_package),
        1,
    )
    ok &= expect(
        "(c) removed remote dependency still requires a lockfile diff",
        scenario(remove_remote_package),
        1,
    )
    ok &= expect(
        "(d) bumped remote requirement still requires a lockfile diff",
        scenario(bump_remote_requirement),
        1,
    )
    ok &= expect(
        "(e) local-path package with remote pins still requires a lockfile diff",
        scenario(add_remote_bearing_path_package),
        1,
    )

    def add_remote_package_with_lockfiles(repo):
        add_remote_package(repo)
        touch_all_lockfiles(repo)

    ok &= expect(
        "(f) added remote dependency passes with matching lockfile diffs",
        scenario(add_remote_package_with_lockfiles),
        0,
    )
    ok &= expect(
        "(g) removing an Xcode product linkage needs no lockfile diff",
        scenario(remove_xcode_product_linkage),
        0,
    )
    ok &= expect(
        "(h) changing an Xcode remote requirement still needs a lockfile diff",
        scenario(change_xcode_remote_requirement),
        1,
    )

    if not ok:
        return 1
    print("check-package-resolved-policy regression tests OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
