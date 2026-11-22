#!/usr/bin/env python3
"""scripts/measure/build-flags.py: the form of a reload's build, read from the reload's own log.

No build and no app: the reload's printed output and its log are small files in a temporary folder, with lines in
the form that xcodebuild writes (a `Build settings from command line` block; for each module the 3 command lines
`builtin-SwiftDriver`, `builtin-Swift-Compilation-Requirements` and `builtin-Swift-Compilation`; a compile command
with no `builtin-` word). So this proves the reader's own logic and the 2 tools' use of its file, NOT that a build
on a Mac writes these lines: the line forms are from a read of one real log.
Run: python3 -I scripts/measure/tests/build-flags.test.py"""
import contextlib, importlib.util, io, json, os, sys, tarfile, tempfile, unittest
from unittest import mock

sys.dont_write_bytecode = True  # the scripts' imports leave no cache folder in the checkout
HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "..", file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


M = load("build_flags_under_test", "build-flags.py")
SWIFTC = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
BENCH_LINE = "==> bench configuration: Release optimization with -DCMUX_BENCH_HOOKS -DCMUX_BLOCKING_CHECKS (no DEBUG)"


def module_lines(name, words):
    """The 3 command lines that Xcode writes for one module."""
    return [f"    builtin-{task} -- {SWIFTC} -module-name {name} {words} @/tmp/dd/{name}.SwiftFileList -sdk /sdk"
            for task in ("SwiftDriver", "Swift-Compilation-Requirements", "Swift-Compilation")]


LOG = "\n".join([
    BENCH_LINE,
    "Command line invocation:",
    "    /usr/bin/xcodebuild -scheme cmux -configuration Release build",
    "",
    "Build settings from command line:",
    "    ARCHS = arm64",
    "    CMUX_SWIFT_OPT_CmuxNextDaemon = -O",
    "    CMUX_SWIFT_OPT_CmuxNextTabs = -O",
    "    OTHER_SWIFT_FLAGS = $(inherited) -DCMUX_BENCH_HOOKS -DCMUX_BLOCKING_CHECKS",
    "    SWIFT_OPTIMIZATION_LEVEL = $(CMUX_SWIFT_OPT_$(TARGET_NAME):default=-Osize)",
    "",
    "SwiftDriver CmuxNextApp normal arm64 com.apple.xcode.tools.swift.compiler (in target 'CmuxNextApp' from project 'CmuxNext')",
    *module_lines("CmuxNextApp", "-Osize -DSWIFT_PACKAGE"),
    *module_lines("CmuxNextSettings", "-Osize -DSWIFT_PACKAGE"),
    *module_lines("CmuxNextDaemon", "-O -DSWIFT_PACKAGE"),
    *module_lines("Fixture", "-Onone -DDEBUG"),
    # A compile command with no `builtin-` word, and the last -O word of 2.
    f"    {SWIFTC} -module-name cmux -Onone -DX -Osize @/tmp/dd/cmux.SwiftFileList",
    f"    builtin-SwiftDriver -- {SWIFTC} -module-name Fast -Ounchecked @/tmp/dd/Fast.SwiftFileList",
    f"    builtin-SwiftDriver -- {SWIFTC} -module-name Plain @/tmp/dd/Plain.SwiftFileList",
    # Lines that are no Swift compile command: an environment line with the compiler's path, a tool that is no
    # compiler with a module name and a level word, a C compile, a link.
    f"    export SWIFT_EXEC\\={SWIFTC}",
    "    /usr/bin/swift-symbolgraph-extract -module-name NotACompile -O",
    "    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -x c -Os -c a.c -o a.o",
    "    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -O -o cmux a.o",
    "** BUILD SUCCEEDED **",
]) + "\n"


class BuildFlags(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def path(self, name):
        return os.path.join(self.dir.name, name)

    def write(self, name, text):
        with open(self.path(name), "w") as f:
            f.write(text)
        return self.path(name)

    def reload_output(self, log=LOG, tag="heldtab"):
        """What the reload printed, with the path of a log that has `log` (None: the log is not there)."""
        at = self.path("reload-own.log")
        if log is not None:
            self.write("reload-own.log", log)
        return self.write("reload.log", f"==> reload starting (tag: {tag}, log: {at})\n==> reload succeeded in 12s\n"), at

    def test_the_log_gives_the_bench_line_the_settings_and_the_counts_of_each_level(self):
        printed, at = self.reload_output()
        record = M.read(printed)
        self.assertEqual((record["log"], record["log_read"]), (at, True))
        self.assertNotIn("not_read", record)
        self.assertEqual(record["bench_configuration"], BENCH_LINE)
        self.assertEqual(record["settings"], {
            "OTHER_SWIFT_FLAGS": "$(inherited) -DCMUX_BENCH_HOOKS -DCMUX_BLOCKING_CHECKS",
            "SWIFT_OPTIMIZATION_LEVEL": "$(CMUX_SWIFT_OPT_$(TARGET_NAME):default=-Osize)",
            "CMUX_SWIFT_OPT": {"-O": ["CmuxNextDaemon", "CmuxNextTabs"]}})
        # 3 lines for each module that Xcode compiled; the command with 2 -O words counts by its last one.
        self.assertEqual(record["swift"]["lines"], {"-Onone": 3, "-O": 3, "-Osize": 7, "other": 1, "none": 1})
        self.assertEqual(record["swift"]["modules"], {
            "-Onone": ["Fixture"], "-O": ["CmuxNextDaemon"], "-Osize": ["CmuxNextApp", "CmuxNextSettings", "cmux"],
            "other": ["Fast"], "none": ["Plain"]})
        self.assertIn("warm folder", record["limit"])

    def test_a_log_of_a_build_that_is_no_bench_build_has_no_bench_line(self):
        printed, _ = self.reload_output(LOG.replace(BENCH_LINE + "\n", ""))
        record = M.read(printed)
        self.assertTrue(record["log_read"])
        self.assertIsNone(record["bench_configuration"])
        self.assertEqual(record["swift"]["lines"]["-Osize"], 7)

    def test_a_build_that_compiled_nothing_has_its_settings_and_counts_of_zero(self):
        settings = LOG.split("SwiftDriver CmuxNextApp")[0] + "** BUILD SUCCEEDED **\n"
        record = M.read(self.reload_output(settings)[0])
        self.assertTrue(record["log_read"])
        self.assertEqual(record["swift"]["lines"], {"-Onone": 0, "-O": 0, "-Osize": 0, "other": 0, "none": 0})
        self.assertEqual(record["settings"]["CMUX_SWIFT_OPT"], {"-O": ["CmuxNextDaemon", "CmuxNextTabs"]})

    def test_a_word_of_another_tool_is_no_level_of_the_swift_compiler(self):
        """`-Os` after `-Xcc` is a word for the C compiler and `-ObjC` is a word for the linker: the Swift compiler
        has the levels -Onone, -O, -Osize, -Ounchecked and -Oplayground only."""
        log = "\n".join([
            f"    builtin-SwiftDriver -- {SWIFTC} -module-name WithACWord -O -Xcc -Os @/tmp/dd/a.SwiftFileList",
            f"    builtin-SwiftDriver -- {SWIFTC} -module-name WithALinkWord -Osize -ObjC @/tmp/dd/b.SwiftFileList",
            f"    builtin-SwiftDriver -- {SWIFTC} -module-name OnlyOtherWords -Xcc -Oz -Objc @/tmp/dd/c.SwiftFileList",
            f"    builtin-SwiftDriver -- {SWIFTC} -module-name Playground -O -Oplayground @/tmp/dd/d.SwiftFileList",
        ]) + "\n"
        record = M.read(self.reload_output(log)[0])
        self.assertEqual(record["swift"]["modules"], {
            "-Onone": [], "-O": ["WithACWord"], "-Osize": ["WithALinkWord"], "other": ["Playground"],
            "none": ["OnlyOtherWords"]})
        self.assertEqual(record["swift"]["lines"], {"-Onone": 0, "-O": 1, "-Osize": 1, "other": 1, "none": 1})

    def test_the_last_reload_line_names_the_log(self):
        printed, at = self.reload_output()
        with open(printed) as f:
            later = f"==> reload starting (tag: old, log: {self.path('gone.log')})\n" + f.read()
        self.assertEqual(M.read(self.write("reload.log", later))["log"], at)

    def test_a_log_that_is_not_there_is_said_and_is_no_fault(self):
        printed, at = self.reload_output(log=None)
        record = M.read(printed)
        self.assertEqual((record["log"], record["log_read"]), (at, False))
        self.assertIn("FileNotFoundError", record["not_read"])
        self.assertNotIn("swift", record)

    def test_an_output_with_no_reload_line_is_said(self):
        record = M.read(self.write("reload.log", "App path:\n  /tmp/x.app\n"))
        self.assertEqual((record["log"], record["log_read"]), (None, False))
        self.assertIn("no `reload starting` line", record["not_read"])

    def test_an_output_file_that_is_not_there_is_said(self):
        record = M.read(self.path("none.log"))
        self.assertEqual((record["log"], record["log_read"]), (None, False))
        self.assertIn("FileNotFoundError", record["not_read"])

    def test_main_prints_one_line_and_writes_the_same_record_with_exit_0(self):
        for log in (LOG, None):
            printed, _ = self.reload_output(log)
            out, said = self.path("build-flags.json"), io.StringIO()
            with contextlib.redirect_stdout(said), mock.patch.object(sys, "argv", ["build-flags.py", printed, "--out", out]):
                self.assertEqual(M.main(), 0)
            lines = said.getvalue().splitlines()
            self.assertEqual(len(lines), 1)
            self.assertTrue(lines[0].startswith("BUILD-FLAGS {"), lines[0][:40])
            with open(out) as f:
                written = json.load(f)
            self.assertEqual(json.loads(lines[0][len("BUILD-FLAGS "):]), written)
            self.assertEqual(written["log_read"], log is not None)
            if log is not None:
                os.remove(self.path("reload-own.log"))

    def test_main_prints_the_line_with_exit_0_when_the_out_file_cannot_be_written(self):
        printed, _ = self.reload_output()
        out, said, errors = self.path("no-folder/build-flags.json"), io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(said), contextlib.redirect_stderr(errors), \
                mock.patch.object(sys, "argv", ["build-flags.py", printed, "--out", out]):
            try:
                code = M.main()
            except OSError as error:
                code = f"main raised {error!r}"
        self.assertEqual(code, 0)
        lines = said.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertTrue(json.loads(lines[0][len("BUILD-FLAGS "):])["log_read"])
        self.assertIn("no-folder", errors.getvalue())


class TheToolsUse(unittest.TestCase):
    """Each of the 2 tools puts the file into its report, and says so when it has none."""

    @classmethod
    def setUpClass(cls):
        cls.tools = {"held-new-tab": load("held_new_tab_for_build_flags", "held-new-tab.py"),
                     "pane-motion-films": load("pane_motion_films_for_build_flags", "pane-motion-films.py")}

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def test_a_tool_takes_the_record_of_the_file(self):
        record = {"log_read": True, "bench_configuration": BENCH_LINE, "swift": {"lines": {"-O": 3}}}
        path = os.path.join(self.dir.name, "build-flags.json")
        with open(path, "w") as f:
            json.dump(record, f)
        for name, tool in self.tools.items():
            self.assertEqual(tool.build_facts(path), record, name)

    def test_a_tool_with_no_file_or_a_file_that_is_no_json_says_not_read(self):
        broken = os.path.join(self.dir.name, "broken.json")
        with open(broken, "w") as f:
            f.write("{")
        for name, tool in self.tools.items():
            self.assertIn("no --build file", tool.build_facts(None)["not_read"], name)
            self.assertIn("broken.json", tool.build_facts(broken)["not_read"], name)
            self.assertIn("none.json", tool.build_facts(os.path.join(self.dir.name, "none.json"))["not_read"], name)

    def test_a_tool_with_a_file_whose_json_is_no_object_says_not_read(self):
        path = os.path.join(self.dir.name, "no-object.json")
        for text in ("[]", "3", "null", '"words"'):
            with open(path, "w") as f:
                f.write(text)
            for name, tool in self.tools.items():
                with self.subTest(tool=name, json=text):
                    got = tool.build_facts(path)
                    self.assertIsInstance(got, dict)
                    self.assertIn("no-object.json: not a JSON object", got.get("not_read", ""))

    def test_each_tool_puts_the_record_into_its_report_and_the_held_key_tool_gives_the_file_to_its_artifact(self):
        """Text only: the `main` of a tool needs an app, so no row calls it."""
        for file in ("held-new-tab.py", "pane-motion-films.py"):
            with open(os.path.join(HERE, "..", file)) as f:
                text = f.read()
            self.assertIn('"build": build_facts(opts.build)', text, file)
            if file == "held-new-tab.py":
                self.assertIn("pack(opts.out, opts.film, opts.artifact, opts.build)", text, file)

    def test_the_held_key_tools_artifact_has_the_file(self):
        out, build = os.path.join(self.dir.name, "measure"), os.path.join(self.dir.name, "build-flags.json")
        os.makedirs(out)
        for path in (os.path.join(out, "report.json"), build):
            with open(path, "w") as f:
                f.write("{}")
        target = os.path.join(self.dir.name, "held-new-tab.tgz")
        pack = self.tools["held-new-tab"].pack
        self.assertEqual(sorted(pack(out, None, target, build)), ["build-flags.json", "report.json"])
        with tarfile.open(target) as tar:
            self.assertEqual(sorted(tar.getnames()), ["build-flags.json", "report.json"])
        self.assertEqual(pack(out, None, target), ["report.json"])
        self.assertEqual(pack(out, None, target, os.path.join(self.dir.name, "none.json")), ["report.json"])

    def test_each_entry_script_reads_the_reloads_log_and_gives_the_file_to_its_tool(self):
        for script, file in (("held-new-tab.sh", '"$out/build-flags.json"'), ("pane-motion-films.sh", '"$out/films/build-flags.json"')):
            with open(os.path.join(HERE, "..", script)) as f:
                text = f.read()
            self.assertIn(f'python3 scripts/measure/build-flags.py "$out/reload.log" --out {file} || true', text, script)
            self.assertIn(f"--build {file}", text, script)
            self.assertLess(text.index("scripts/reload.sh --tag"), text.index("scripts/measure/build-flags.py \""), script)
        with open(os.path.join(HERE, "..", "pane-motion-films.sh")) as f:
            self.assertIn("-name 'build-flags.json'", f.read())


if __name__ == "__main__":
    unittest.main()
