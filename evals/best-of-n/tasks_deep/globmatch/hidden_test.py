from globmatch import IgnoreRules


def rules(*lines):
    return IgnoreRules(lines)


def test_reported_dir_pattern_matches_at_any_depth():
    r = rules("build/")
    assert r.ignored("build", is_dir=True)
    assert r.ignored("packages/app/build", is_dir=True)
    assert not r.ignored("packages/app/build", is_dir=False)  # a file named build


def test_files_inside_ignored_directory():
    r = rules("build/")
    assert r.ignored("build/out.o")
    assert r.ignored("packages/app/build/gen/a.js")
    assert not r.ignored("packages/app/builder.js")
    r = rules("/node_modules")
    assert r.ignored("node_modules/left-pad/index.js")
    assert not r.ignored("web/node_modules/x.js")


def test_negation_cannot_reinclude_under_ignored_dir():
    r = rules("logs/", "!logs/keep.txt")
    assert r.ignored("logs/keep.txt")
    r = rules("logs/*", "!logs/keep.txt")
    assert not r.ignored("logs/keep.txt")
    assert r.ignored("logs/other.txt")
    r = rules("out/", "!out/")
    assert not r.ignored("out/a.txt")


def test_double_star_matches_zero_directories():
    r = rules("a/**/b")
    assert r.ignored("a/b") and r.ignored("a/x/b") and r.ignored("a/x/y/b")
    assert not r.ignored("a/xb")
    r = rules("**/foo")
    assert r.ignored("foo") and r.ignored("x/y/foo")
    r = rules("docs/**/*.md")
    assert r.ignored("docs/readme.md") and r.ignored("docs/a/b/c.md")
    assert not r.ignored("src/docs/readme.md")


def test_anchoring_regressions():
    r = rules("doc/frotz")
    assert r.ignored("doc/frotz") and not r.ignored("a/doc/frotz")
    r = rules("/TODO")
    assert r.ignored("TODO") and not r.ignored("src/TODO")
    r = rules("*.log")
    assert r.ignored("a.log") and r.ignored("x/y/z.log") and not r.ignored("a.log.txt")
    r = rules("abc/**")
    assert r.ignored("abc/x") and r.ignored("abc/x/y") and not r.ignored("abcd/x")


def test_last_rule_wins_and_syntax_regressions():
    r = IgnoreRules.from_text("# comment\n\n*.txt\n!keep.txt\n\\#hash\n\\!bang\ntrail   \nf?o\n[ab].c\n")
    assert r.ignored("x.txt") and not r.ignored("keep.txt") and not r.ignored("d/keep.txt")
    assert r.ignored("#hash") and r.ignored("!bang") and r.ignored("trail")
    assert r.ignored("fxo") and not r.ignored("f/o")
    assert r.ignored("a.c") and r.ignored("d/b.c") and not r.ignored("c.c")
    assert not r.ignored("# comment")


def test_filter_paths_walk():
    r = rules("build/", "*.tmp", "!important.tmp", "/dist")
    entries = ["src/", "src/main.rs", "src/a.tmp", "important.tmp", "build/", "build/x.o",
               "pkg/build/", "pkg/build/y.o", "pkg/build/important.tmp", "dist/", "dist/app.js", "pkg/dist/"]
    assert r.filter_paths(entries) == ["src/", "src/main.rs", "important.tmp", "pkg/dist/"]


def test_star_runs_and_case_regressions():
    r = rules("a**b")
    assert r.ignored("ab") and r.ignored("axyb") and r.ignored("d/axb")
    assert not r.ignored("a/b") and not r.ignored("ax/yb")
    r = rules("**.log")
    assert r.ignored("x/y.log") and r.ignored(".log") and not r.ignored("y.log.z")
    r = rules("*")
    assert r.ignored(".hidden") and r.ignored("a/.b")
    r = rules("Makefile", "*.TXT")
    assert not r.ignored("makefile") and not r.ignored("a.txt") and r.ignored("d/Makefile") and r.ignored("b.TXT")


def test_hostile_patterns_are_fast():
    import os
    import subprocess
    import sys
    import textwrap
    import globmatch
    code = textwrap.dedent("""
        import time
        from globmatch import IgnoreRules
        rules = IgnoreRules(["*a*a*a*a*a*a*a*a*a*b", "**/a/**/a/**/a/**/a/**/a/**/b", "x*y*z*w*v/", "!*a?a?a?a?c"])
        paths = []
        for k in range(50):
            paths.append("src/" + "a" * (40 + k % 20) + ".c")
            paths.append("/".join(["a"] * (20 + k % 15)) + "/c")
            paths.append("x" + "yzwv" * 12 + "q/f")
        t = time.perf_counter()
        hits = sum(rules.ignored(p) for p in paths)
        hits += len(rules.filter_paths(p + "/" for p in paths[:50]))
        el = time.perf_counter() - t
        assert hits == 50, hits
        print(el)
    """)
    try:
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=8,
                             cwd=os.path.dirname(os.path.abspath(globmatch.__file__)))
    except subprocess.TimeoutExpired:
        raise AssertionError("too slow")
    assert out.returncode == 0, out.stderr[-400:]
    assert float(out.stdout.split()[-1]) < 1.5, out.stdout
