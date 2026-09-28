#!/usr/bin/env python3
"""Contracts for the project.pbxproj git merge driver.

The driver must merge the everyday conflict, two branches each adding a
different source file, and must refuse anything else, so a disagreement about
the same lines still reaches the author as a normal git conflict. It must also
never leave a project file behind that Xcode cannot open, which is why a union
the normalizer rejects counts as a refusal rather than a result.
"""

import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "scripts" / "merge-pbxproj.py"


def uuid(seed):
    """A stable 24-hex-character object id, the shape Xcode writes."""
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


def project(names, settings=None):
    """A small but structurally real project that defines each name four times.

    Four entries per file is the point of the driver: no target here is
    filesystem-synchronized, so a build file, a file reference, a group child
    and a sources-phase member all have to be written by hand, and two branches
    adding different files append to all four of the same regions.
    """
    build_files = "".join(
        f"\t\t{uuid('bf' + n)} /* {n} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {uuid('fr' + n)} /* {n} */; }};\n"
        for n in names
    )
    file_refs = "".join(
        f"\t\t{uuid('fr' + n)} /* {n} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {n}; sourceTree = \"<group>\"; }};\n"
        for n in names
    )
    children = "".join(f"\t\t\t\t{uuid('fr' + n)} /* {n} */,\n" for n in names)
    phase_files = "".join(f"\t\t\t\t{uuid('bf' + n)} /* {n} in Sources */,\n" for n in names)
    return f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tobjectVersion = 77;
\tobjects = {{

/* Begin PBXBuildFile section */
{build_files}/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{file_refs}/* End PBXFileReference section */

/* Begin PBXGroup section */
\t\t{uuid('group')} /* Sources */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{children}\t\t\t);
\t\t\tpath = Sources;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXSourcesBuildPhase section */
\t\t{uuid('phase')} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{phase_files}\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
\t\t{uuid('config')} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tSWIFT_VERSION = {settings or '6.0'};
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
/* End XCBuildConfiguration section */
\t}};
\trootObject = {uuid('root')} /* Project object */;
}}
"""


def run(base, ours, theirs):
    with tempfile.TemporaryDirectory() as directory:
        paths = {}
        for name, text in (("O", base), ("A", ours), ("B", theirs)):
            path = Path(directory) / name
            path.write_text(text, encoding="utf-8")
            paths[name] = path
        result = subprocess.run(
            [sys.executable, str(DRIVER), str(paths["O"]), str(paths["A"]), str(paths["B"]),
             "cmux.xcodeproj/project.pbxproj"],
            capture_output=True,
            text=True,
        )
        return result.returncode, paths["A"].read_text(encoding="utf-8"), result.stderr


def entries(text, name):
    """Which of the four regions declare this file, as a set of region names.

    Counting occurrences would over-count, because a build file line also names
    the file in its `fileRef` comment. Each region is identified by the shape of
    its own line instead, so a missing one is reported by name.
    """
    found = set()
    for line in text.splitlines():
        stripped = line.strip()
        if f"/* {name} in Sources */ = {{isa = PBXBuildFile;" in stripped:
            found.add("build file")
        elif f"/* {name} */ = {{isa = PBXFileReference;" in stripped:
            found.add("file reference")
        elif stripped == f"{uuid('fr' + name)} /* {name} */,":
            found.add("group child")
        elif stripped == f"{uuid('bf' + name)} /* {name} in Sources */,":
            found.add("sources phase")
    return found


REGIONS = {"build file", "file reference", "group child", "sources phase"}


def test_each_side_adds_a_different_file():
    """The everyday conflict, and the whole reason the driver exists."""
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift", "Ours.swift"])
    theirs = project(["Alpha.swift", "Theirs.swift"])
    code, merged, stderr = run(base, ours, theirs)
    assert code == 0, stderr
    for name in ("Alpha.swift", "Ours.swift", "Theirs.swift"):
        missing = REGIONS - entries(merged, name)
        assert not missing, f"{name} is missing from {sorted(missing)}\n{merged}"


def test_both_sides_add_the_same_file_once():
    """A file cherry-picked onto both branches must not be declared twice."""
    base = project(["Alpha.swift"])
    both = project(["Alpha.swift", "Shared.swift"])
    code, merged, stderr = run(base, both, both)
    assert code == 0, stderr
    assert entries(merged, "Shared.swift") == REGIONS, merged
    assert merged.count("Shared.swift in Sources */ = {isa = PBXBuildFile;") == 1, merged


def test_one_sided_change_applies():
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift"])
    theirs = project(["Alpha.swift", "Theirs.swift"])
    code, merged, stderr = run(base, ours, theirs)
    assert code == 0, stderr
    assert entries(merged, "Theirs.swift") == REGIONS, merged


def test_both_sides_change_the_same_setting_falls_back_to_git():
    """A disagreement is not an insertion, so the author has to settle it."""
    base = project(["Alpha.swift"], settings="5.0")
    ours = project(["Alpha.swift"], settings="6.0")
    theirs = project(["Alpha.swift"], settings="6.1")
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1, "a real disagreement must not be resolved silently"
    assert "SWIFT_VERSION = 6.0" in merged, "ours must be left untouched for git"
    assert "merge-pbxproj" in stderr, stderr


def test_a_side_carrying_conflict_markers_is_refused():
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift"]).replace(
        "\tarchiveVersion = 1;", "<" * 32 + " HEAD\n\tarchiveVersion = 1;"
    )
    code, _, stderr = run(base, ours, project(["Alpha.swift", "Theirs.swift"]))
    assert code == 1
    assert "conflict-marker" in stderr, stderr


def test_the_same_entry_added_differently_is_refused():
    """Two branches adding one file under different names is a disagreement.

    The lines collide rather than sitting beside each other, so keeping both
    would declare the same object twice.
    """
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift", "Ours.swift"])
    theirs = project(["Alpha.swift", "Ours.swift"]).replace("path = Ours.swift;", "path = Other.swift;")
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1, "a duplicated object id must not be written to the project"
    assert merged == ours, "ours must be left exactly as git handed it over"
    assert "only distinct added lines can be merged" in stderr, stderr


def test_a_union_the_normalizer_rejects_is_refused():
    """The driver writes over %A, so a project Xcode could not open must not pass.

    Here the union itself succeeds: ours matches the base, so a three-way merge
    takes theirs wholesale without ever seeing a conflict. Only the normalizer
    notices that what it took is not a project file. That is the case the
    second check exists for, and the assertion on %A is the point of it: a
    refusal has to leave the working tree exactly as git handed it over.
    """
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift"])
    code, merged, stderr = run(base, ours, "not a project")
    assert code == 1
    assert merged == ours, "a rejected union must not leave a half-written project behind"
    assert "normalizer rejected the union" in stderr, stderr


def test_the_result_is_normalized():
    """Merging leaves the file in the state the pre-commit hook and CI demand."""
    base = project(["Alpha.swift"])
    code, merged, stderr = run(base, project(["Alpha.swift", "Zeta.swift"]),
                               project(["Alpha.swift", "Beta.swift"]))
    assert code == 0, stderr
    with tempfile.TemporaryDirectory() as directory:
        scratch = Path(directory) / "project.pbxproj"
        scratch.write_text(merged, encoding="utf-8")
        check = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "normalize-pbxproj.py"), "--check", str(scratch)],
            capture_output=True, text=True,
        )
    assert check.returncode == 0, check.stderr or check.stdout


def main():
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    print(f"\n{len(tests)} tests passed")


if __name__ == "__main__":
    main()
