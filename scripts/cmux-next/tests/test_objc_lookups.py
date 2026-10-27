#!/usr/bin/env python3
"""check-objc-selectors.py private API lookups (p10-stability-193): each lookup kind refused without its guard and
passed with it, the generated os-matrix probe in step with the sources, and --record reading a results folder into
the table per macOS major (and failing when a name the table records is gone). Runs anywhere (no Mac, no build).
Run: python3 -I scripts/cmux-next/tests/test_objc_lookups.py"""
import importlib.util, json, os, subprocess, sys, tempfile, unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "check-objc-selectors.py"
REPO = HERE.parents[2]

spec = importlib.util.spec_from_file_location("check_objc_selectors", SCRIPT)
check = importlib.util.module_from_spec(spec)
sys.modules["check_objc_selectors"] = check
spec.loader.exec_module(check)


def verdicts(body: str) -> list[tuple[str, str | None, bool]]:
    return [(l.call, l.key, l.guarded) for l in check.scan_lookups(body)]


def unguarded(body: str) -> list[str]:
    return [l.call for l in check.scan_lookups(body) if not l.guarded]


class Classes(unittest.TestCase):
    def test_optional_class_lookup_passes(self):
        self.assertEqual(verdicts('func f() -> AnyClass? {\n    guard let c = NSClassFromString("CABackdropLayer") else '
                                  '{ return nil }\n    return c\n}\n'),
                         [("NSClassFromString", "class CABackdropLayer", True)])

    def test_forced_and_cast_lookups_refused(self):
        self.assertEqual(unguarded('let a = NSClassFromString("X")!\n'), ["NSClassFromString"])
        self.assertEqual(unguarded('let b = NSClassFromString("X") as! NSObject.Type\n'), ["NSClassFromString"])
        self.assertEqual(unguarded('let c = NSClassFromString("X") as? NSObject.Type\n'), [])

    def test_bound_then_forced_refused_unless_checked_first(self):
        self.assertEqual(unguarded('func f() {\n    let c = NSClassFromString("X")\n    use(c!)\n}\n'),
                         ["NSClassFromString"])
        self.assertEqual(unguarded('func f() {\n    let c = NSClassFromString("X")\n    guard c != nil else { return }\n'
                                   '    use(c!)\n}\n'), [])

    def test_dlsym_bitcast_refused(self):
        self.assertEqual(unguarded('let f = unsafeBitCast(dlsym(h, "sym"), to: F.self)\n'), ["dlsym"])
        found = check.scan_lookups('func f() {\n    guard let s = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), '
                                   '"swift_demangle") else { return }\n}\n')
        self.assertEqual([(l.key, l.guarded) for l in found], [("symbol swift_demangle", True)])

    def test_implicitly_unwrapped_dlsym_refused(self):
        # dlsym is imported as `-> UnsafeMutableRawPointer!`: a member access or a non-optional binding unwraps it.
        self.assertEqual(unguarded('func f() -> CFString {\n    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), '
                                   '"kFoo").assumingMemoryBound(to: CFString.self).pointee\n}\n'), ["dlsym"])
        self.assertEqual(unguarded('func f() {\n    let p: UnsafeMutableRawPointer = dlsym(h, "kFoo")\n    use(p)\n}\n'),
                         ["dlsym"])
        self.assertEqual(unguarded('let p = objc_getClass("X").debugDescription\n'), [])
        self.assertEqual(unguarded('let p = objc_getClass("X").hash\n'), ["objc_getClass"])
        self.assertEqual(unguarded('func f() {\n    let p: UnsafeMutableRawPointer? = dlsym(h, "kFoo")\n    use(p)\n}\n'), [])
        self.assertEqual(unguarded('let p = dlsym(h, "kFoo")?.load(as: Int.self)\n'), [])
        self.assertEqual(unguarded('let p = dlsym(h, "kFoo").map { $0 }\n'), [])

    def test_wrapped_bitcast_iuo_binding_and_grouped_force_refused(self):
        self.assertEqual(unguarded('let f = unsafeBitCast(\n    dlsym(UnsafeMutableRawPointer(bitPattern: -2), '
                                   '"CGSMainConnectionID"),\n    to: F.self)\n'), ["dlsym"])
        self.assertEqual(unguarded('let c: AnyClass! = NSClassFromString("X")\n'), ["NSClassFromString"])
        self.assertEqual(unguarded('let c = (NSClassFromString("X"))!\n'), ["NSClassFromString"])
        self.assertEqual(unguarded('let c = (NSClassFromString("X") as? NSView.Type)!\n'), ["NSClassFromString"])
        self.assertEqual(unguarded('let c = (NSClassFromString("X") as? NSView.Type)?.init()\n'), [])
        self.assertEqual(unguarded('let n = use(NSClassFromString("X"))!\n'), [])  # the call's result, not the lookup

    def test_condition_list_continuation_is_conditional(self):
        body = ('func f() {\n    guard let x = y,\n          let c = NSClassFromString("X") else { return }\n'
                '    use(c)\n}\n')
        self.assertEqual(unguarded(body), [])


class Selectors(unittest.TestCase):
    def test_unchecked_send_refused(self):
        self.assertEqual(unguarded('func f(_ v: NSView) {\n    v.perform(NSSelectorFromString("_x"))\n}\n'),
                         ["NSSelectorFromString"])

    def test_bound_selector_checked_in_function(self):
        body = ('func f(_ v: NSView) {\n    let sel = NSSelectorFromString("_x")\n    guard v.responds(to: sel) '
                'else { return }\n    v.perform(sel)\n}\n')
        self.assertEqual(verdicts(body), [("NSSelectorFromString", "selector NSView _x", True)])

    def test_each_use_of_a_bound_selector_is_judged(self):
        # A safe use (an action, a comparison) does not cover a send in the same function.
        body = ('func f(_ v: NSView) {\n    let sel = NSSelectorFromString("_foo:")\n'
                '    let item = NSMenuItem(title: "", action: sel, keyEquivalent: "")\n    v.perform(sel, with: item)\n}\n')
        self.assertEqual(unguarded(body), ["NSSelectorFromString"])
        body = ('func f(_ v: NSView, _ i: NSMenuItem) {\n    let sel = NSSelectorFromString("_foo:")\n'
                '    if i.action == sel {}\n    v.perform(sel, with: i)\n}\n')
        self.assertEqual(unguarded(body), ["NSSelectorFromString"])
        body = ('func f(_ v: NSView, _ i: NSMenuItem) {\n    let sel = NSSelectorFromString("_foo:")\n'
                '    i.action = sel\n    if i.action == sel {}\n}\n')
        self.assertEqual(unguarded(body), [])

    def test_check_after_the_send_does_not_count(self):
        body = ('func f(_ v: NSView) {\n    let sel = NSSelectorFromString("_foo:")\n    v.perform(sel)\n'
                '    _ = v.responds(to: sel)\n}\n')
        self.assertEqual(unguarded(body), ["NSSelectorFromString"])
        body = ('enum E {\n    static let sel = NSSelectorFromString("_x")\n}\n'
                'func f(_ v: NSView) {\n    v.perform(E.sel)\n    _ = v.responds(to: E.sel)\n}\n')
        self.assertEqual(unguarded(body), ["NSSelectorFromString"])

    def test_check_in_another_function_does_not_count(self):
        body = ('func f(_ v: NSView) {\n    let sel = NSSelectorFromString("_x")\n    v.perform(sel)\n}\n'
                'func g(_ v: NSView, _ sel: Selector) -> Bool {\n    v.responds(to: sel)\n}\n')
        self.assertEqual(unguarded(body), ["NSSelectorFromString"])

    def test_stored_selector_checked_anywhere_in_its_file(self):
        body = ('enum E {\n    static let sel = NSSelectorFromString("_x")\n}\n'
                'func f(_ v: NSView) {\n    if v.responds(to: E.sel) { v.perform(E.sel) }\n}\n')
        self.assertEqual(unguarded(body), [])

    def test_injected_responds_seam_counts(self):
        body = ('struct S {\n    static let sel = NSSelectorFromString("_x")\n    let responds: (Selector) -> Bool\n'
                '    func ok() -> Bool { responds(Self.sel) }\n}\n')
        self.assertEqual(unguarded(body), [])

    def test_inline_checked_and_action_and_compare(self):
        self.assertEqual(unguarded('let a = v.responds(to: NSSelectorFromString("_x"))\n'), [])
        self.assertEqual(unguarded('let i = NSMenuItem(title: "", action: Selector(("undo:")), keyEquivalent: "")\n'), [])
        self.assertEqual(unguarded('let i = item(t, Selector(("undo:")), "z")\n'), ["Selector"])
        self.assertEqual(unguarded('textView.doCommand(by: NSSelectorFromString(name))\n'), [])
        body = 'static let act = NSSelectorFromString("t:")\nfunc v(_ i: NSMenuItem) -> Bool {\n    switch i.action {\n' \
               '    case Self.act: return true\n    default: return false\n    }\n}\n'
        self.assertEqual(unguarded(body), [])
        # `case Self.act:` is a comparison, not a label.
        body = 'extension C {\n    static let act = NSSelectorFromString("t:")\n    func v(_ i: NSMenuItem) {\n' \
               '        switch i.action {\n        case Self.act: break\n        default: break\n        }\n    }\n}\n'
        self.assertEqual(unguarded(body), [])

    def test_selector_conversion_is_not_a_lookup(self):
        self.assertEqual(verdicts("let s = Selector(other)\n"), [])

    def test_allow_comments(self):
        self.assertEqual(unguarded('// selector-allow: NSObject has it on every macOS\nlet s = NSSelectorFromString("a")\n'), [])
        self.assertEqual(unguarded('// crash-allow: reviewed\nlet s = NSSelectorFromString("a")\n'), [])


class KVC(unittest.TestCase):
    def test_literal_key_needs_its_accessor_checked(self):
        self.assertEqual(unguarded('func f(_ v: WKWebView) {\n    v.setValue(false, forKey: "drawsBackground")\n}\n'),
                         ["setValue"])
        body = ('func f(_ v: WKWebView) {\n    guard v.responds(to: NSSelectorFromString("_setDrawsBackground:")) else '
                '{ return }\n    v.setValue(false, forKey: "drawsBackground")\n}\n')
        self.assertEqual(unguarded(body), [])
        body = ('func f(_ i: NSObject) -> Bool {\n    guard i.responds(to: Selector(("isVisible"))) else { return false }\n'
                '    return i.value(forKey: "visible") as? Bool ?? false\n}\n')
        self.assertEqual(unguarded(body), [])

    def test_check_after_the_call_does_not_count(self):
        body = ('func f(_ v: WKWebView) {\n    v.setValue(false, forKey: "drawsBackground")\n'
                '    _ = v.responds(to: NSSelectorFromString("setDrawsBackground:"))\n}\n')
        self.assertEqual(unguarded(body), ["setValue"])  # the later lookup is itself checked inline

    def test_computed_keys_and_key_paths_skipped(self):
        self.assertEqual(verdicts("f.setValue(x, forKey: kCIInputImageKey)\n"), [])
        self.assertEqual(verdicts('l.setValue(x, forKeyPath: "transform.rotation.z")\n'), [])
        self.assertEqual(verdicts("func value(for key: Key) -> Value? { index(forKey: key) }\n"), [])


class Swizzles(unittest.TestCase):
    def test_replace_needs_a_method_lookup(self):
        self.assertEqual(unguarded('func h(_ c: AnyClass, _ i: IMP) {\n    class_replaceMethod(c, s, i, "v@:")\n}\n'),
                         ["class_replaceMethod"])
        body = ('func h(_ c: AnyClass, _ i: IMP) {\n    guard let m = class_getInstanceMethod(c, s) else { return }\n'
                '    class_replaceMethod(c, s, i, method_getTypeEncoding(m))\n}\n')
        self.assertEqual(unguarded(body), [])

    def test_set_implementation_takes_a_found_method(self):
        self.assertEqual(unguarded("func h(_ m: Method, _ i: IMP) {\n    method_setImplementation(m, i)\n}\n"), [])


class Receivers(unittest.TestCase):
    """A selector or KVC key is probed on the class the source sends it to, or not at all."""

    def keys(self, body: str) -> list[str | None]:
        return [l.key for l in check.scan_lookups(body)]

    def test_declared_parameter_and_extension_self(self):
        body = ('func f(_ webView: WKWebView) {\n    guard webView.responds(to: NSSelectorFromString("_inspector")) else '
                '{ return }\n    _ = webView.value(forKey: "_inspector")\n}\n')
        self.assertEqual(self.keys(body), ["selector WKWebView _inspector", "kvc-get WKWebView _inspector"])
        body = ('extension NSWindow {\n    var radius: CGFloat {\n        guard responds(to: NSSelectorFromString("_r")) '
                'else { return 0 }\n        return self.value(forKey: "_r") as? CGFloat ?? 0\n    }\n}\n')
        self.assertEqual(self.keys(body), [None, "kvc-get NSWindow _r"])  # a bare responds(...) names no receiver

    def test_class_lookup_instances_and_class_methods(self):
        body = ('func f() {\n    guard let cls = NSClassFromString("_WKContentWorldConfiguration") as? NSObject.Type '
                'else { return }\n    let config = cls.init()\n    let sel = NSSelectorFromString("setName:")\n'
                '    let make = NSSelectorFromString("_worldWith:")\n'
                '    guard config.responds(to: sel), (WKContentWorld.self as AnyObject).responds(to: make) else { return }\n'
                '    config.setValue("n", forKey: "name")\n}\n')
        self.assertEqual(self.keys(body), ["class _WKContentWorldConfiguration",
                                           "selector _WKContentWorldConfiguration setName:",
                                           "selector +WKContentWorld _worldWith:",
                                           "kvc-set _WKContentWorldConfiguration name"])
        self.assertEqual(self.keys('let ok = WKWebView.instancesRespond(to: NSSelectorFromString("_frames:"))\n'),
                         ["selector WKWebView _frames:"])

    def test_generic_unknown_and_non_os_receivers_not_probed(self):
        body = ('func f(_ node: AnyObject, _ o: NSObject) {\n    guard node.responds(to: NSSelectorFromString("info")), '
                'o.responds(to: NSSelectorFromString("key")) else { return }\n    _ = node.value(forKey: "info")\n'
                '    _ = o.value(forKey: "key")\n    _ = $0.value(forKey: "key")\n}\n')
        self.assertEqual(self.keys(body), [None] * 5)
        body = ('func f(_ w: CefNSWindow, _ filter: CIFilter) {\n    guard w.responds(to: NSSelectorFromString("_x")) else '
                '{ return }\n    filter.setValue(v, forKey: "inputRVector")\n}\n')
        self.assertEqual(self.keys(body), [None, None])
        self.assertEqual(self.keys('let a: AnyClass? = NSClassFromString("CefNSWindow")\n'
                                   'let b = dlsym(h, "ghostty_set_trace_hook")\nlet c = dlsym(h, "CGSMainConnectionID")\n'),
                         [None, None, "symbol CGSMainConnectionID"])


class Probe(unittest.TestCase):
    KEYS = ["class CABackdropLayer", "kvc-get WKWebView _inspector", "selector WKWebView _x:", "symbol swift_demangle"]

    def test_plans(self):
        self.assertEqual(check.probe_plan("kvc-get NSWindow visible")[:3],
                         ("method", "NSWindow", ["getVisible", "visible", "isVisible", "_visible"]))
        self.assertEqual(check.probe_plan("kvc-set _WKContentWorldConfiguration name")[2], ["setName:", "_setName:"])
        self.assertEqual(check.probe_plan("selector WKWebView _x:"), ("method", "WKWebView", ["_x:"], []))
        self.assertEqual(check.probe_plan("selector +CAFilter filterWithType:"),
                         ("classmethod", "CAFilter", ["filterWithType:"], []))
        self.assertEqual(check.probe_plan("symbol swift_demangle"), ("symbol", "", ["swift_demangle"], []))

    def test_source_round_trips_and_rejects_hand_edits(self):
        source = check.probe_source(self.KEYS)
        keyset, keys = check.parse_probe_source(source)
        self.assertEqual(keys, self.KEYS)
        self.assertEqual(keyset, check.keyset_id(self.KEYS))
        with self.assertRaises(ValueError):
            check.parse_probe_source(source.replace('"symbol swift_demangle"', '"symbol other"', 1))

    def test_checked_in_probe_matches_the_sources(self):
        done = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(REPO), "--lookups"],
                              capture_output=True, text=True)
        self.assertNotIn("does not probe the current lookups", done.stderr)
        self.assertEqual(done.returncode, 0, done.stderr[-2000:])

    def test_output_parsing(self):
        keyset = check.keyset_id(self.KEYS)
        out = f"ABSENT selector WKWebView _x:\nobjc-lookups macOS 14.8.7 keyset {keyset}: 4 keys, 1 absent\n"
        version, answers = check.parse_probe_output(out, keyset, self.KEYS)
        self.assertEqual(version, "14.8.7")
        self.assertEqual(answers["selector WKWebView _x:"], False)
        self.assertEqual(answers["class CABackdropLayer"], True)
        with self.assertRaises(ValueError):  # cut output
            check.parse_probe_output(f"objc-lookups macOS 14.8.7 keyset {keyset}: 4 keys, 1 absent\n", keyset, self.KEYS)
        with self.assertRaises(ValueError):  # another key set
            check.parse_probe_output("objc-lookups macOS 14.8.7 keyset 0000: 4 keys, 0 absent\n", keyset, self.KEYS)
        with self.assertRaises(ValueError):  # no summary
            check.parse_probe_output("ABSENT selector WKWebView _x:\n", keyset, self.KEYS)


class Record(unittest.TestCase):
    """--record over a fake repository and an os-matrix results folder."""

    SOURCE = ('func f(_ v: WKWebView) {\n    let sel = NSSelectorFromString("_x:")\n'
              '    guard v.responds(to: sel) else { return }\n    v.perform(sel, with: nil)\n}\n'
              'let cls: AnyClass? = NSClassFromString("CABackdropLayer")\n')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        src = self.root / "Packages/macOS/Kit/Sources/Kit"
        src.mkdir(parents=True)
        (src / "A.swift").write_text(self.SOURCE)
        (self.root / "scripts/cmux-next").mkdir(parents=True)
        (self.root / "scripts/fuzz/macos-matrix/probes").mkdir(parents=True)
        (self.root / check.TABLE).write_text(json.dumps({"macos": [], "keys": {}}))

    def tearDown(self):
        self.tmp.cleanup()

    def run_check(self, *args):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(self.root), *args],
                              capture_output=True, text=True)

    def results(self, answers_by_os: dict[str, set[str]], verdict="PASS"):
        keyset, keys = check.parse_probe_source((self.root / check.PROBE_FILE).read_text())
        out = self.root / "out"
        for version, absent in answers_by_os.items():
            folder = out / version.split(".")[0]
            folder.mkdir(parents=True, exist_ok=True)
            stdout = "".join(f"ABSENT {k}\n" for k in sorted(absent))
            stdout += f"objc-lookups macOS {version} keyset {keyset}: {len(keys)} keys, {len(absent)} absent\n"
            (folder / "probe.stdout").write_text(stdout)
            (folder / "result.json").write_text(json.dumps({"probe": check.PROBE_NAME, "verdict": verdict,
                                                            "os": version, "exit_code": 0, "stdout": stdout}))
        return out

    def test_probe_stale_fails_then_record_writes_per_major(self):
        stale = self.run_check("--lookups")
        self.assertEqual(stale.returncode, 1)
        self.assertIn("does not probe the current lookups", stale.stderr)
        self.assertEqual(self.run_check("--write-probe").returncode, 0)
        self.assertEqual(self.run_check("--lookups").returncode, 0)
        out = self.results({"14.8.7": {"selector WKWebView _x:"}, "15.7.7": set(), "26.6.2": set(), "27.0": set()})
        done = self.run_check("--record", str(out), "--write")
        self.assertEqual(done.returncode, 0, done.stderr)
        table = json.loads((self.root / check.TABLE).read_text())
        self.assertEqual(table["lookup_majors"], ["14", "15", "26", "27"])
        self.assertEqual(table["lookups"]["selector WKWebView _x:"], {"14": False, "15": True, "26": True, "27": True})
        self.assertEqual(table["lookups"]["class CABackdropLayer"], {"14": True, "15": True, "26": True, "27": True})
        # A later run where macOS 27 lost a recorded name fails without --write.
        gone = self.results({"27.1": {"class CABackdropLayer"}})
        refused = self.run_check("--record", str(gone))
        self.assertEqual(refused.returncode, 1)
        self.assertIn("macOS 27 no longer has class CABackdropLayer", refused.stderr)

    def test_no_verdict_major_is_reported_not_recorded(self):
        self.run_check("--write-probe")
        out = self.results({"14.8.7": set()}, verdict="NO-VERDICT")
        done = self.run_check("--record", str(out), "--write")
        self.assertEqual(done.returncode, 2)
        self.assertIn("no answers on macOS 14.8.7", done.stderr)
        self.assertNotIn("lookups", json.loads((self.root / check.TABLE).read_text()))

    def test_baseline_holds_old_debt_only(self):
        self.run_check("--write-probe")
        kit = self.root / "Packages/macOS/Kit/Sources/Kit/B.swift"
        kit.write_text('let c = NSClassFromString("Old")!\n')
        self.run_check("--write-probe")
        self.assertEqual(self.run_check("--lookups").returncode, 1)
        self.assertEqual(self.run_check("--lookups", "--write").returncode, 0)
        self.assertEqual(self.run_check("--lookups").returncode, 0)
        kit.write_text('let c = NSClassFromString("Old")!\nlet d = NSClassFromString("Old")!\n')
        refused = self.run_check("--lookups")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("B.swift:2: NSClassFromString", refused.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
