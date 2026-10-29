#!/usr/bin/env python3
"""Contracts for the project.pbxproj git merge driver.

The driver must merge the everyday conflict, two branches each adding a
different source file, and must refuse anything else, so a disagreement about
the same lines still reaches the author as a normal git conflict. It must also
never leave a project file behind that Xcode cannot open, which is why a union
the normalizer rejects counts as a refusal rather than a result.
"""

import hashlib
import importlib.util
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "scripts" / "merge-pbxproj.py"
GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_AUTHOR_NAME": "Merge Test",
    "GIT_AUTHOR_EMAIL": "merge@example.invalid",
    "GIT_COMMITTER_NAME": "Merge Test",
    "GIT_COMMITTER_EMAIL": "merge@example.invalid",
}


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


def load_driver(name="merge_pbxproj_test"):
    spec = importlib.util.spec_from_file_location(name, DRIVER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def test_same_file_with_different_object_ids_is_refused():
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift", "Shared.swift"])
    theirs = project(["Alpha.swift", "Shared.swift"])
    theirs = theirs.replace(uuid("frShared.swift"), uuid("frShared.swift-theirs"))
    theirs = theirs.replace(uuid("bfShared.swift"), uuid("bfShared.swift-theirs"))

    code, merged, stderr = run(base, ours, theirs)

    assert code == 1
    assert "same logical file" in stderr, stderr
    assert "<" * 32 in merged


def test_same_file_with_only_different_build_ids_is_refused():
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift", "Shared.swift"])
    theirs = project(["Alpha.swift", "Shared.swift"]).replace(
        uuid("bfShared.swift"), uuid("bfShared.swift-theirs")
    )

    code, _, stderr = run(base, ours, theirs)

    assert code == 1
    assert "same logical file" in stderr, stderr


def test_quoted_path_cannot_hide_the_same_file_with_different_ids():
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift", "Shared.swift"])
    theirs = project(["Alpha.swift", "Shared.swift"])
    theirs = theirs.replace(uuid("frShared.swift"), uuid("frShared.swift-theirs"))
    theirs = theirs.replace(uuid("bfShared.swift"), uuid("bfShared.swift-theirs"))
    theirs = theirs.replace("path = Shared.swift;", 'path = "Shared.swift";')

    code, _, stderr = run(base, ours, theirs)

    assert code == 1
    assert "same logical file" in stderr, stderr


def test_same_file_at_different_insertion_positions_is_refused():
    base = project(["Alpha.swift", "Zeta.swift"])
    ours = project(["Alpha.swift", "Shared.swift", "Zeta.swift"])
    theirs = project(["Alpha.swift", "Zeta.swift", "Shared.swift"])
    theirs = theirs.replace(uuid("frShared.swift"), uuid("frShared.swift-theirs"))
    theirs = theirs.replace(uuid("bfShared.swift"), uuid("bfShared.swift-theirs"))

    code, merged, stderr = run(base, ours, theirs)

    assert code == 1
    assert "same logical file" in stderr, stderr
    assert "<" * 32 in merged


def test_one_sided_change_applies():
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift"])
    theirs = project(["Alpha.swift", "Theirs.swift"])
    code, merged, stderr = run(base, ours, theirs)
    assert code == 0, stderr
    assert entries(merged, "Theirs.swift") == REGIONS, merged


def test_one_sided_existing_entry_edit_does_not_collide_with_unrelated_addition():
    base = project(["Alpha.swift", "Zeta.swift"])
    ours = base.replace(
        "path = Alpha.swift; sourceTree = \"<group>\";",
        "path = Alpha.swift; includeInIndex = 1; sourceTree = \"<group>\";",
    )
    theirs = project(["Alpha.swift", "Zeta.swift", "Theirs.swift"])

    code, merged, stderr = run(base, ours, theirs)

    assert code == 0, stderr
    assert "includeInIndex = 1" in merged
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



def test_git_merge_leaves_conflict_markers_and_unmerged_stages():
    """A failing custom driver must write conflict output itself; Git will not."""
    with tempfile.TemporaryDirectory() as directory:
        repo = Path(directory)
        def git(*args):
            return subprocess.run(["git", "-C", str(repo), "-c", "core.hooksPath=/dev/null",
                                   *args], capture_output=True, text=True)
        assert git("init", "-b", "ours").returncode == 0
        git("config", "user.name", "Merge Test")
        git("config", "user.email", "merge@example.invalid")
        git("config", "merge.pbxproj.driver",
            f"{shlex.quote(sys.executable)} {shlex.quote(str(DRIVER))} %O %A %B %P")
        path = repo / "project.pbxproj"
        (repo / ".gitattributes").write_text("project.pbxproj merge=pbxproj\n")
        path.write_text(project(["Alpha.swift"], settings="5.0"))
        git("add", ".")
        assert git("commit", "-m", "base").returncode == 0
        git("branch", "theirs")
        path.write_text(project(["Alpha.swift"], settings="6.0"))
        git("commit", "-am", "ours")
        git("checkout", "theirs")
        path.write_text(project(["Alpha.swift"], settings="6.1"))
        git("commit", "-am", "theirs")
        git("checkout", "ours")
        result = git("merge", "theirs")
        assert result.returncode != 0, result.stdout
        assert len(git("ls-files", "--unmerged").stdout.splitlines()) == 3
        merged = path.read_text()
        assert "<<<<<<<" in merged and "=======" in merged and ">>>>>>>" in merged, merged
        assert "SWIFT_VERSION = 6.0" in merged and "SWIFT_VERSION = 6.1" in merged


def test_a_side_carrying_conflict_markers_is_refused():
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift"]).replace(
        "\tarchiveVersion = 1;", "<" * 32 + " HEAD\n\tarchiveVersion = 1;"
    )
    theirs = project(["Alpha.swift", "Theirs.swift"])
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1
    assert "conflict-marker" in stderr, stderr
    assert merged.startswith("<" * 32 + " ours\n")
    assert "\n" + "|" * 32 + " base\n" in merged
    assert "\n" + "=" * 32 + "\n" in merged
    assert merged.endswith(">" * 32 + " theirs\n")
    assert base.rstrip() in merged and ours.rstrip() in merged and theirs.rstrip() in merged


def test_invalid_utf8_leaves_an_explicit_byte_preserving_conflict():
    with tempfile.TemporaryDirectory() as directory:
        paths = [Path(directory) / name for name in ("base", "ours", "theirs")]
        payloads = [b"base\xff\n", b"ours\xfe\n", b"theirs\xfd\n"]
        for path, payload in zip(paths, payloads):
            path.write_bytes(payload)
        result = subprocess.run(
            [sys.executable, str(DRIVER), *(str(path) for path in paths), "project.pbxproj"],
            capture_output=True,
        )
        assert result.returncode == 1
        conflicted = paths[1].read_bytes()
        assert b"<" * 32 in conflicted
        assert all(payload.rstrip() in conflicted for payload in payloads)
        assert b"Traceback" not in result.stderr


def test_missing_input_leaves_an_explicit_conflict_in_ours():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        base = root / "missing-base"
        ours = root / "ours"
        theirs = root / "theirs"
        ours_text = project(["Ours.swift"])
        theirs_text = project(["Theirs.swift"])
        ours.write_text(ours_text, encoding="utf-8")
        theirs.write_text(theirs_text, encoding="utf-8")

        result = subprocess.run(
            [sys.executable, str(DRIVER), str(base), str(ours), str(theirs),
             "cmux.xcodeproj/project.pbxproj"],
            capture_output=True,
            text=True,
        )

        assert result.returncode == 1
        conflicted = ours.read_text(encoding="utf-8")
        assert "<" * 32 in conflicted
        assert "could not read base" in conflicted
        assert ours_text.rstrip() in conflicted and theirs_text.rstrip() in conflicted
        assert "cannot read merge inputs" in result.stderr


def test_helper_load_failure_still_materializes_a_conflict():
    module = load_driver("merge_pbxproj_failure_test")
    module.load_mergers = lambda: (_ for _ in ()).throw(SyntaxError("broken helper"))
    with tempfile.TemporaryDirectory() as directory:
        paths = [Path(directory) / name for name in ("base", "ours", "theirs")]
        texts = [project(["Base.swift"]), project(["Ours.swift"]), project(["Theirs.swift"])]
        for path, text in zip(paths, texts):
            path.write_text(text, encoding="utf-8")
        code = module.main(["merge-pbxproj.py", *(str(path) for path in paths), "project.pbxproj"])
        assert code == 1
        conflicted = paths[1].read_text(encoding="utf-8")
        assert "<" * 32 in conflicted
        assert all(text.rstrip() in conflicted for text in texts)


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
    assert "<" * 32 in merged, "a failed custom merge must materialize the conflict in %A"
    assert "path = Ours.swift;" in merged and "path = Other.swift;" in merged
    assert "only distinct added lines can be merged" in stderr, stderr


def test_a_real_git_merge_leaves_markers_and_unmerged_stages():
    """Git does not provide its own conflict text after a custom driver fails."""
    with tempfile.TemporaryDirectory() as directory:
        repo = Path(directory)
        project_path = repo / "cmux.xcodeproj" / "project.pbxproj"

        def git(*args, check=True):
            return subprocess.run(
                ["git", *args], cwd=repo, capture_output=True, text=True, check=check,
                env=GIT_ENV,
            )

        git("init", "-q", "-b", "main")
        git("config", "core.hooksPath", "/dev/null")
        git("config", "commit.gpgSign", "false")
        git("config", "merge.pbxproj.driver",
            f"{sys.executable} {DRIVER} %O %A %B %P")
        (repo / ".gitattributes").write_text(
            "cmux.xcodeproj/project.pbxproj merge=pbxproj\n", encoding="utf-8"
        )
        project_path.parent.mkdir()
        project_path.write_text(project(["Alpha.swift"], settings="5.0"), encoding="utf-8")
        git("add", ".")
        git("commit", "-qm", "base")
        git("branch", "theirs")

        project_path.write_text(project(["Alpha.swift"], settings="6.0"), encoding="utf-8")
        git("commit", "-qam", "ours")
        git("switch", "-q", "theirs")
        project_path.write_text(project(["Alpha.swift"], settings="6.1"), encoding="utf-8")
        git("commit", "-qam", "theirs")
        git("switch", "-q", "main")

        merge = git("merge", "theirs", check=False)
        assert merge.returncode != 0
        assert git("ls-files", "--unmerged").stdout.strip(), "the index must remain unmerged"
        conflicted = project_path.read_text(encoding="utf-8")
        assert "<" * 32 in conflicted
        assert "SWIFT_VERSION = 6.0" in conflicted
        assert "SWIFT_VERSION = 6.1" in conflicted


def test_a_union_the_normalizer_rejects_is_refused():
    """The driver writes over %A, so a project Xcode could not open must not pass.

    Here the union itself succeeds: ours matches the base, so a three-way merge
    takes theirs wholesale without ever seeing a conflict. Only the normalizer
    notices that what it took is not a project file. That is the case the
    second check exists for, and the assertion on %A is the point of it: a
    refusal has to leave an explicit conflict in the working tree.
    """
    base = project(["Alpha.swift"])
    ours = project(["Alpha.swift"])
    code, merged, stderr = run(base, ours, "not a project")
    assert code == 1
    assert "<" * 32 in merged, "a rejected union must leave an explicit semantic conflict"
    assert ours in merged and "not a project" in merged
    assert "normalizer rejected the union" in stderr, stderr


def test_order_sensitive_insertions_are_refused():
    """Distinct array entries are not a set when their execution order matters."""
    marker = "/* Begin XCBuildConfiguration section */"
    target = f"""/* Begin PBXNativeTarget section */
\t\t{uuid('target')} /* app */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildPhases = (
\t\t\t\t{uuid('compile')} /* Compile */,
\t\t\t);
\t\t\tname = app;
\t\t}};
/* End PBXNativeTarget section */

"""
    base = project(["Alpha.swift"]).replace(marker, target + marker)
    needle = "\t\t\tbuildPhases = (\n"
    # The .swift suffix deliberately matches the old text-only allowlist.
    ours = base.replace(needle, needle + f"\t\t\t\t{uuid('phase-a')} /* Consumer.swift */,\n")
    theirs = base.replace(needle, needle + f"\t\t\t\t{uuid('phase-b')} /* Producer.swift */,\n")
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1
    assert "<" * 32 in merged
    assert "automatic union is limited to source-file project entries" in stderr


def test_nested_dictionary_cannot_spoof_a_top_level_object_entry():
    marker = "/* End PBXBuildFile section */"
    holder = f"""\t\t{uuid('holder')} /* holder */ = {{
\t\t\tisa = PBXBuildFile;
\t\t\tsettings = {{
\t\t\t\tBASE = 1;
\t\t\t}};
\t\t}};
"""
    base = project(["Alpha.swift"]).replace(marker, holder + marker)
    needle = "\t\t\tsettings = {\n"
    ours = base.replace(
        needle,
        needle + f"\t\t{uuid('nested-a')} /* NestedA.swift */ = {{isa = PBXBuildFile; fileRef = X; }};\n",
    )
    theirs = base.replace(
        needle,
        needle + f"\t\t{uuid('nested-b')} /* NestedB.swift */ = {{isa = PBXBuildFile; fileRef = Y; }};\n",
    )
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1
    assert "<" * 32 in merged
    assert "automatic union is limited to source-file project entries" in stderr


def test_section_markers_are_comments_at_the_objects_dictionary_depth():
    module = load_driver("merge_pbxproj_location_test")
    mergers = module.load_mergers()
    text = project(["Alpha.swift"])

    begin = text.index("/* Begin PBXGroup section */") + len("/* Begin PBXGroup section */")
    section, depth, array = module.project_location(mergers, text[:begin])
    assert (section, depth, array) == ("PBXGroup", 2, None)

    child = text.index("/* Alpha.swift */,", begin)
    section, depth, array = module.project_location(mergers, text[:child])
    assert (section, depth, array) == ("PBXGroup", 3, "children")

    end = text.index("/* End PBXGroup section */") + len("/* End PBXGroup section */")
    section, depth, array = module.project_location(mergers, text[:end])
    assert (section, depth, array) == (None, 2, None)


def test_marker_text_in_a_quoted_scalar_cannot_spoof_a_section():
    marker = "/* Begin XCBuildConfiguration section */"
    target = f'''/* Begin PBXNativeTarget section */
\t\t{uuid('target')} /* app */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tnote = "before
/* Begin PBXGroup section */
after";
\t\t\tchildren = (
\t\t\t\t{uuid('existing')} /* Existing.swift */,
\t\t\t);
\t\t\tname = app;
\t\t}};
/* End PBXNativeTarget section */

'''
    base = project(["Alpha.swift"]).replace(marker, target + marker)
    needle = 'after";\n\t\t\tchildren = (\n'
    ours = base.replace(
        needle, needle + f"\t\t\t\t{uuid('spoof-a')} /* Consumer.swift */,\n", 1
    )
    theirs = base.replace(
        needle, needle + f"\t\t\t\t{uuid('spoof-b')} /* Producer.swift */,\n", 1
    )
    code, merged, stderr = run(base, ours, theirs)
    assert code == 1
    assert "<" * 32 in merged
    assert "automatic union is limited to source-file project entries" in stderr


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
