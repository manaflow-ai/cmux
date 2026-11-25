"""schemas/settings/settings-schema.json without Swift: SettingsSchemaExport.json(catalog:) in Python.

Reads the hand-edited sources in schemas/settings (the ones gen-settings-sources.py turns into the
Swift descriptors), the String Catalog the app compiles, and the few generated Swift tables the
descriptors name (swift_data.py), and writes the bytes SettingsSchemaExportTests writes.

One difference by design: Swift keeps each conformance sample `SettingDescriptor.accepts` agrees
with; SettingsSchemaExportTests.everyRowHasConformanceSamples fails unless it agrees with every
one, so with that test green the filter keeps them all, and so does this. `check_samples` runs the
portable part of the validator here so a sample that would break that test fails this export too.
"""
from __future__ import annotations

import json
import os

import djson
import swift_data

SETTINGS = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
CATALOG = SETTINGS + "/Localizable.xcstrings"
DESIGN_CATALOG = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/Localizable.xcstrings"
SRC = "schemas/settings/source"
GEN = "schemas/settings/generator"


def load(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as handle:
        return json.load(handle)


def load_policy(root):
    """The agent policy as {"groups": [{agent, keys}]}: schemas/settings/source/agent-policy/ holds one
    <key>.json ({agent, why?}) per key plus _refusals.json (gen-settings-sources.py checks its shape)."""
    rel = SRC + "/agent-policy"
    groups = {}
    for name in sorted(os.listdir(os.path.join(root, rel))):
        if name == "_refusals.json" or not name.endswith(".json"):
            continue
        agent = load(root, rel + "/" + name)["agent"]
        groups.setdefault(agent, []).append(name[: -len(".json")])
    return {"groups": [{"agent": agent, "keys": keys} for agent, keys in groups.items()]}


class MissingKeys(Exception):
    pass


class Schema:
    def __init__(self, root):
        self.root = root
        self.catalog = swift_data.Catalog(root, CATALOG)
        self.sections = load(root, SRC + "/sections.json")["sections"]
        self.layout = load(root, SRC + "/page-layout.json")
        self.policy = load_policy(root)
        self.facts = load(root, SRC + "/row-facts.json")
        self.samples = load(root, SRC + "/samples.json")
        self.missing = set()
        self.descriptors = self._descriptors()

    # Text -------------------------------------------------------------------------------------

    def resolve(self, text):
        """A source text ({key, text}) as SettingsText.keyed resolves it: (key, English text)."""
        if text is None:
            return None
        if text["key"] is None:
            return (None, text["text"])
        return (text["key"], self.catalog.text(text["key"], text["text"]))

    def text(self, pair):
        key, value = pair
        if key is not None and key not in self.catalog.strings:
            self.missing.add(key)
        return {"text": value, "key": key}

    def section_title(self, section_id):
        entry = next(s for s in self.sections if s["id"] == section_id)
        return self.resolve(entry["title"])

    # Descriptors ------------------------------------------------------------------------------

    def _lists(self):
        """(Type, var) -> [(list entry, rows)] for every generated var, joined vars included."""
        out = {}
        for name in sorted(os.listdir(os.path.join(self.root, GEN))):
            if not name.endswith(".json"):
                continue
            gen = load(self.root, GEN + "/" + name)
            data = load(self.root, gen["source"])
            entries = []
            for entry in data["lists"]:
                var, owner = gen["lists"][entry["name"]]
                out[(gen["type"], var)] = [entry]
                if owner:
                    out[(owner, var)] = [entry]
                entries.append(entry)
            if gen.get("joined"):
                out[(gen["type"], gen["joined"])] = entries
        return out

    def _descriptors(self):
        lists = self._lists()
        lists[("WorkspaceRowSetting", "descriptors")] = [
            entry for ref in swift_data.workspace_row_descriptors(self.root) for entry in lists[ref]]
        before, after = swift_data.schema_all_order(self.root)
        shared = set(self.facts["shared_with_browser"])
        out = []
        for refs, share in ((before, True), (after, False)):
            for ref in refs:
                if ref not in lists:
                    raise swift_data.SwiftShapeChanged("SettingsSchema.all names %s.%s, which no source defines" % ref)
                for entry in lists[ref]:
                    for row in entry["rows"]:
                        descriptor = self.descriptor(entry, row)
                        if share and descriptor["id"] in shared:
                            descriptor["consumers"] = ["cmux-browser", "cmux-next"]
                        out.append(descriptor)
        return out

    def choices_from(self, member):
        # BackdropArt.label ("Title — Artist"): artChoices and BackdropSelection.art's title.
        design = swift_data.Catalog(self.root, DESIGN_CATALOG)
        fmt = design.text("backdrop.label", "%1$@ — %2$@")

        def label(art):
            return (None, fmt.replace("%1$@", design.text(art["title_key"], art["title"])).replace("%2$@", art["artist"]))
        if member == "BackdropArtSetting.artChoices":
            return [{"value": art["id"], "title": label(art)} for art in swift_data.backdrop_art(self.root)]
        if member == "BackdropSelectionSetting.catalogChoices":
            works = swift_data.backdrop_art(self.root)
            out = []
            for collection in swift_data.backdrop_collections(self.root):
                for art in works:
                    if art["collection"] == collection:
                        out.append({"value": art["id"], "title": label(art)})
            out.append({"value": "desktop", "title": self.resolve({"key": "settings.choice.desktopWallpaper",
                                                                   "text": "Desktop Wallpaper"})})
            return out
        if member == "ChromeStyleSetting.choices":
            return [{"value": value, "title": self.resolve({"key": key, "text": text})}
                    for value, key, text in swift_data.chrome_styles(self.root)]
        raise swift_data.SwiftShapeChanged("choices_from %s has no Linux reader" % member)

    def descriptor(self, entry, row):
        choices = None
        if "choices" in row or row.get("choices_from"):
            choices = [{"value": c["value"], "title": self.resolve(c["title"])} for c in row.get("choices", [])]
            if row.get("choices_from"):
                choices += self.choices_from(row["choices_from"])
        page_hidden = row.get("page_hidden")
        palette = None  # exposed
        if page_hidden and not row.get("palette_shown"):
            palette = page_hidden
        if row.get("palette_hidden"):
            palette = row["palette_hidden"]
        return {
            "id": row["key"],
            "row": row,
            "section": entry["section"],
            "group": self.resolve(entry["group"]),
            "title": self.resolve(row["title"]),
            "help": self.resolve(row.get("help")),
            "summary": self.resolve(row.get("summary")),
            "default_label": self.resolve(row.get("default_label")),
            "placeholder": self.resolve(row.get("placeholder")),
            "choices": choices,
            "consumers": sorted(row.get("consumers") or ["cmux-next"]),
            "page_shown": not page_hidden,
            "palette_hidden": palette,
        }

    # Export -----------------------------------------------------------------------------------

    def agent_tables(self):
        settable, refused = set(), {}
        for group in self.policy["groups"]:
            for key in group["keys"]:
                if group["agent"] == "settable":
                    settable.add(key)
                else:
                    refused[key] = group["agent"]
        return settable, refused

    def json(self, strict=True):
        return djson.dumps(self.document(strict), pretty=True) + "\n"

    def document(self, strict=True):
        """The export as a dict (rows carry what the MDM manifest reads too)."""
        self.missing = set()
        sections = [{"id": s["id"], "title": self.text(self.resolve(s["title"])), "symbol": s["symbol"]}
                    for s in self.sections]
        settable, refused = self.agent_tables()
        rows = [self.export_row(d, settable, refused) for d in self.descriptors]
        document = {"version": 1, "sections": sections, "page": self.page(), "rows": rows}
        if self.missing and strict:
            raise MissingKeys("keys not in Localizable.xcstrings: " + ", ".join(sorted(self.missing)))
        return document

    def export_row(self, d, settable, refused):
        row = d["row"]
        key = d["id"]
        agent = True if key in settable else (False if key in refused else None)
        shown_in_next = "cmux-next" in d["consumers"]
        out = {
            "key": key,
            "path": key.split("."),
            "section": d["section"],
            "group": self.text(d["group"]),
            "title": self.text(d["title"]),
            "help": self.text(d["help"]) if d["help"] else None,
            "summary": self.text(d["summary"]) if d["summary"] else None,
            "default": row["default"],
            "default_label": self.text(d["default_label"]) if d["default_label"] else None,
            "placeholder": self.text(d["placeholder"]) if d["placeholder"] else None,
            "keywords": row.get("keywords", []),
            "agent_settable": agent or False,
            "agent_refusal": refused.get(key),
            "kept_on_reset_all": key in self.facts["kept_on_reset_all"],
            "consumers": d["consumers"],
            "page_hidden": not (d["page_shown"]),
            "surfaces": self.surfaces(d, agent is True, shown_in_next),
        }
        kind = row["kind"]

        def choices():
            return [{"value": c["value"], "title": self.text(c["title"])} for c in d["choices"]]
        if kind in ("choice", "choice_or_number", "choice_or_url"):
            out["choices"] = choices()
        if kind in ("number", "choice_or_number", "number_list"):
            rng = row["range"]
            out["range"] = {"min": float(rng["min"]), "max": float(rng["max"]), "step": float(rng["step"]),
                            "unit": rng["unit"], "placeholder": float(rng.get("placeholder", rng["min"]))}
        if kind == "choice_or_url":
            out["url_key"] = row["url_key"]
        if kind == "ordered_choices":
            kind = "string_list"
            out["choices"] = choices()
            out["ordered"] = True
        elif kind == "choice_set":
            kind = "string_list"
            out["choices"] = choices()
            out["ordered"] = False
        elif kind == "json":
            out["shape"] = row["shape"]
        out["kind"] = kind
        validation = self.facts["validation"]
        out["validation"] = validation["keys"].get(key) or validation["kinds"].get(kind) or validation["default"]
        if out["validation"] == "domain:app_id":
            out["pattern"] = self.facts["app_id_pattern"]
        accept, refuse = self.sample_values(out)
        out["accepts"] = accept
        out["refuses"] = refuse
        return out

    def surfaces(self, d, agent_settable, shown_in_next):
        def surface(operations, aliases=(), app_operations=(), app_aliases=(), row=None, editor=None, offered=None, reason=None):
            return {"offered": bool(operations) if offered is None else offered, "operations": list(operations),
                    "aliases": list(aliases), "app_operations": list(app_operations), "app_aliases": list(app_aliases),
                    "row": row, "editor": editor, "reason": reason}
        if d["palette_hidden"] is not None:
            palette = surface([], reason=d["palette_hidden"])
        elif shown_in_next:
            row = "setting:" + d["id"]
            if d["row"]["kind"] == "toggle":
                palette = surface(["palette.toggleSetting"], row=row, editor="toggle")
            else:
                palette = surface([], row=row, editor="options", offered=True)
        else:
            palette = surface([], reason="not_consumed_by_cmux_next")
        cli_ops = ["settings.list", "settings.get", "settings.set", "settings.reset"]
        reset_aliases = ["settings.unset"]
        return {
            "palette": palette,
            "cli": surface(cli_ops, reset_aliases),
            "mcp": surface(["settings.list", "settings.get"] + (["settings.set", "settings.reset"] if agent_settable else []),
                           reset_aliases if agent_settable else [], reason=None if agent_settable else "agent_settable_false"),
            "socket": surface(cli_ops, app_operations=["settings.get", "settings.set", "settings.reset"], app_aliases=reset_aliases),
        }

    def sample_values(self, row):
        kind = row["kind"]
        name = "choice_list" if kind == "string_list" and "choices" in row else kind
        sets = self.samples["domains"].get(row["validation"]) or self.samples["kinds"].get(name)
        if sets is None:
            return [], []
        choices = [c["value"] for c in row.get("choices", [])]
        rng = row.get("range") or {}
        low, high = float(rng.get("min", 0)), float(rng.get("max", 0))
        span = max(high - low, 1.0)
        url_key = row.get("url_key", "")

        def values(token):
            return {
                "choices": list(choices),
                "choices_reversed": list(reversed(choices)),
                "first_choice": [choices[0] if choices else "a"],
                "min": [low], "max": [high], "mid": [low + (high - low) / 2],
                "below": [low - span], "above": [high + span],
                "url_key": [url_key],
            }.get(token, [])

        def fill(value):
            if isinstance(value, dict):
                if len(value) == 1 and isinstance(value.get("$sample"), str):
                    return values(value["$sample"])
                return [{(url_key if k == "$url_key" else k): (fill(v) or [None])[0] for k, v in value.items()}]
            if isinstance(value, list):
                return [[x for item in value for x in fill(item)]]
            return [value]
        return ([x for v in sets["accept"] for x in fill(v)], [x for v in sets["refuse"] for x in fill(v)])

    def page(self):
        shown = [d for d in self.descriptors if "cmux-next" in d["consumers"] and d["page_shown"]]
        ids = set(d["id"] for d in shown)
        specs = [c for run in self.layout["sidebar_sections"] for c in run["categories"]]
        claimed = set(k for spec in specs for g in spec["groups"] for k in g.get("lead_keys", []) + g.get("keys", []))
        categories = []
        for spec in specs:
            groups = []
            for index, group in enumerate(spec["groups"]):
                key = group.get("group")
                own = [d["id"] for d in shown if key is not None and d["group"][0] == key and d["id"] not in claimed]
                rows = [k for k in group.get("lead_keys", []) if k in ids] + own + [k for k in group.get("keys", []) if k in ids]
                title = self.resolve(group["title"]) if group.get("title") else None
                if title is None and key is not None:
                    first = next((d for d in shown if d["group"][0] == key), None)
                    title = (key, first["group"][1]) if first else None
                if not rows or title is None:
                    continue
                groups.append({"key": key if key is not None else "%s.%d" % (spec["id"], index),
                               "title": self.text(title), "rows": rows})
            title = spec["title"]
            title = self.section_title(title["section"]) if set(title) == {"section"} else self.resolve(title)
            entry = {
                "id": spec["id"], "title": self.text(title), "symbol": spec["symbol"], "groups": groups,
                "lead": spec.get("lead", []), "trail": spec.get("trail", []), "actions": spec.get("actions", []),
                "aliases": spec.get("aliases", []) + spec.get("legacy_ids", []),
            }
            if spec.get("dev_only"):
                entry["dev_only"] = True
            categories.append(entry)
        sidebar = []
        for run in self.layout["sidebar_sections"]:
            entry = {"id": run["id"], "title": self.text(self.resolve(run["title"])) if run["title"] else None,
                     "categories": [c["id"] for c in run["categories"]]}
            if run.get("collapsed"):
                entry["collapsed"] = True
            sidebar.append(entry)
        return {"default_category": self.layout["default_category"], "categories": categories, "sidebar_sections": sidebar}
