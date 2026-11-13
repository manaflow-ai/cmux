import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "web-bundle-report.py"
SPEC = importlib.util.spec_from_file_location("web_bundle_report", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class WebBundleReportTests(unittest.TestCase):
    def write_bundle(self, root, name, modules):
        metafile = root / f"{name}.json"
        inputs = {}
        for path, source_bytes, emitted in modules:
            source = root / path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("export * from './child';\n" if "barrel" in path else "export const value = 1;\n", encoding="utf-8")
            inputs[str(source)] = {"bytes": source_bytes, "bytesInOutput": emitted}
        metafile.write_text(
            json.dumps(
                {
                    "inputs": {path: {"bytes": value["bytes"]} for path, value in inputs.items()},
                    "outputs": {
                        "entry.js": {
                            "bytes": sum(i["bytesInOutput"] for i in inputs.values()),
                            "inputs": {
                                path: {"bytesInOutput": value["bytesInOutput"]}
                                for path, value in inputs.items()
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        return metafile

    def test_reachability_and_shaken_barrel(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = self.write_bundle(root, "one", [("barrel.ts", 200_000, 1_000)])
            bundle = MODULE.load_bundle("one", metafile, root)
            self.assertEqual(bundle["modules"][0]["sourceBytes"], 200_000)
            self.assertEqual(bundle["modules"][0]["reachableBytes"], 1_000)
            self.assertEqual(bundle["barrels"][0]["barrel"], 1)

    def test_esbuild_top_level_input_bytes_are_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = self.write_bundle(root, "one", [("source.ts", 200_000, 1_000)])
            bundle = MODULE.load_bundle("one", metafile, root)
            self.assertEqual(bundle["modules"][0]["sourceBytes"], 200_000)
            self.assertEqual(bundle["modules"][0]["attributionMetric"], "emitted")
            self.assertEqual(bundle["modules"][0]["emittedBytes"], 1_000)

    def test_rolldown_rendered_lengths_are_separate_from_emitted_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = root / "rolldown.json"
            metafile.write_text(json.dumps({
                "schema": 2,
                "tool": "rolldown",
                "outputs": {"entry.js": {"bytes": 600, "inputs": {
                    "src/module.ts": {
                        "originalLength": 2_000,
                        "renderedLength": 1_000,
                        "metric": "rolldown-rendered-length",
                    }
                }}},
            }), encoding="utf-8")
            bundle = MODULE.load_bundle("rolldown", metafile, None)
            row = bundle["modules"][0]
            self.assertIsNone(bundle["shippedBytes"])
            self.assertEqual(bundle["attributionValue"], 1_000)
            self.assertIsNone(bundle["reachableBytes"])
            self.assertEqual(bundle["attributionMetric"], "rolldown-rendered-length")
            self.assertEqual(row["renderedLength"], 1_000)
            self.assertEqual(row["originalLength"], 2_000)
            self.assertEqual(row["emittedBytes"], 0)
            self.assertEqual(bundle["outputs"][0]["bytes"], 600)

    def test_rolldown_producer_keeps_lengths_out_of_byte_fields(self):
        plugin = SCRIPT.parents[2] / "webviews/scripts/bundle-metafile.mjs"
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "metafile.json"
            subprocess.run([
                "node", "--input-type=module", "-e",
                """const { bundleMetafile } = await import(process.argv[1]);
                await bundleMetafile(process.argv[2]).generateBundle({}, {
                  'entry.js': {type: 'chunk', code: '/*🌍*/', facadeModuleId: 'entry.js',
                    imports: [], dynamicImports: [],
                    modules: {'entry.js': {originalLength: 100, renderedLength: 60}}}
                });""",
                plugin.as_uri(), str(output),
            ], check=True, capture_output=True, text=True)
            meta = json.loads(output.read_text())
            chunk = meta["outputs"]["entry.js"]
            contribution = chunk["inputs"]["entry.js"]
            self.assertEqual(chunk["bytes"], len("/*🌍*/".encode()))
            self.assertEqual(contribution["renderedLength"], 60)
            self.assertNotIn("bytesInOutput", contribution)
            self.assertNotIn("sourceBytes", contribution)
            bundle = MODULE.load_bundle("rolldown", output, None)
            self.assertEqual(bundle["attributionValue"], 60)
            self.assertIsNone(bundle["reachableBytes"])

    def test_legacy_rolldown_bytes_are_unknown_not_emitted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = root / "legacy-rolldown.json"
            metafile.write_text(json.dumps({
                "schema": 1,
                "tool": "rolldown",
                "outputs": {"entry.js": {"bytes": 600, "inputs": {
                    "src/module.ts": {"bytes": 2_000, "bytesInOutput": 1_000}
                }}},
            }), encoding="utf-8")
            bundle = MODULE.load_bundle("legacy", metafile, None)
            row = bundle["modules"][0]
            self.assertIsNone(bundle["reachableBytes"])
            self.assertEqual(bundle["attributionMetric"], "unknown")
            self.assertEqual(row["unknownValue"], 1_000)
            self.assertEqual(row["emittedBytes"], 0)
            markdown = MODULE.render_markdown({"bundles": [bundle], "duplicates": {}, "findings": []})
            self.assertIn("| `src/module.ts` | unknown | unknown | unknown | unknown |", markdown)

    def test_unrecognized_metric_is_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = root / "future.json"
            metafile.write_text(json.dumps({"outputs": {"entry.js": {"bytes": 10, "inputs": {
                "module.js": {"bytesInOutput": 20, "metric": "future-metric"}
            }}}}))
            bundle = MODULE.load_bundle("future", metafile, None)
            self.assertEqual(bundle["attributionMetric"], "unknown")
            self.assertIsNone(bundle["attributionValue"])

    def test_captured_empty_source_is_not_replaced_with_current_file_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = self.write_bundle(root, "zero", [("source.js", 0, 0)])
            bundle = MODULE.load_bundle("zero", metafile, None)
            self.assertEqual(bundle["modules"][0]["sourceBytes"], 0)
            self.assertEqual(bundle["modules"][0]["sourceBytesKind"], "captured")

    def test_missing_rolldown_length_stays_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = root / "missing-length.json"
            metafile.write_text(json.dumps({
                "schema": 2, "tool": "rolldown",
                "outputs": {"entry.js": {"bytes": 600, "inputs": {
                    "src/module.ts": {"renderedLength": None, "metric": "rolldown-rendered-length"}
                }}},
            }), encoding="utf-8")
            bundle = MODULE.load_bundle("missing", metafile, None)
            self.assertIsNone(bundle["reachableBytes"])
            self.assertEqual(bundle["attributionMetric"], "unknown")

    def test_omitted_source_is_not_counted_as_shipped_savings(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = root / "graph.json"
            metafile.write_text(json.dumps({
                "inputs": {"used.js": {"bytes": 100}, "omitted.js": {"bytes": 500}},
                "outputs": {"entry.js": {"bytes": 40, "inputs": {"used.js": {"bytesInOutput": 40}}}},
            }))
            bundle = MODULE.load_bundle("graph", metafile, None)
            self.assertEqual(bundle["omittedInputs"], [{"path": "omitted.js", "sourceBytes": 500}])
            self.assertEqual(bundle["reachableBytes"], 40)
            self.assertIsNone(bundle["shippedBytes"])

    def test_relative_inputs_use_metafile_source_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_root = root / "checkout" / "webviews"
            source_root.mkdir(parents=True)
            source = source_root / "src/barrel.ts"
            source.parent.mkdir(parents=True)
            source.write_text("export * from './child';\n", encoding="utf-8")
            metafile = root / "reports/pages.json"
            metafile.parent.mkdir()
            metafile.write_text(
                json.dumps(
                    {
                        "inputs": {"src/barrel.ts": {"bytes": 200}},
                        "outputs": {
                            "entry.js": {
                                "bytes": 100,
                                "inputs": {"src/barrel.ts": {"bytesInOutput": 100}},
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            bundle = MODULE.load_bundle("pages", metafile, root, source_root)
            self.assertEqual(bundle["barrels"][0]["barrel"], 1)

    def test_duplicate_react_detector_reports_real_multiple_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pages = self.write_bundle(root, "pages", [("one/node_modules/react/index.js", 100, 80)])
            pane = self.write_bundle(root, "pane", [("two/node_modules/react/index.js", 100, 80)])
            output = root / "report.json"
            subprocess.run(
                [sys.executable, str(SCRIPT), "--metafile", f"pages={pages}",
                 "--metafile", f"pane={pane}", "--json", str(output)],
                check=True, capture_output=True, text=True,
            )
            report = json.loads(output.read_text())
            self.assertEqual(len(report["duplicates"]["react"]["instances"]), 2)
            self.assertTrue(any("duplicate react package across bundles" in finding for finding in report["findings"]))

    def test_installed_copies_use_canonical_paths_across_bundlers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_root = root / "checkout/webviews"
            source_root.mkdir(parents=True)
            module = "node_modules/prosemirror-model/dist/index.js"
            absolute = self.write_bundle(source_root, "absolute", [(module, 100, 80)])
            relative = root / "relative.json"
            relative.write_text(json.dumps({"outputs": {"entry.js": {"bytes": 80, "inputs": {module: {"bytesInOutput": 80}}}}}), encoding="utf-8")
            output = root / "report.json"
            subprocess.run(
                [sys.executable, str(SCRIPT), "--metafile", f"pages={relative}",
                 "--metafile", f"webviews={absolute}", "--source-root", f"pages={source_root}",
                 "--json", str(output)],
                check=True, capture_output=True, text=True,
            )
            package = json.loads(output.read_text())["duplicates"]["prosemirror-model"]
            self.assertEqual(package["bundles"], ["pages", "webviews"])
            self.assertEqual(len(package["instances"]), 1)
            self.assertEqual(package["instances"][0], str(source_root / "node_modules/prosemirror-model"))

    def test_nested_installed_copy_remains_distinct(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = self.write_bundle(root, "one", [
                ("node_modules/react/index.js", 100, 80),
                ("node_modules/widget/node_modules/react/index.js", 100, 80),
            ])
            bundle = MODULE.load_bundle("one", metafile, root)
            self.assertEqual(len({row["packageInstance"] for row in bundle["modules"]}), 2)

    def test_commonjs_and_dev_inputs_are_marked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cjs = root / "node_modules/pkg/index.cjs"
            dev = root / "src/gallery/example.test.ts"
            cjs.parent.mkdir(parents=True, exist_ok=True)
            dev.parent.mkdir(parents=True, exist_ok=True)
            cjs.write_text("// require('comment')\nconst text = 'require('; module.exports = {};", encoding="utf-8")
            dev.write_text("export const fixture = true;", encoding="utf-8")
            metafile = root / "bundle.json"
            metafile.write_text(json.dumps({"outputs": {"entry.js": {"bytes": 30, "inputs": {str(cjs): {"bytes": 20, "bytesInOutput": 20}, str(dev): {"bytes": 10, "bytesInOutput": 10}}}}}), encoding="utf-8")
            bundle = MODULE.load_bundle("bundle", metafile, root)
            self.assertEqual(len(bundle["commonjs"]), 1)
            self.assertEqual(len(bundle["devInputs"]), 1)

    def test_commonjs_metadata_format_is_marked_without_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = root / "bundle.json"
            metafile.write_text(
                json.dumps(
                    {
                        "inputs": {"generated.js": {"bytes": 100, "format": "cjs", "imports": []}},
                        "outputs": {"entry.js": {"bytes": 100, "inputs": {"generated.js": {"bytesInOutput": 100}}}},
                    }
                ),
                encoding="utf-8",
            )
            bundle = MODULE.load_bundle("bundle", metafile, root)
            self.assertEqual(len(bundle["commonjs"]), 1)

    def test_require_text_in_regex_or_grammar_is_not_commonjs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "grammar.mjs"
            source.write_text("export const pattern = /require(_once)?/;\nexport const grammar = 'module.exports';\n")
            metafile = root / "bundle.json"
            metafile.write_text(json.dumps({
                "inputs": {str(source): {"format": "esm", "bytes": source.stat().st_size}},
                "outputs": {"entry.js": {"bytes": 60, "inputs": {str(source): {"bytesInOutput": 60}}}},
            }))
            self.assertEqual(MODULE.load_bundle("bundle", metafile, None)["commonjs"], [])

    def test_development_names_include_camel_case_fixture_and_shipped_debug_page(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = self.write_bundle(root, "pages", [
                ("src/mockFixture.ts", 100, 80),
                ("src/summary/chatGallery.ts", 100, 80),
                ("src/pages/debug-settings/main.ts", 100, 80),
            ])
            bundle = MODULE.load_bundle("pages", metafile, None)
            self.assertEqual(len(bundle["devInputs"]), 3)

    def test_shaken_fixture_does_not_warn_that_it_shipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = self.write_bundle(root, "pages", [("src/mockFixture.ts", 100, 0)])
            bundle = MODULE.load_bundle("pages", metafile, None)
            self.assertEqual(bundle["devInputs"], [])
            markdown = MODULE.render_markdown({"bundles": [bundle], "duplicates": {}, "findings": []})
            self.assertNotIn("development-named (review usage)", markdown)

    def test_zero_byte_package_wrapper_does_not_count_as_another_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = self.write_bundle(root, "pages", [
                ("node_modules/react/index.js", 100, 80),
                ("node_modules/widget/node_modules/react/index.js", 100, 0),
            ])
            output = root / "report.json"
            subprocess.run([sys.executable, str(SCRIPT), "--metafile", f"pages={metafile}",
                            "--json", str(output)], check=True, capture_output=True, text=True)
            report = json.loads(output.read_text())
            self.assertEqual(len(report["duplicates"]["react"]["instances"]), 1)
            self.assertFalse(any("within pages" in finding for finding in report["findings"]))

    def test_barrel_graph_includes_exported_child_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            barrel = root / "barrel.ts"
            child = root / "child.ts"
            barrel.write_text("export * from './child';\n", encoding="utf-8")
            child.write_text("export const value = 'x'.repeat(100_000);\n", encoding="utf-8")
            metafile = root / "bundle.json"
            metafile.write_text(
                json.dumps(
                    {
                        "inputs": {
                            "barrel.ts": {"bytes": barrel.stat().st_size},
                            "child.ts": {"bytes": child.stat().st_size},
                        },
                        "outputs": {
                            "entry.js": {
                                "bytes": 100_000,
                                "inputs": {
                                    "barrel.ts": {"bytesInOutput": 0},
                                    "child.ts": {"bytesInOutput": 100_000},
                                },
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            bundle = MODULE.load_bundle("bundle", metafile, root)
            self.assertEqual(bundle["barrels"][0]["barrel"], 1)
            self.assertEqual(bundle["barrels"][0]["barrelReachableBytes"], 100_000)

    def test_barrel_comments_do_not_count_as_exports(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.ts"
            source.write_text("// export * from './missing';\nconst text = \"export * from './missing'\";\n", encoding="utf-8")
            metafile = root / "bundle.json"
            metafile.write_text(json.dumps({"outputs": {"entry.js": {"bytes": 10, "inputs": {"source.ts": {"bytesInOutput": 10}}}}}), encoding="utf-8")
            bundle = MODULE.load_bundle("bundle", metafile, root)
            self.assertEqual(bundle["barrels"], [])


if __name__ == "__main__":
    unittest.main()
