#!/usr/bin/env python3
"""The CmuxNextApp type graph and the move queue that empties the App (p11-codebase task 000a).

CmuxNextApp is one Swift module: its files reference each other's types freely, so a directory cannot leave the
App until every reference out of it either points at a package its destination may depend on or goes through
the destination's Host protocol. This script finds those references and plans the moves:

  1. Facts. Every top-level App type, every member declared in a type body or an extension (so a member that
     `Cloud/AppServices+Cloud.swift` adds to AppServices belongs to Cloud, not to the hub), every reference
     from one App file to a type or member defined in another, and every file's imports. Read from the index
     store of one fleet Debug build (`--index-store`, exact: Swift's own resolution through libIndexStore) or,
     for dry runs, from a regex scan of the sources (`strip`/`Braces` of arch_counts.py; typed variables and
     member chains such as `services.cloud.start` are followed one property at a time). A module an App file
     re-exports (`@_exported import CmuxNextDaemonService`) is visible in every App file without an import, so a
     file that names one of its public types (regex) or one of its symbols (index store: the USR's module) counts
     as importing it: the module stays visible after the move only as a declared dependency.
  2. Groups. Files group by first-level directory; Handlers and Control by domain prefix, Pages by
     subdirectory, top-level files by name family (`PaneController+Drag.swift` is family PaneController).
     When a group's destination is below ui and names a `ui` destination, its view files (SwiftUI, WebKit or
     a ui-layer import, or an NSView/NSWindow subclass) form a second group `<group>:ui` that goes there
     (Chrome's components/foo/core next to components/foo/browser, components/README.md). A feature directory's
     `AppServices+X.swift` / `AppActionContext+X.swift` is its Host conformance and stays as `Hosts/<group>`.
  3. Destinations. DESTINATIONS below: an existing target first, a target the spec creates (task 007) only
     where none fits, CmuxNextApp for the composition root (it stays). The same map is written into
     architecture-refactor-DESIGN.md section 4 by `--write`.
  4. Cuts. A reference into the composition root, or up the layer order or the TIERS (features never name
     Workbench or WorkbenchUI concretes, and only the App names AppControl), can only go through the
     Host protocol or WorkbenchInterface (Chrome's BrowserWindowInterface,
     chrome/browser/ui/browser_window/public/browser_window_interface.h, and the FooDelegate an embedder
     implements, content/public/browser/web_contents_delegate.h): it is a Host member of the group. A reference
     from ungated work into an owner-gated group (Phase W) is cut the same way, so no ungated unit waits for an
     owner. The remaining references between destinations become package edges, heaviest first, and an edge that
     would close a cycle in the package graph (existing Package.swift edges and imports included) is cut
     instead: also a Host member. This is the greedy acyclic subgraph; cycles between groups of one destination
     need no cut (one module). The allowed edges are Chrome's DEPS model (buildtools/checkdeps/checkdeps.py).
  5. Order. After the cuts every strongly connected component lies inside one destination; each is one move
     unit (one seam commit plus one move commit, the Q1 queue), sorted leaf-first: a unit moves after every
     unit it depends on, lower layers and ungated work first. Each unit is one Q1 task: the task-table row that
     holds most of its lines, lettered when that row spans several units.

Output (plans/cmux-next/app-graph.json): per group its destination, layer, host_members (`Type.member`, or
`Type` where the reference names no member), deps (the destinations and modules its code needs), cuts (each
cut edge with its reason and members), scc_id (its component in the uncut graph, root edges aside), order (its
move unit's index), plus `order` (the units, each with its Q1 task id and the owner gates it waits on), `tasks`
(each Q1 task id -> its one unit), `families` (each task-table row -> its units), `new_targets` (what task 007
creates), `provisional` (true for a regex plan), `cycles` (each
component of more than one group and the cuts that open it) and `destinations` (each target's final dependency list, the deps it adds, and any import that
breaks the layer order or would close a package cycle).

Usage:
  scripts/cmux-next/app-graph.py                       summary of the regex scan
  scripts/cmux-next/app-graph.py --queue               the Q1 move queue, one unit per line (TSV)
  scripts/cmux-next/app-graph.py --json                the JSON on stdout
  scripts/cmux-next/app-graph.py --write               write app-graph.json and the DESIGN section 4 table
  scripts/cmux-next/app-graph.py --index-store PATH    read the facts from a Debug build's index store
                                                       (fleet: .build/debug/index/store or DerivedData's
                                                       Index.noindex/DataStore); --libindexstore names the
                                                       library when the toolchain one is not found
Test: python3 -m pytest scripts/cmux-next/tests/test_app_graph.py
"""

from __future__ import annotations

import argparse
import bisect
import collections
import ctypes
import dataclasses
import heapq
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = "CmuxNextApp"
APP_DIR = f"Packages/macOS/CmuxNext/Sources/{APP}"
MANIFEST = "Packages/macOS/CmuxNext/Package.swift"
LAYERS = "plans/cmux-next/architecture-layers.json"
OUT = "plans/cmux-next/app-graph.json"
DESIGN = "plans/cmux-next/architecture-refactor-DESIGN.md"
TABLE_BEGIN = "<!-- app-graph:begin (generated by scripts/cmux-next/app-graph.py --write; do not edit) -->"
TABLE_END = "<!-- app-graph:end -->"


def _load_counts():
    """scripts/cmux-next/arch_counts.py: Swift blanking, brace structure, the manifest reader, the layer map."""
    spec = importlib.util.spec_from_file_location("cmux_next_arch_counts", Path(__file__).resolve().parent / "arch_counts.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


counts = _load_counts()

# ---------------------------------------------------------------------------------------------------
# The destination map (reconciled with p11-codebase.md section 3A and the task table)

# Targets task 007 creates, with their layer (p11-codebase.md section 3A). Only those that receive App code
# appear in DESTINATIONS; the rest are listed so a destination's layer is known before 007 lands.
SPEC_TARGETS = {
    "CmuxNextSignals": "core", "CmuxNextSettingsSchema": "core", "CmuxNextPagesCore": "core",
    "CmuxNextIconsCore": "core", "CmuxNextDaemonWire": "core", "CmuxNextActionsCatalog": "core",
    "CmuxNextChromiumWire": "core",
    "CmuxNextAppearance": "domain", "CmuxNextEnvironment": "domain", "CmuxNextWorkbenchInterface": "domain",
    "CmuxNextAgentPaneModel": "domain", "CmuxNextLayoutModel": "domain", "CmuxNextTabsModel": "domain",
    "CmuxNextSidebarModel": "domain", "CmuxNextHistoryModel": "domain", "CmuxNextHomeModel": "domain",
    "CmuxNextAgentActivityModel": "domain", "CmuxNextQuit": "domain", "CmuxNextWorkbench": "domain",
    "CmuxNextSettingsStore": "service",
    "CmuxNextWorkbenchUI": "ui", "CmuxNextAgentTabs": "ui", "CmuxNextBrowserFeatures": "ui",
    "CmuxNextCloudFeatures": "ui", "CmuxNextRemoteMachines": "ui", "CmuxNextNotifications": "ui",
    "CmuxNextAppControl": "ui", "CmuxNextPresenters": "ui",
}
# Added by this map: section 3A has no target above these kits, and each kit sits below code the glue imports.
# app-graph.json `new_targets` lists them with the 3A targets (what task 007 creates); DESIGN section 4 names them.
ADDED_TARGETS = {
    "CmuxNextHomeFeatures": "HomeEngine and HostedChief depend on CmuxNextHome, and the Home glue imports both",
    "CmuxNextSidebarFeatures": "Bridge depends on CmuxNextSidebar, and the Sidebar glue imports Bridge",
    "CmuxNextPaletteSources": "the palette sources read AgentTabs, SidebarFeatures, BrowserFeatures and other "
                              "features, and those features depend on the CmuxNextPalette kit",
}
NEW_TARGETS = {**SPEC_TARGETS, **{t: "ui" for t in ADDED_TARGETS}}
CUT_REASONS = ("app", "upward", "gated", "cycle")


@dataclasses.dataclass(frozen=True)
class Dest:
    target: str
    task: str | None = None  # the p11 task that moves the group (100-182), when the task table names it
    ui: str | None = None  # where the group's view files go when TARGET is below ui
    gated: str | None = None  # owner whose release the move waits for (Phase W, task 000h)
    app_dir: str | None = None  # for groups that stay: Composition, Hosts, Launch or Menus


W_SWITCH = "PL-switch"
W_TYPING = "PL-typing"
W_CEF = "PL-cef-tab"
W_MOTION = "PL-motion-core"
WB = "CmuxNextWorkbench"
WBUI = "CmuxNextWorkbenchUI"

# Group key -> destination. Keys: first-level directory, `Handlers/<domain>`, `Control/<domain>`,
# `Pages/<subdir or family>`, `top:<family>` for top-level files.
DESTINATIONS: dict[str, Dest] = {
    # 100: Palette family (the kit CmuxNextPalette keeps what imports no feature; sources go above the features)
    "PaletteScopes": Dest("CmuxNextPalette", "100"), "PaletteUsage": Dest("CmuxNextPalette", "100"),
    "GlobalSearch": Dest("CmuxNextPalette", "100"),
    "PaletteNavigation": Dest("CmuxNextPaletteSources", "100"), "TabSearch": Dest("CmuxNextPaletteSources", "100"),
    "FindInDirectory": Dest("CmuxNextPaletteSources", "100"), "LayoutTemplates": Dest("CmuxNextPaletteSources", "100"),
    "top:Palette": Dest("CmuxNextPaletteSources", "100"),
    "top:SettingsPaletteSource": Dest("CmuxNextPaletteSources", "100"),
    # 101: diagnostics (service targets; their windows and prompts are workbench UI, not the Presenters kit)
    "ErrorJournal": Dest("CmuxNextErrorJournal", "101", ui=WBUI),
    "Crash": Dest("CmuxNextCrashReporting", "101", ui=WBUI),
    "HangReports": Dest("CmuxNextHangReports", "101", ui=WBUI),
    # 102
    "IconAssets": Dest(WBUI, "102"), "IconPicker": Dest(WBUI, "102"),  # import Sidebar, Tabs, Bookmarks: above Icons
    "Favicons": Dest("CmuxNextFavicons", "102"),
    # 103
    "SleepyMode": Dest("CmuxNextFloating", "103"), "QuickComposer": Dest("CmuxNextFloating", "103"),
    # 104-106: browser
    "BrowserHits": Dest("CmuxNextBrowserFeatures", "104"), "Hints": Dest("CmuxNextBrowserFeatures", "104"),
    "LinkHints": Dest("CmuxNextBrowserFeatures", "104"), "WebInspection": Dest("CmuxNextBrowserFeatures", "104"),
    "DesignMode": Dest("CmuxNextBrowserFeatures", "104"), "Popups": Dest("CmuxNextPopups", "104"),
    "Links": Dest("CmuxNextBrowserFeatures", "104"),
    "BrowserProfiles": Dest("CmuxNextBrowserFeatures", "105"), "Passwords": Dest("CmuxNextBrowserFeatures", "105"),
    "Billing": Dest("CmuxNextBrowserFeatures", "105"),
    "BrowserHost": Dest("CmuxNextBrowserFeatures", "106"), "RemoteLocalhost": Dest("CmuxNextBrowserFeatures", "106"),
    # 107-108: cloud (CmuxNextCloud is a service: views cannot go there)
    "Cloud": Dest("CmuxNextCloudFeatures", "107"), "ChiefMove": Dest("CmuxNextCloudFeatures", "109"),
    "Accounts": Dest("CmuxNextAccounts", "108"), "Usage": Dest("CmuxNextAppControl", "108"),
    "top:CloudCreationRows": Dest("CmuxNextCloudFeatures", "107"),
    # 109-111: remote machines
    "Remote": Dest("CmuxNextRemoteMachines", "109"), "Pairing": Dest("CmuxNextRemoteMachines", "109"),
    "SessionTransfer": Dest("CmuxNextRemoteMachines", "109"),
    "Server": Dest("CmuxNextServer", "110"), "ServerUpdates": Dest("CmuxNextServer", "110"),
    # RemoteBrowser and RemoteViewSessions depend on RemoteView, and the glue imports both
    "RemoteView": Dest("CmuxNextRemoteMachines", "111"), "MacScreen": Dest("CmuxNextMacScreen", "111"),
    # 112-113: home (HostedChief -> HomeEngine -> Home, and the glue imports all three)
    "Home": Dest("CmuxNextHomeFeatures", "112"), "TopPages": Dest("CmuxNextHomeFeatures", "113"),
    "Chief": Dest("CmuxNextHomeFeatures", "113"), "Phone": Dest("CmuxNextPhone", "113"),
    "ChatQuotes": Dest("CmuxNextHomeFeatures", "113"),
    # 114-118
    "Feed": Dest("CmuxNextFeed", "114"), "Notifications": Dest("CmuxNextNotifications", "115"),
    # Stash -> History, and History's glue imports Bookmarks and Browser: browser features
    "History": Dest("CmuxNextBrowserFeatures", "116"), "Vault": Dest("CmuxNextBrowserFeatures", "116"),
    "Stash": Dest("CmuxNextBrowserFeatures", "116"),
    "Bookmarks": Dest("CmuxNextBrowserFeatures", "117"),
    "Onboarding": Dest("CmuxNextOnboarding", "118"),
    "BrowserImportOffer": Dest("CmuxNextBrowserFeatures", "118"),  # imports ImportCards (ImportCards -> Onboarding)
    "Permissions": Dest("CmuxNextAppPermissions", "118"),
    "ComputerUse": Dest("CmuxNextOnboarding", "118"),
    # 119-121
    "Settings": Dest("CmuxNextSettingsWindow", "119"), "Density": Dest("CmuxNextSettingsWindow", "119"),
    "Themes": Dest("CmuxNextAppearance", "119", ui="CmuxNextSettingsWindow"),
    "top:ThemeBridge": Dest("CmuxNextAppearance", "119", ui="CmuxNextSettingsWindow"),
    "Quit": Dest("CmuxNextQuit", "120", ui=WBUI),
    "FileExplorer": Dest("CmuxNextFilesUI", "121"), "FilesPane": Dest("CmuxNextFilesUI", "121"),
    "Screenshots": Dest("CmuxNextScreenshots", "121"), "Viewers": Dest("CmuxNextFilesUI", "121"),
    # 122-126
    "AgentActivity": Dest("CmuxNextAgentActivity", "122"), "AgentHarnesses": Dest("CmuxNextAgentTabs", "122"),
    "AgentRecents": Dest("CmuxNextAgentTabs", "122"), "Projects": Dest("CmuxNextAgentTabs", "122"),
    "AgentCursor": Dest("CmuxNextAgentCursor", "122", ui="CmuxNextAgentTabs"),
    "Apps": Dest("CmuxNextApps", "123"), "TaskManager": Dest("CmuxNextResources", "123"),
    "Tasks": Dest("CmuxNextTasks", "123"), "Checklist": Dest("CmuxNextTasks", "123"),
    # Bridge -> Sidebar, and the glue imports Bridge, AgentPane, Apps, Bookmarks
    "SidebarSections": Dest("CmuxNextSidebarFeatures", "124", gated="a590"),
    "SidebarSnapshot": Dest("CmuxNextSidebarFeatures", "124", gated="a590"),
    "Pins": Dest("CmuxNextSidebarFeatures", "124", gated="a590"),
    "Groups": Dest("CmuxNextSidebarFeatures", "124", gated="a590"),
    "HostPressure": Dest(WBUI, "125"),  # reads Settings: cannot go into the HostPressure service
    "ClipboardReads": Dest("CmuxNextTerminal", "125"),
    "GlobalHotKeys": Dest("CmuxNextFocusUI", "125"), "Share": Dest(WBUI, "125"),
    "Hibernation": Dest("CmuxNextHibernation", "126", ui=WBUI),
    "DeepLinks": Dest(WB, "126", ui=WBUI),
    # 127-128: page providers move with their domain; PageFactory and the provider list wire every domain's
    # provider, so they are composition (the page host itself is already CmuxNextPages)
    "Pages/Core": Dest(APP, "127", app_dir="Composition"), "Pages/Chromium": Dest("CmuxNextBrowserFeatures", "127"),
    "Pages/Diff": Dest("CmuxNextFilesUI", "127"), "Pages/FileTree": Dest("CmuxNextFilesUI", "127"),
    "Pages/Files": Dest("CmuxNextFilesUI", "127"), "Pages/MobilePairing": Dest("CmuxNextPhone", "128"),
    "Pages/Chief": Dest("CmuxNextChiefViews", "128"), "Pages/Settings": Dest("CmuxNextSettingsWindow", "128"),
    "Pages/Home": Dest("CmuxNextHomeFeatures", "128"), "Pages/Server": Dest("CmuxNextServer", "128"),
    "InternalPages": Dest(WBUI, "128"),  # imports SettingsWindow, Tabs, Bridge: above Pages
    # 130-133: Control (debug and control socket): one diagnostics target above the domains
    "Control/Core": Dest("CmuxNextAppControl", "133"), "Control/Sidebar": Dest("CmuxNextAppControl", "130"),
    "Control/Browser": Dest("CmuxNextAppControl", "130"),
    "Control/Window": Dest("CmuxNextAppControl", "131", gated=W_MOTION),
    "Control/Agent": Dest("CmuxNextAppControl", "132"),
    "top:Debug": Dest("CmuxNextAppControl", "133"), "top:ShowcaseState": Dest("CmuxNextAppControl", "133"),
    "top:UIInspectorController": Dest("CmuxNextAppControl", "133"),
    # 141-154: handlers move with their domain against `<Domain>ActionHost`
    "Handlers/Cloud": Dest("CmuxNextCloudFeatures", "141"), "Handlers/Agent": Dest("CmuxNextAgentTabs", "142"),
    "Handlers/Browser": Dest("CmuxNextBrowserFeatures", "143"),
    "Handlers/Tab": Dest(WB, "145", ui=WBUI, gated=W_SWITCH),
    "Handlers/Pane": Dest(WB, "146", ui=WBUI, gated=W_SWITCH),
    "Handlers/Workspace": Dest(WB, "147", ui=WBUI),
    "Handlers/Settings": Dest("CmuxNextSettingsWindow", "148"),
    "Handlers/Remote": Dest("CmuxNextRemoteMachines", "149"), "Handlers/History": Dest("CmuxNextBrowserFeatures", "150"),
    "Handlers/Chief": Dest("CmuxNextHomeFeatures", "151"), "Handlers/Files": Dest("CmuxNextFilesUI", "152"),
    "Handlers/Terminal": Dest("CmuxNextTerminal", "153"), "Handlers/Misc": Dest(WB, "154", ui=WBUI),
    "Handlers/Infra": Dest(APP, "140", app_dir="Composition"),
    # 160-165: top-level families
    "top:AgentTabs": Dest("CmuxNextAgentTabs", "160"), "top:AgentChat": Dest("CmuxNextAgentTabs", "160"),
    "top:AgentPane": Dest("CmuxNextAgentTabs", "161"), "top:Agent": Dest("CmuxNextAgentTabs", "161"),
    "top:ChatSettingsPush": Dest("CmuxNextAgentTabs", "161"),
    "top:Browser": Dest("CmuxNextBrowserFeatures", "162"), "top:Chromium": Dest("CmuxNextBrowserFeatures", "162"),
    "top:Chrome": Dest("CmuxNextBrowserFeatures", "162"), "top:ExtensionMenuRouter": Dest("CmuxNextBrowserFeatures", "162"),
    "top:StaticURL": Dest("CmuxNextBrowserFeatures", "162"), "top:WorkingURL": Dest("CmuxNextBrowserFeatures", "162"),
    "top:OutboundTab": Dest("CmuxNextBrowserFeatures", "162"),
    "top:Sidebar": Dest("CmuxNextSidebarFeatures", "163", gated="a590"),
    "top:PersonalGroup": Dest("CmuxNextSidebarFeatures", "163", gated="a590"),
    "top:Terminal": Dest("CmuxNextTerminal", "164", gated="PL-ghostty"),
    "top:DaemonTerminalIO": Dest("CmuxNextTerminal", "164", gated="PL-ghostty"),
    "top:GhosttyConfigLiveReload": Dest("CmuxNextTerminal", "164", gated="PL-ghostty"),
    "top:AppActions": Dest(WB, "165", ui=WBUI), "top:ActionRouting": Dest(WB, "165", ui=WBUI),
    "top:ActionScope": Dest(WB, "165", ui=WBUI), "top:Config": Dest(WB, "165", ui=WBUI),
    "top:WorkContextTrail": Dest(WB, "165", ui=WBUI),
    "top:FeaturePolicyEnforcer": Dest(WB, "165", ui=WBUI), "top:ManagedPolicyBridge": Dest(WB, "165", ui=WBUI),
    "top:UpdaterService": Dest(APP, "180", app_dir="Composition"),  # wires Updater to WebUpdates (WebUpdates -> Updater)
    # 170-179: Phase W (owner-gated workbench)
    "top:PaneController": Dest(WB, "170", ui=WBUI, gated=W_SWITCH),
    "top:PaneBrowserTabOpener": Dest(WB, "170", ui=WBUI, gated=W_CEF),
    "top:TabContentCache": Dest(WB, "171", ui=WBUI, gated=W_CEF),
    "top:WorkspaceContentController": Dest(WB, "171", ui=WBUI, gated=W_SWITCH),
    "top:Tab": Dest(WB, "171", ui=WBUI, gated=W_SWITCH),
    "top:Workspace": Dest(WB, "171", ui=WBUI), "top:EmptyWorkspace": Dest(WB, "171", ui=WBUI),
    "top:PaneContentView": Dest(WBUI, "172", gated=W_MOTION), "top:WindowRootView": Dest(WBUI, "172", gated=W_MOTION),
    "top:Pane": Dest(WB, "172", ui=WBUI, gated=W_SWITCH),
    "top:ContentPresentationScheduler": Dest(WB, "172", ui=WBUI, gated=W_SWITCH),
    "top:Surface": Dest(WBUI, "172", gated=W_MOTION), "top:TitlebarView": Dest(WBUI, "174"),
    "top:SheetDismissal": Dest(WBUI, "174"), "top:GlassModeWatch": Dest(WBUI, "174"),
    "top:NativeCaretAccessory": Dest("CmuxNextFocusUI", "175", gated=W_TYPING),
    "Windows": Dest(WB, "173", ui=WBUI, gated=W_MOTION), "Screens": Dest(WB, "173", ui=WBUI, gated=W_MOTION),
    "RightSidebar": Dest(WB, "174", ui=WBUI),
    # CmuxNextFocus is core and the App's focus code reads Settings, Bridge, Daemon and Control: FocusUI
    "Focus": Dest("CmuxNextFocusUI", "175", gated=W_TYPING),
    "InputVerification": Dest("CmuxNextFocusUI", "176", gated=W_TYPING),
    "Drag": Dest(WB, "177", ui=WBUI, gated=W_MOTION),
    "NewTab": Dest(WB, "178", ui=WBUI, gated=W_SWITCH), "top:NewTab": Dest(WB, "178", ui=WBUI, gated=W_SWITCH),
    "top:NewTerminal": Dest(WB, "178", ui=WBUI, gated=W_SWITCH),
    "top:NewWorkspaceFocus": Dest(WB, "178", ui=WBUI, gated=W_SWITCH),
    "top:StripNewTab": Dest(WB, "178", ui=WBUI, gated=W_SWITCH),
    "top:RestoredNewTabPages": Dest(WB, "178", ui=WBUI, gated=W_SWITCH),
    "top:PreparedTabClose": Dest(WB, "179", ui=WBUI), "top:PreviousNext": Dest(WB, "179", ui=WBUI),
    "top:Space": Dest(WB, "179", ui=WBUI), "top:SplitRoomCheck": Dest(WB, "179", ui=WBUI),
    "top:TestWindowPlacement": Dest(WB, "179", ui=WBUI),
    # The composition root: stays (Composition/, Hosts/, Launch/, Menus/)
    "top:AppServices": Dest(APP, "180", app_dir="Composition"),
    "top:AppEnvironment": Dest(APP, "180", app_dir="Composition"),
    "top:AppDelegate": Dest(APP, "182", app_dir="Launch"), "top:AppProcessRoot": Dest(APP, "182", app_dir="Launch"),
    "top:CmuxApplication": Dest(APP, "182", app_dir="Launch", gated="PL-cef-helper"),
    "top:CmuxNextApp": Dest(APP, "182", app_dir="Launch"), "top:Launch": Dest(APP, "182", app_dir="Launch"),
    "top:BenchHooksMarker": Dest(APP, "182", app_dir="Launch"),
    "top:MainMenu": Dest(APP, "181", app_dir="Menus"), "top:MenuIdentityHeader": Dest(APP, "181", app_dir="Menus"),
    "top:Strings": Dest(APP, "180", app_dir="Composition"),
    # @_exported re-export files: deleted by task 015, never moved
    "top:ComputerUseExport": Dest(APP, "015", app_dir="Composition"),
    "top:DaemonServiceExport": Dest(APP, "015", app_dir="Composition"),
    "top:FocusUIExport": Dest(APP, "015", app_dir="Composition"),
}

# Tiers across layers: a target may depend on another only when neither its layer nor its tier is lower.
# Features see the workbench through CmuxNextWorkbenchInterface, never Workbench or WorkbenchUI (p11 3B rule 3;
# Chrome's BrowserWindowInterface, never Browser), and nothing but the App depends on the diagnostics target.
TIERS = {"CmuxNextWorkbench": 1, "CmuxNextWorkbenchUI": 1, "CmuxNextAppControl": 2}

# A feature directory's extension of a composition hub (`Cloud/AppServices+Cloud.swift`) is that feature's
# Host conformance: it stays in the App as `Hosts/<group>` (Chrome's FooDelegate implemented by chrome/browser).
HOST_EXTENSION = re.compile(r"^(?:AppServices|AppActionContext)\+")

# Single files that leave their directory's group (path relative to the App -> group key).
FILE_GROUPS = {"Onboarding/BrowserImportOfferService.swift": "BrowserImportOffer"}

# Package edges a spec'd task removes before the moves (architecture-layers.json `plan`): left out of the
# package graph so the plan does not route around them.
PLANNED_DROPS = {
    ("CmuxNextDaemonService", "CmuxNextApps"): "architecture-layers.json: DaemonService drops AgentPane, Apps, Bridge, Layout",
    ("CmuxNextDaemonService", "CmuxNextAgentPane"): "architecture-layers.json: DaemonService drops AgentPane, Apps, Bridge, Layout",
    ("CmuxNextDaemonService", "CmuxNextBridge"): "architecture-layers.json: DaemonService drops AgentPane, Apps, Bridge, Layout",
    ("CmuxNextDaemonService", "CmuxNextLayout"): "architecture-layers.json: DaemonService drops AgentPane, Apps, Bridge, Layout",
}

# Multi-word top-level families, matched longest first (anything else: the leading CamelCase word).
TOP_FAMILIES = sorted({
    "AgentTabs", "AgentTab", "AgentChat", "AgentPane", "AppServices", "AppActions", "AppDelegate", "AppEnvironment",
    "AppProcessRoot", "PaneController", "PaneContentView", "PaneBrowserTabOpener", "TabContentCache",
    "WindowRootView", "WorkspaceContentController", "EmptyWorkspace", "NewTab", "NewTerminal",
    "NewWorkspaceFocus", "StripNewTab", "RestoredNewTabPages", "CmuxApplication", "CmuxNextApp", "MainMenu",
    "MenuIdentityHeader", "BenchHooksMarker", "ActionRouting", "ActionScope", "WorkContextTrail",
    "FeaturePolicyEnforcer", "ManagedPolicyBridge", "UpdaterService", "PersonalGroup", "CloudCreationRows",
    "ChatSettingsPush", "ExtensionMenuRouter", "StaticURL", "WorkingURL", "OutboundTab", "DaemonTerminalIO",
    "GhosttyConfigLiveReload", "ThemeBridge", "ShowcaseState", "UIInspectorController", "SettingsPaletteSource",
    "ContentPresentationScheduler", "TitlebarView", "SheetDismissal", "GlassModeWatch", "NativeCaretAccessory",
    "PreparedTabClose", "PreviousNext", "SplitRoomCheck", "TestWindowPlacement", "ComputerUseExport",
    "DaemonServiceExport", "FocusUIExport",
}, key=lambda s: (-len(s), s))
TOP_FAMILY_ALIASES = {"AgentTab": "AgentTabs"}

# Directories split into groups by file-name prefix: (prefixes, domain), first match wins.
HANDLER_DOMAINS = (
    (("ActionRegistry", "AppActionContext", "HandlerCoverage", "HandlerStrings", "MiscHandlerStrings",
      "ConfirmationStrings", "DestructiveConfirmation"), "Infra"),
    (("Cloud", "Accounts", "AppStore", "UpgradeToPro"), "Cloud"),
    (("ChiefInspector", "ChiefMemory", "DaemonChiefMemory", "HomeDock"), "Chief"),
    (("Agent", "AddHarness", "DockedAgentChat", "NewChatPlacement", "TerminalChat", "ComputerUse", "ChatColumn",
      "ChatDock", "FindWork"), "Agent"),
    (("BrowserDevice", "RemoteGroup", "Remote", "Server", "MachineIcon", "MachineReconnect", "SSHTarget"), "Remote"),
    (("Bookmark", "History", "Vault", "Notification", "Music", "NowPlaying", "DaemonClosedHistory", "ClosedTabsFeed",
      "IconHistory", "TabIconHistory"), "History"),
    (("Browser", "CertificateWarning", "DevTools", "Extension", "PageCommand", "PageInfo", "Password",
      "PictureInPicture", "ProfileMenu", "WebInspector", "Link", "OpenIn"), "Browser"),
    (("Settings", "Appearance", "Theme", "Keybinding", "Keymap", "ScreenAppearance", "CLIInstall", "Update",
      "AboutPanel"), "Settings"),
    (("File", "FindInDirectory", "Viewer", "Diff", "VSCode", "Resource"), "Files"),
    (("Terminal", "TextBox", "ResumeCommand", "RunningPrograms", "TabRestart"), "Terminal"),
    (("Tab", "ClosedTab", "CloseToast", "CloseUndo", "BulkClose", "RefusedClose", "GroupIcon", "NewTabKind",
      "PreviousLaunch"), "Tab"),
    (("Pane", "Column", "DockColumn", "Room", "Screen", "Window", "MainPaneLayout", "RightSidebar", "FocusRing",
      "Canvas", "Hint", "List"), "Pane"),
    (("Workspace", "GroupSpawn", "Sidebar"), "Workspace"),
)
CONTROL_DOMAINS = (
    (("DebugSidebar", "DebugHints"), "Sidebar"),
    (("AppBrowserPage", "AppPageInputCursor", "BrowserNativeInputs", "DebugCEF", "DebugChromium", "DebugDownloads",
      "DebugExtension", "DebugWebInspector", "DebugPage", "PageInputCursorEvents", "ExtensionControl",
      "DebugOmnibar", "DebugBrowser"), "Browser"),
    (("DebugWindow", "DebugPane", "DebugMotion", "DebugLayers", "DebugFrame", "DebugTabSwitch",
      "DebugWorkspaceSwitch", "DebugScreens", "DebugDockColumns", "DebugLayoutCounters", "DebugHoverSweep",
      "DebugPointerHover", "DebugCommitBoundary", "DebugViewKey", "DebugAXFrame", "DebugAppActivation",
      "Surface", "DebugMainCPUProbe", "DebugInstantCreate", "DebugOpenPanel"), "Window"),
    (("DebugAgent", "DebugChatOpenTrace", "DebugHome", "DebugNewTerminal", "DebugTerminal", "GhosttyDiagnostics",
      "DebugCardGrid", "DebugNewTab", "DebugCloud"), "Agent"),
)
PAGES_FAMILIES = (
    (("Chief",), "Chief"), (("Settings", "WhatsNew"), "Settings"), (("HomeChannels",), "Home"),
    (("ServerSettings",), "Server"),
)
FAMILY_DIRS = {"Handlers": (HANDLER_DOMAINS, "Misc"), "Control": (CONTROL_DOMAINS, "Core")}
SUBDIR_DIRS = {"Pages": (PAGES_FAMILIES, "Core")}

# Modules a spec'd task replaces before the moves: an import of the key counts as one of the value.
MODULE_RENAMES = {"CmuxNextAppCore": "CmuxNextWorkbenchInterface"}  # task 005 dissolves AppCore

# Frameworks that make a file a view file (with a ui-layer import or an NS view/window subclass).
UI_FRAMEWORKS = frozenset({"SwiftUI", "WebKit"})
UI_SUBCLASS = re.compile(r"\b(?:class)\s+\w+\s*(?:<[^>{]*>)?\s*:\s*(?:NS(?:View|ViewController|Window|Panel|"
                         r"WindowController|Button|TextField|ScrollView|StackView|VisualEffectView|ImageView|"
                         r"CollectionViewItem|TableCellView|Control)|WK\w+)\b")

# ---------------------------------------------------------------------------------------------------
# Facts (both backends)


@dataclasses.dataclass
class Facts:
    """What the graph is built from, whatever read it. Paths are relative to the App directory."""

    files: dict[str, int] = dataclasses.field(default_factory=dict)  # path -> physical lines
    imports: dict[str, set[str]] = dataclasses.field(default_factory=dict)  # path -> imported modules
    ui_files: set[str] = dataclasses.field(default_factory=set)  # paths with a view (see UI_SUBCLASS)
    types: dict[str, str] = dataclasses.field(default_factory=dict)  # top-level App type -> declaring path
    # (src path, src type or "", dst path, dst type, member or "") -> reference count
    refs: collections.Counter = dataclasses.field(default_factory=collections.Counter)
    # module -> the App file that re-exports it (`@_exported import M`): every App file sees M without an import,
    # so a file that names one of M's types needs M once it leaves the App
    reexports: dict[str, str] = dataclasses.field(default_factory=dict)
    implicit_imports: dict[str, set[str]] = dataclasses.field(default_factory=dict)  # path -> modules seen that way
    source: str = "regex"

    def add_implicit(self, rel: str, module: str) -> None:
        if module not in self.imports.setdefault(rel, set()):
            self.imports[rel].add(module)
            self.implicit_imports.setdefault(rel, set()).add(module)


IMPORT = re.compile(r"^[ \t]*(?:@[\w()]+[ \t]+)*(?:(?:public|package|internal|private|fileprivate)[ \t]+)?import[ \t]+"
                    r"(?:(?:struct|class|enum|protocol|func|var|let|typealias|actor)[ \t]+)?(\w+)", re.M)
MODS = r"(?:(?:public|package|internal|open|final|nonisolated|indirect|private|fileprivate)\s+)*"
TOP_DECL = re.compile(r"^[ \t]*(?:@[\w.]+(?:\([^()\n]*\))?\s+)*" + MODS +
                      r"(class|struct|enum|protocol|actor|typealias)\s+([A-Z]\w*)", re.M)
BLOCK_HEAD = re.compile(r"\b(class|struct|enum|protocol|actor|extension)\s+([A-Z][\w]*)")
MEMBER_DECL = re.compile(r"\b(?:func|var|let|case|subscript)\s+`?([A-Za-z_]\w*)`?")
PROP_TYPE = re.compile(r"\b(?:var|let)\s+([A-Za-z_]\w*)\s*:\s*(?:any\s+|some\s+)?\(?([A-Z]\w*)")
TYPED_NAME = re.compile(r"(?<![\w.])([a-z_]\w*)\s*:\s*(?:any\s+|some\s+|inout\s+)?\(?([A-Z]\w*)")
CONSTRUCTED = re.compile(r"\b(?:let|var)\s+([a-z_]\w*)\s*=\s*([A-Z]\w*)\s*(?:\.\s*init\s*)?\(")
TYPE_TOKEN = re.compile(r"(?<![\w.])([A-Z]\w*)")
REEXPORT = re.compile(r"^[ \t]*@_exported[ \t]+(?:(?:public|package|internal)[ \t]+)?import[ \t]+(\w+)", re.M)
VISIBLE = re.compile(r"\b(?:public|package|open)\s")
USR_MODULE = re.compile(r"^s:\D*?(\d+)")
MEMBER_AFTER = re.compile(r"\s*\.\s*([a-z_]\w*)")
CHAIN = re.compile(r"(?:\s*[?!]?\s*\.\s*([A-Za-z_]\w*))")


def _stem(name: str) -> str:
    return re.sub(r"(\+.*)?\.swift$", "", name)


def _top_blocks(code: str, braces) -> list[tuple[int, int, str]]:
    """(open, close, owner type) of each depth-0 type or extension block."""
    out = []
    for p in braces.opens:
        if braces.parent.get(p, -1) != -1:
            continue
        m = None
        for m in BLOCK_HEAD.finditer(braces.head(p)):
            pass
        if m:
            out.append((p, braces.close.get(p, len(code)), m.group(2)))
    return out


def module_types(sources: Path, module: str, seen: frozenset[str] = frozenset()) -> dict[str, set[str]]:
    """Type name -> the modules whose import makes it visible: MODULE's top-level public, package or open types
    (in SOURCES/MODULE), and those of the modules MODULE re-exports in turn (credited to MODULE)."""
    out: dict[str, set[str]] = collections.defaultdict(set)
    for path in sorted((sources / module).rglob("*.swift")):
        code = counts.strip(path.read_text(errors="replace"))
        braces = counts.Braces(code)
        for m in TOP_DECL.finditer(code):
            if not braces.enclosing(m.start()) and VISIBLE.search(m.group(0)):
                out[m.group(2)].add(module)
        for inner in REEXPORT.findall(code):
            if inner not in seen and inner != module:
                for name in module_types(sources, inner, seen | {module}):
                    out[name].add(module)
    return out


def usr_module(usr: str) -> str | None:
    """The module a Swift USR's symbol belongs to: its first length-prefixed identifier (`s:21CmuxNextDaemonService
    13DaemonServiceC`, or `s:SS21CmuxNextDaemonServiceE...` for an extension member of a standard type)."""
    m = USR_MODULE.match(usr)
    return usr[m.end():m.end() + int(m.group(1))] if m else None


def regex_facts(app_dir: Path) -> Facts:
    """Facts from the sources alone: top-level non-private type declarations, members of type bodies and
    extensions, and references by type name, `Type.member`, typed variables and their property chains."""
    facts, codes = scan_files(app_dir)
    structure: dict[str, tuple] = {}
    declared: dict[str, list[str]] = collections.defaultdict(list)
    for rel, code in codes.items():
        braces = counts.Braces(code)
        blocks = _top_blocks(code, braces)
        structure[rel] = (braces, blocks, [b[0] for b in blocks])
        for m in TOP_DECL.finditer(code):
            if braces.enclosing(m.start()):
                continue
            if re.search(r"\b(?:private|fileprivate)\s", m.group(0)):
                continue
            declared[m.group(2)].append(rel)
    for name, paths in declared.items():
        if len(set(paths)) == 1:
            facts.types[name] = paths[0]
    external: dict[str, set[str]] = collections.defaultdict(set)
    for module in facts.reexports:
        for name, mods in module_types(app_dir.parent, module).items():
            external[name] |= mods
    for rel, code in codes.items():
        for name in set(TYPE_TOKEN.findall(code)) & external.keys():
            if name not in declared:  # an App type of the same name shadows the imported one
                for module in external[name]:
                    facts.add_implicit(rel, module)

    members: dict[tuple[str, str], str] = {}  # (type, member) -> path that declares it
    prop_types: dict[tuple[str, str], str] = {}  # (type, property) -> App type of the property
    for rel, code in codes.items():
        braces, blocks, _ = structure[rel]
        for open_, close, owner in blocks:
            if owner not in facts.types:
                continue
            body = code[open_ + 1:close]
            for m in MEMBER_DECL.finditer(body):
                pos = open_ + 1 + m.start()
                if len(braces.enclosing(pos)) == 1:
                    members.setdefault((owner, m.group(1)), rel)
            for m in PROP_TYPE.finditer(body):
                pos = open_ + 1 + m.start()
                if len(braces.enclosing(pos)) == 1 and m.group(2) in facts.types:
                    prop_types.setdefault((owner, m.group(1)), m.group(2))

    types = facts.types
    for rel, code in codes.items():
        braces, blocks, starts = structure[rel]

        def context(pos: int) -> str:
            i = bisect.bisect_right(starts, pos) - 1
            if i >= 0 and blocks[i][0] < pos < blocks[i][1]:
                return blocks[i][2]
            return ""

        def add(pos: int, type_name: str, member: str) -> None:
            dst = members.get((type_name, member), types[type_name]) if member else types[type_name]
            if dst != rel:
                facts.refs[(rel, context(pos), dst, type_name, member)] += 1

        for m in TYPE_TOKEN.finditer(code):
            name = m.group(1)
            if name not in types:
                continue
            after = MEMBER_AFTER.match(code, m.end())
            add(m.start(), name, after.group(1) if after else "")
        typed: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
        for pattern in (TYPED_NAME, CONSTRUCTED):
            for m in pattern.finditer(code):
                if m.group(2) in types:
                    typed[m.group(1)][m.group(2)] += 1
        if not typed:
            continue
        var_type = {name: c.most_common(1)[0][0] for name, c in typed.items()}
        access = re.compile(r"(?:(?<![\w.])|(?<=self\.))(" + "|".join(sorted(map(re.escape, var_type))) + r")\b")
        for m in access.finditer(code):
            owner = var_type[m.group(1)]
            pos = m.end()
            while owner:
                step = CHAIN.match(code, pos)
                if not step or not step.group(1)[0].islower():
                    break
                member = step.group(1)
                add(m.start(), owner, member)
                owner = prop_types.get((owner, member))
                pos = step.end()
    return facts


# ---------------------------------------------------------------------------------------------------
# Index store backend (libIndexStore through ctypes; the C API of indexstore.h)

KIND_ENUM, KIND_STRUCT, KIND_CLASS, KIND_PROTOCOL, KIND_EXTENSION, KIND_TYPEALIAS = 5, 6, 7, 8, 9, 11
TYPE_KINDS = frozenset({KIND_ENUM, KIND_STRUCT, KIND_CLASS, KIND_PROTOCOL, KIND_TYPEALIAS})
ROLE_DEFINITION, ROLE_REFERENCE = 1 << 1, 1 << 2
REL_CHILDOF, REL_EXTENDEDBY, REL_CONTAINEDBY = 1 << 9, 1 << 14, 1 << 16
DEPENDENCY_RECORD = 2


@dataclasses.dataclass(frozen=True)
class Sym:
    usr: str
    name: str
    kind: int


@dataclasses.dataclass(frozen=True)
class Occurrence:
    sym: Sym
    roles: int
    relations: tuple[tuple[int, Sym], ...] = ()


def index_facts(app_dir: Path, records: dict[str, list[Occurrence]]) -> Facts:
    """Facts from index-store occurrences: RECORDS maps each App source path (absolute or relative to
    APP_DIR) to the occurrences of its record. A type defined at top level is an App type; a nested type and
    a member resolve to their top-level owner (through the extension a member is declared in, to the type it
    extends), and a reference keeps the file that defines what it names."""
    facts, _ = scan_files(app_dir)
    facts.source = "index-store"
    top: dict[str, tuple[str, str]] = {}  # usr -> (name, path) of a top-level App type
    parent: dict[str, str] = {}  # usr of a nested type, member or extension -> usr of what contains it
    defined_in: dict[str, str] = {}  # usr -> path of its definition
    member_name: dict[str, str] = {}
    refs: list[tuple[str, str, str]] = []  # (path, referenced usr, context usr)

    def rel_of(path: str) -> str | None:
        p = Path(path)
        try:
            return (p.relative_to(app_dir) if p.is_absolute() else p).as_posix()
        except ValueError:
            return None

    for path, occurrences in records.items():
        rel = rel_of(path)
        if rel is None or rel not in facts.files:
            continue
        for occ in occurrences:
            sym = occ.sym
            # `extension Foo` is a reference to Foo whose relation names the extension symbol.
            for r, s in occ.relations:
                if r & REL_EXTENDEDBY and s.kind == KIND_EXTENSION:
                    parent[s.usr] = sym.usr
            if occ.roles & ROLE_DEFINITION:
                defined_in.setdefault(sym.usr, rel)
                owners = [s for r, s in occ.relations if r & REL_CHILDOF]
                if sym.kind == KIND_EXTENSION:
                    pass
                elif owners:
                    parent[sym.usr] = owners[0].usr
                    if sym.kind not in TYPE_KINDS:
                        member_name[sym.usr] = sym.name
                elif sym.kind in TYPE_KINDS:
                    top[sym.usr] = (sym.name, rel)
            if occ.roles & ROLE_REFERENCE:
                context = next((s.usr for r, s in occ.relations if r & REL_CONTAINEDBY), "")
                refs.append((rel, sym.usr, context))
                module = usr_module(sym.usr)
                if module in facts.reexports:
                    facts.add_implicit(rel, module)

    def owner_type(usr: str) -> str | None:
        seen = set()
        while usr and usr not in top and usr not in seen:
            seen.add(usr)
            usr = parent.get(usr, "")
        return usr if usr in top else None

    names = collections.Counter(name for name, _ in top.values())
    for usr, (name, rel) in top.items():
        if names[name] == 1:
            facts.types[name] = rel
    for rel, usr, ctx in refs:
        owner = owner_type(usr)
        if owner is None:
            continue
        name = top[owner][0]
        if name not in facts.types:
            continue
        member = member_name.get(usr, "") if parent.get(usr) and usr != owner else ""
        dst = defined_in.get(usr, top[owner][1]) if member else top[owner][1]
        ctx_owner = owner_type(ctx) if ctx else None
        if dst != rel:
            facts.refs[(rel, top[ctx_owner][0] if ctx_owner else "", dst, name, member)] += 1
    return facts


def scan_files(app_dir: Path) -> tuple[Facts, dict[str, str]]:
    """Files, line counts, imports and view files of APP_DIR (what the index store does not say), and each
    file's code with comments and string contents blanked."""
    facts = Facts()
    codes: dict[str, str] = {}
    for path in sorted(app_dir.rglob("*.swift")):
        rel = path.relative_to(app_dir).as_posix()
        raw = path.read_text(errors="replace")
        code = counts.strip(raw)
        codes[rel] = code
        facts.files[rel] = raw.count("\n") + (0 if raw.endswith("\n") or not raw else 1)
        facts.imports[rel] = {MODULE_RENAMES.get(m, m) for m in IMPORT.findall(code)}
        for m in REEXPORT.findall(code):
            facts.reexports.setdefault(MODULE_RENAMES.get(m, m), rel)
        if UI_SUBCLASS.search(code):
            facts.ui_files.add(rel)
    return facts, codes


class _StringRef(ctypes.Structure):
    _fields_ = [("data", ctypes.c_char_p), ("length", ctypes.c_size_t)]

    def text(self) -> str:
        return ctypes.string_at(self.data, self.length).decode(errors="replace") if self.data else ""


def find_libindexstore(explicit: str | None) -> str:
    if explicit:
        return explicit
    candidates = []
    xcrun = shutil.which("xcrun")
    swift = None
    if xcrun:
        swift = subprocess.run([xcrun, "--find", "swift"], capture_output=True, text=True).stdout.strip() or None
    swift = swift or shutil.which("swift")
    if swift:
        lib = Path(os.path.realpath(swift)).parent.parent / "lib"
        candidates += [lib / "libIndexStore.dylib", lib / "libIndexStore.so"]
    candidates += [Path("/usr/lib/libIndexStore.so")]
    for c in candidates:
        if c.exists():
            return str(c)
    raise SystemExit("app-graph.py: libIndexStore not found; pass --libindexstore PATH")


def newest_records(units: list[tuple[tuple[int, int], dict[str, str]]]) -> dict[str, str]:
    """Source path -> record name, from the unit written last that names the path. A Debug store keeps the units
    of earlier builds and configurations, so the first unit enumerated can hold an old version of a file."""
    best: dict[str, tuple[tuple[int, int], str]] = {}
    for mtime, records in units:
        for path, record in records.items():
            if path not in best or mtime > best[path][0]:
                best[path] = (mtime, record)
    return {path: record for path, (_, record) in best.items()}


def read_index_store(store: Path, app_dir: Path, lib_path: str) -> dict[str, list[Occurrence]]:
    """Occurrences of every record whose source file is under APP_DIR, from the units of module CmuxNextApp."""
    lib = ctypes.CDLL(lib_path)
    vp, cp, b = ctypes.c_void_p, ctypes.c_char_p, ctypes.c_bool
    unit_cb = ctypes.CFUNCTYPE(b, vp, _StringRef)
    dep_cb = ctypes.CFUNCTYPE(b, vp, vp)
    occ_cb = ctypes.CFUNCTYPE(b, vp, vp)
    rel_cb = ctypes.CFUNCTYPE(b, vp, vp)
    sigs = {
        "indexstore_store_create": (vp, [cp, ctypes.POINTER(vp)]),
        "indexstore_store_dispose": (None, [vp]),
        "indexstore_store_units_apply_f": (b, [vp, ctypes.c_uint, vp, unit_cb]),
        "indexstore_unit_reader_create": (vp, [vp, cp, ctypes.POINTER(vp)]),
        "indexstore_unit_reader_dispose": (None, [vp]),
        "indexstore_unit_reader_get_module_name": (_StringRef, [vp]),
        "indexstore_unit_reader_get_modification_time": (None, [vp, ctypes.POINTER(ctypes.c_int64),
                                                                ctypes.POINTER(ctypes.c_int64)]),
        "indexstore_unit_reader_dependencies_apply_f": (b, [vp, vp, dep_cb]),
        "indexstore_unit_dependency_get_kind": (ctypes.c_int, [vp]),
        "indexstore_unit_dependency_get_filepath": (_StringRef, [vp]),
        "indexstore_unit_dependency_get_name": (_StringRef, [vp]),
        "indexstore_record_reader_create": (vp, [vp, cp, ctypes.POINTER(vp)]),
        "indexstore_record_reader_dispose": (None, [vp]),
        "indexstore_record_reader_occurrences_apply_f": (b, [vp, vp, occ_cb]),
        "indexstore_occurrence_get_symbol": (vp, [vp]),
        "indexstore_occurrence_get_roles": (ctypes.c_uint64, [vp]),
        "indexstore_occurrence_relations_apply_f": (b, [vp, vp, rel_cb]),
        "indexstore_symbol_relation_get_roles": (ctypes.c_uint64, [vp]),
        "indexstore_symbol_relation_get_symbol": (vp, [vp]),
        "indexstore_symbol_get_kind": (ctypes.c_int, [vp]),
        "indexstore_symbol_get_name": (_StringRef, [vp]),
        "indexstore_symbol_get_usr": (_StringRef, [vp]),
        "indexstore_error_get_description": (cp, [vp]),
    }
    for name, (res, args) in sigs.items():
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = res, args

    def check(handle, error, what):
        if not handle:
            why = lib.indexstore_error_get_description(error).decode() if error else "unknown error"
            raise SystemExit(f"app-graph.py: {what}: {why}")
        return handle

    error = vp()
    store_h = check(lib.indexstore_store_create(str(store).encode(), ctypes.byref(error)), error, f"open {store}")
    units: list[str] = []
    keep = unit_cb(lambda _c, name: units.append(name.text()) or True)
    lib.indexstore_store_units_apply_f(store_h, 0, None, keep)

    def sym(handle) -> Sym:
        return Sym(lib.indexstore_symbol_get_usr(handle).text(), lib.indexstore_symbol_get_name(handle).text(),
                   lib.indexstore_symbol_get_kind(handle))

    app_root = str(app_dir.resolve()) + "/"
    unit_records: list[tuple[tuple[int, int], dict[str, str]]] = []
    for unit in units:
        reader = lib.indexstore_unit_reader_create(store_h, unit.encode(), ctypes.byref(error))
        if not reader:
            continue
        if lib.indexstore_unit_reader_get_module_name(reader).text() == APP:
            seconds, nanos = ctypes.c_int64(), ctypes.c_int64()
            lib.indexstore_unit_reader_get_modification_time(reader, ctypes.byref(seconds), ctypes.byref(nanos))
            mine: dict[str, str] = {}

            def on_dep(_c, dep):
                if lib.indexstore_unit_dependency_get_kind(dep) == DEPENDENCY_RECORD:
                    path = os.path.realpath(lib.indexstore_unit_dependency_get_filepath(dep).text())
                    if path.startswith(app_root):
                        mine[path] = lib.indexstore_unit_dependency_get_name(dep).text()
                return True
            lib.indexstore_unit_reader_dependencies_apply_f(reader, None, dep_cb(on_dep))
            unit_records.append(((seconds.value, nanos.value), mine))
        lib.indexstore_unit_reader_dispose(reader)

    out: dict[str, list[Occurrence]] = {}
    for path, record in newest_records(unit_records).items():
        reader = lib.indexstore_record_reader_create(store_h, record.encode(), ctypes.byref(error))
        if not reader:
            why = lib.indexstore_error_get_description(error).decode() if error else "unknown error"
            print(f"app-graph.py: warning: {path}: record {record} unreadable ({why}); its references are left out",
                  file=sys.stderr)
            continue
        occurrences: list[Occurrence] = []

        def on_occ(_c, occ):
            rels: list[tuple[int, Sym]] = []

            def on_rel(_c2, rel):
                rels.append((lib.indexstore_symbol_relation_get_roles(rel),
                             sym(lib.indexstore_symbol_relation_get_symbol(rel))))
                return True
            lib.indexstore_occurrence_relations_apply_f(occ, None, rel_cb(on_rel))
            occurrences.append(Occurrence(sym(lib.indexstore_occurrence_get_symbol(occ)),
                                          lib.indexstore_occurrence_get_roles(occ), tuple(rels)))
            return True
        lib.indexstore_record_reader_occurrences_apply_f(reader, None, occ_cb(on_occ))
        lib.indexstore_record_reader_dispose(reader)
        out[path] = occurrences
    lib.indexstore_store_dispose(store_h)
    return out


# ---------------------------------------------------------------------------------------------------
# Groups, destinations, cuts, order


def _prefix_domain(stem: str, table, default: str) -> str:
    for prefixes, domain in table:
        if stem.startswith(prefixes):
            return domain
    return default


def top_family(stem: str) -> str:
    for family in TOP_FAMILIES:
        if stem.startswith(family):
            return TOP_FAMILY_ALIASES.get(family, family)
    m = re.match(r"[A-Z]+(?=[A-Z][a-z])|[A-Z][a-z0-9]*", stem)
    return m.group(0) if m else stem


def base_group(rel: str) -> str:
    if rel in FILE_GROUPS:
        return FILE_GROUPS[rel]
    parts = rel.split("/")
    if len(parts) > 1 and HOST_EXTENSION.match(parts[-1]):
        return f"Hosts/{base_group(parts[0] + '/' + HOST_EXTENSION.sub('', parts[-1]))}"
    stem = _stem(parts[-1])
    if len(parts) == 1:
        return "top:" + top_family(stem)
    head = parts[0]
    if head in FAMILY_DIRS:
        table, default = FAMILY_DIRS[head]
        return f"{head}/{_prefix_domain(stem, table, default)}"
    if head in SUBDIR_DIRS:
        if len(parts) > 2:
            return f"{head}/{parts[1]}"
        table, default = SUBDIR_DIRS[head]
        return f"{head}/{_prefix_domain(stem, table, default)}"
    return head


@dataclasses.dataclass
class World:
    """Package facts: each existing target's dependencies and every target's layer."""

    deps: dict[str, set[str]]
    layers: dict[str, str]
    order: dict[str, int]

    @classmethod
    def read(cls, root: Path, manifest: str = MANIFEST, layers: str = LAYERS) -> World:
        parsed = counts.parse_manifest((root / manifest).read_text())
        deps = {name: (set(t.deps) | {p for p, _ in t.products}) - {d for (s, d) in PLANNED_DROPS if s == name}
                for name, t in parsed.targets.items() if t.kind != "testTarget"}
        lay = counts.LayerMap.parse((root / layers).read_text())
        placed = {name: layer for name, layer in lay.layers.items() if layer in lay.order}
        for name, layer in NEW_TARGETS.items():
            placed.setdefault(name, layer)
            deps.setdefault(name, set())
        return cls(deps, placed, lay.order)

    def rank(self, target: str) -> int:
        return self.order.get(self.layers.get(target, ""), len(self.order))

    def tier(self, target: str) -> int:
        return TIERS.get(target, 0)

    def above(self, b: str, a: str) -> bool:
        """Whether an edge A -> B points up: B's layer or B's tier is higher than A's."""
        return self.rank(b) > self.rank(a) or self.tier(b) > self.tier(a)

    def modules(self) -> set[str]:
        return set(self.deps) | set(self.layers)


def destination_of(group: str, world: World, table: dict[str, Dest]) -> tuple[Dest, bool]:
    """GROUP's destination and whether the table names it (else CmuxNext<Name> when that target exists)."""
    base = group.removesuffix(":ui")
    if base.startswith("Hosts/"):
        return Dest(APP, (table.get(base[len("Hosts/"):]) or Dest(APP)).task, app_dir="Hosts"), True
    dest = table.get(base)
    if dest is not None:
        if group.endswith(":ui"):
            return Dest(dest.ui or dest.target, dest.task, None, dest.gated, dest.app_dir), True
        return dest, True
    leaf = base.split(":")[-1].split("/")[-1]
    guess = f"CmuxNext{leaf}"
    if guess in world.deps:
        return Dest(guess), False
    return Dest(APP, app_dir="Composition"), False


def is_view_file(rel: str, facts: Facts, world: World) -> bool:
    imports = facts.imports.get(rel, set())
    if imports & UI_FRAMEWORKS or rel in facts.ui_files:
        return True
    return any(world.layers.get(m) in ("ui", "app") for m in imports if m != APP)


def assign_groups(facts: Facts, world: World, table: dict[str, Dest]) -> dict[str, str]:
    """path -> group, with view files of a split group in `<group>:ui`."""
    out = {}
    for rel in facts.files:
        group = base_group(rel)
        dest = table.get(group)
        if dest and dest.ui and world.above(dest.ui, dest.target) and is_view_file(rel, facts, world):
            group += ":ui"
        out[rel] = group
    return out


def tarjan(nodes: list[str], edges: dict[str, set[str]]) -> list[list[str]]:
    """Strongly connected components (iterative Tarjan), each sorted, in reverse topological order."""
    index: dict[str, int] = {}
    low: dict[str, int] = {}
    on_stack: set[str] = set()
    stack: list[str] = []
    out: list[list[str]] = []
    counter = 0
    for start in nodes:
        if start in index:
            continue
        work = [(start, iter(sorted(edges.get(start, ()))))]
        index[start] = low[start] = counter
        counter += 1
        stack.append(start)
        on_stack.add(start)
        while work:
            node, it = work[-1]
            advanced = False
            for nxt in it:
                if nxt not in index:
                    index[nxt] = low[nxt] = counter
                    counter += 1
                    stack.append(nxt)
                    on_stack.add(nxt)
                    work.append((nxt, iter(sorted(edges.get(nxt, ())))))
                    advanced = True
                    break
                if nxt in on_stack:
                    low[node] = min(low[node], index[nxt])
            if advanced:
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[node])
            if low[node] == index[node]:
                comp = []
                while True:
                    w = stack.pop()
                    on_stack.discard(w)
                    comp.append(w)
                    if w == node:
                        break
                out.append(sorted(comp))
    return out


def _reaches(graph: dict[str, set[str]], src: str, dst: str) -> bool:
    seen, todo = {src}, [src]
    while todo:
        n = todo.pop()
        if n == dst:
            return True
        for m in graph.get(n, ()):
            if m not in seen:
                seen.add(m)
                todo.append(m)
    return False


def legal_destinations(mods: set[str], world: World, limit: int = 5) -> list[str]:
    """Targets that may import every module in MODS (none above them, none that already reaches them), fewest
    new dependencies first: what a group whose destination breaks an import could go to instead."""
    out = []
    for target in sorted(world.layers):
        if target == APP or target in mods or "TestSupport" in target or any(world.above(m, target) for m in mods):
            continue
        if target not in world.deps or any(_reaches(world.deps, m, target) for m in mods):
            continue
        out.append((len(mods - world.deps[target]), world.rank(target), target))
    return [t for _, _, t in sorted(out)[:limit]]


def _host_member(type_name: str, member: str) -> str:
    return f"{type_name}.{member}" if member else type_name


def build(facts: Facts, world: World, table: dict[str, Dest] | None = None) -> dict:
    """The app-graph.json object."""
    table = DESTINATIONS if table is None else table
    group_of = assign_groups(facts, world, table)
    groups = sorted(set(group_of.values()))
    dest: dict[str, Dest] = {}
    mapped: dict[str, bool] = {}
    for g in groups:
        dest[g], mapped[g] = destination_of(g, world, table)
    root = {g for g in groups if dest[g].target == APP}
    modules = world.modules()

    # Group edges with their evidence.
    weight: collections.Counter = collections.Counter()
    evidence: dict[tuple[str, str], collections.Counter] = collections.defaultdict(collections.Counter)
    type_edges: collections.Counter = collections.Counter()
    for (src, src_type, dst, dst_type, member), n in facts.refs.items():
        a, b = group_of.get(src), group_of.get(dst)
        if a is None or b is None:
            continue
        if src_type and src_type != dst_type:
            type_edges[(src_type, dst_type)] += n
        if a == b:
            continue
        weight[(a, b)] += n
        evidence[(a, b)][_host_member(dst_type, member)] += n

    # Imports per group (CmuxNext and closure modules only).
    imports: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for rel, mods in facts.imports.items():
        for m in mods:
            if m in modules and m != APP:
                imports[group_of[rel]][m] += 1

    # SCCs of the uncut graph, edges into the composition root aside (those are its Host surface by design).
    movable_edges: dict[str, set[str]] = collections.defaultdict(set)
    for (a, b) in weight:
        if b not in root:
            movable_edges[a].add(b)
    sccs = tarjan(groups, movable_edges)
    scc_of = {}
    for i, comp in enumerate(sorted(sccs, key=lambda c: (-len(c), c))):
        for g in comp:
            scc_of[g] = i

    # Classify edges; build the package graph greedily (existing edges and imports fixed first).
    cuts: dict[str, list[dict]] = collections.defaultdict(list)
    package: dict[str, set[str]] = collections.defaultdict(set)
    for t, ds in world.deps.items():
        package[t] |= ds
    violations: dict[str, list[dict]] = collections.defaultdict(list)
    group_deps: dict[str, set[str]] = collections.defaultdict(set)
    blocked_imports: dict[str, list[str]] = collections.defaultdict(list)

    import_pairs = collections.Counter()
    for g, mods in imports.items():
        if g in root:
            continue
        for m, n in mods.items():
            if m != dest[g].target:
                import_pairs[(dest[g].target, m, g)] += n
    for (d, m, g), n in sorted(import_pairs.items(), key=lambda kv: (-kv[1], kv[0])):
        if world.above(m, d):
            violations[d].append({"group": g, "module": m, "reason": "upward-import"})
            blocked_imports[g].append(m)
        elif m not in package[d] and _reaches(package, m, d):
            violations[d].append({"group": g, "module": m, "reason": "import-cycle"})
            blocked_imports[g].append(m)
        else:
            package[d].add(m)
            group_deps[g].add(m)

    suggestions = {g: legal_destinations(set(imports[g]), world) for g in blocked_imports}

    pair_weight: collections.Counter = collections.Counter()
    pair_edges: dict[tuple[str, str], list[tuple[str, str]]] = collections.defaultdict(list)
    internal: dict[str, set[str]] = collections.defaultdict(set)

    def cut(a: str, b: str, reason: str) -> None:
        cuts[a].append({"to": b, "reason": reason, "weight": weight[(a, b)],
                        "members": sorted(evidence[(a, b)])})

    for (a, b) in sorted(weight):
        if a in root:
            continue
        if b in root:
            cut(a, b, "app")
            continue
        da, db = dest[a].target, dest[b].target
        if world.above(db, da):
            cut(a, b, "upward")
        elif dest[b].gated and not dest[a].gated:
            # Ungated work never waits for an owner: B stays in the App until its owner releases it, so A reaches
            # it through its Host (and the seam folds back into a package edge once B has moved).
            cut(a, b, "gated")
        elif da == db:
            internal[a].add(b)
        else:
            pair_weight[(da, db)] += weight[(a, b)]
            pair_edges[(da, db)].append((a, b))
    for (da, db), _ in sorted(pair_weight.items(), key=lambda kv: (-kv[1], kv[0])):
        if db in package[da] or not _reaches(package, db, da):
            package[da].add(db)
            for a, b in pair_edges[(da, db)]:
                internal[a].add(b)
                group_deps[a].add(db)
        else:
            for a, b in pair_edges[(da, db)]:
                cut(a, b, "cycle")

    # Move units: SCCs after the cuts (each inside one destination), ordered leaf-first.
    movable = [g for g in groups if g not in root]
    units = tarjan(movable, {g: {h for h in internal[g] if h not in root} for g in movable})
    unit_of = {g: i for i, comp in enumerate(units) for g in comp}
    needs: dict[int, set[int]] = collections.defaultdict(set)
    needed_by: dict[int, set[int]] = collections.defaultdict(set)
    for g in movable:
        for h in internal[g]:
            if h in unit_of and unit_of[h] != unit_of[g]:
                needs[unit_of[g]].add(unit_of[h])
                needed_by[unit_of[h]].add(unit_of[g])

    lines = collections.Counter()
    for rel, g in group_of.items():
        lines[g] += facts.files[rel]

    def priority(u: int) -> tuple:
        comp = units[u]
        gated = any(dest[g].gated for g in comp)
        target = dest[comp[0]].target
        return (gated, world.tier(target), world.rank(target), sum(lines[g] for g in comp), comp[0])

    remaining = {u: len(needs[u]) for u in range(len(units))}
    ready = [(priority(u), u) for u, n in remaining.items() if n == 0]
    heapq.heapify(ready)
    sequence: list[int] = []
    while ready:
        _, u = heapq.heappop(ready)
        sequence.append(u)
        for v in needed_by[u]:
            remaining[v] -= 1
            if remaining[v] == 0:
                heapq.heappush(ready, (priority(v), v))
    position = {u: i for i, u in enumerate(sequence)}
    root_order = len(sequence)
    unit_lines = {u: sum(lines[g] for g in units[u]) for u in sequence}

    # The owner gates each unit waits for, its own and those of every unit it needs (sequence is leaf-first).
    waits: dict[int, set[str]] = {}
    for u in sequence:
        waits[u] = {dest[g].gated for g in units[u] if dest[g].gated}
        for v in needs[u]:
            waits[u] |= waits[v]

    # One Q1 task per unit: the task-table row (DESTINATIONS' task, the "family") holding most of its lines, with a
    # letter when the family spans several units (100a, 100b, ...), so each task id names exactly one order entry.
    def family(u: int) -> str | None:
        by: collections.Counter = collections.Counter()
        for g in units[u]:
            if dest[g].task:
                by[dest[g].task] += lines[g]
        return min(by, key=lambda t: (-by[t], t)) if by else None

    by_family: dict[str | None, list[int]] = collections.defaultdict(list)
    for u in sequence:
        by_family[family(u)].append(u)
    task_of: dict[int, str] = {}
    for fam, us in by_family.items():
        for k, u in enumerate(us):
            if fam is None:
                task_of[u] = f"q1-{position[u]}"
            elif len(us) == 1:
                task_of[u] = fam
            else:
                task_of[u] = fam + (chr(ord("a") + k) if len(us) <= 26 else f"-{k + 1}")

    def host_members(g: str) -> list[str]:
        out = set()
        for c in cuts[g]:
            out.update(c["members"])
        return sorted(out)

    types_of = collections.defaultdict(list)
    for name, rel in facts.types.items():
        types_of[group_of[rel]].append(name)

    group_json = {}
    for g in groups:
        d = dest[g]
        entry = {
            "destination": d.target,
            "layer": world.layers.get(d.target, "app" if d.target == APP else None),
            "mapped": mapped[g],
            "files": sum(1 for r in group_of if group_of[r] == g),
            "lines": lines[g],
            "scc_id": scc_of[g],
            "order": root_order if g in root else position[unit_of[g]],
            "q1_task": None if g in root else task_of[unit_of[g]],
            "moves_with": [] if g in root else [h for h in units[unit_of[g]] if h != g],
            "host_members": [] if g in root else host_members(g),
            "deps": sorted(group_deps[g]) if g not in root else sorted(
                {dest[h].target for (a, h) in weight if a == g and dest[h].target != APP}),
            "cuts": [] if g in root else sorted(cuts[g], key=lambda c: (c["to"], c["reason"])),
            "blocked_imports": sorted(set(blocked_imports[g])),
            "legal_destinations": suggestions.get(g, []),
            "out": {h: weight[(g, h)] for h in sorted({b for (a, b) in weight if a == g})},
            "types": sorted(types_of[g]),
        }
        if d.task:
            entry["task"] = d.task
        if d.gated:
            entry["gated"] = d.gated
        if d.app_dir:
            entry["app_dir"] = d.app_dir
        group_json[g] = entry

    order_json = []
    for i, u in enumerate(sequence):
        comp = units[u]
        members = set()
        unit_cuts = []
        for g in comp:
            members.update(host_members(g))
            unit_cuts += [{"from": g, "to": c["to"], "reason": c["reason"], "weight": c["weight"]} for c in cuts[g]]
        order_json.append({
            "order": i, "task": task_of[u], "groups": comp, "destination": dest[comp[0]].target,
            "scc_id": sorted({scc_of[g] for g in comp}),
            "lines": unit_lines[u],
            "families": sorted({dest[g].task for g in comp if dest[g].task}),
            "gated": sorted({dest[g].gated for g in comp if dest[g].gated}),
            "waits_on": sorted(waits[u]),
            "depends_on": sorted(position[v] for v in needs[u]),
            "host_members": sorted(members),
            "cuts": sorted(unit_cuts, key=lambda c: (c["from"], c["to"])),
        })

    cycles = []
    for comp in sorted(sccs, key=lambda c: (-len(c), c)):
        if len(comp) < 2:
            continue
        inside = set(comp)
        cycles.append({
            "scc_id": scc_of[comp[0]], "groups": comp,
            "cuts": [{"from": g, "to": c["to"], "reason": c["reason"], "weight": c["weight"]}
                     for g in comp for c in sorted(cuts[g], key=lambda c: c["to"]) if c["to"] in inside],
        })

    dest_json = {}
    for target in sorted({dest[g].target for g in groups} - {APP}):
        mine = [g for g in groups if dest[g].target == target]
        existing = sorted(world.deps.get(target, set())) if target not in NEW_TARGETS else []
        final = sorted(package[target] - {target})
        dest_json[target] = {
            "layer": world.layers.get(target),
            "new": target in NEW_TARGETS,
            "added_by_map": target in ADDED_TARGETS,
            "groups": mine,
            "lines": sum(lines[g] for g in mine),
            "deps": final,
            "added_deps": sorted(set(final) - set(existing)),
            "violations": sorted(violations[target], key=lambda v: (v["group"], v["module"])),
        }

    all_edges: dict[str, set[str]] = collections.defaultdict(set)
    for (a, b) in weight:
        all_edges[a].add(b)
    largest = max((len(c) for c in tarjan(groups, all_edges)), default=0)
    ungated_lines = sum(unit_lines[u] for u in sequence if not waits[u])
    return {
        "_doc": ("CmuxNextApp move plan from scripts/cmux-next/app-graph.py (p11-codebase task 000a). Regenerate with "
                 "`app-graph.py --write` (regex) or `--index-store PATH --write` (fleet Debug build); never hand-edit. "
                 "groups: destination, host_members (Type.member the group reaches through its Host), deps, cuts "
                 "(reason app = into the composition root, upward = up the layer order or into a higher tier, "
                 "gated = from ungated work into an owner-gated group, cycle = would close a package cycle), scc_id "
                 "(component of the uncut graph, root edges aside), order (index into `order`; the composition root "
                 "has the last index). order: move units leaf-first, one seam commit plus one move commit each; "
                 "task is the unit's Q1 task id (tasks: id -> its one entry; families: task-table row -> entries), "
                 "waits_on the owner gates it or a unit it needs waits for. destinations: final dependency list per "
                 "target. new_targets: what task 007 creates. provisional: true until the facts come from an index "
                 "store (the regex scan guesses variable types file-wide, so host_members, cut weights and deps are "
                 "approximate); task 007 lands final deps only from a non-provisional plan."),
        "source": facts.source,
        "provisional": facts.source != "index-store",
        "new_targets": {t: {"layer": layer, "in_spec_3a": t in SPEC_TARGETS, "why": ADDED_TARGETS.get(t, ""),
                            "receives_app_code": any(dest[g].target == t for g in groups)}
                        for t, layer in sorted(NEW_TARGETS.items())},
        "summary": {
            "files": len(facts.files), "lines": sum(facts.files.values()), "types": len(facts.types),
            "groups": len(groups), "root_groups": len(root), "unmapped_groups": sorted(g for g in groups if not mapped[g]),
            "references": sum(facts.refs.values()), "type_edges": len(type_edges),
            "largest_scc_with_root": largest, "largest_scc": max((len(c) for c in sccs), default=0),
            "cycles": len(cycles), "move_units": len(sequence),
            "cuts": {r: sum(1 for g in cuts for c in cuts[g] if c["reason"] == r) for r in CUT_REASONS},
            "movable_lines": sum(unit_lines.values()),
            "ungated_units": sum(1 for u in sequence if not waits[u]), "ungated_lines": ungated_lines,
            "app_lines_after_ungated": sum(facts.files.values()) - ungated_lines,
            "app_lines_after_all": sum(lines[g] for g in root),
        },
        "groups": group_json,
        "order": order_json,
        "tasks": {u["task"]: u["order"] for u in order_json},
        "families": {t: [u["order"] for u in order_json if t in u["families"]]
                     for t in sorted({t for u in order_json for t in u["families"]})},
        "cycles": cycles,
        "destinations": dest_json,
    }


# ---------------------------------------------------------------------------------------------------
# Output


_FLAT_LIST = re.compile(r"\[\n\s*((?:\"(?:[^\"\\\n]|\\.)*\"|-?\d+),?\n\s*)+\]")


def to_json(graph: dict) -> str:
    """GRAPH as indented JSON with each list of plain strings or numbers on one line."""
    return _FLAT_LIST.sub(lambda m: json.dumps(json.loads(m.group(0))), json.dumps(graph, indent=1)) + "\n"


def queue_lines(graph: dict) -> list[str]:
    out = ["order\ttask\tdestination\tlines\tfamilies\twaits_on\thost_members\tcuts\tgroups"]
    for u in graph["order"]:
        out.append("\t".join([str(u["order"]), u["task"], u["destination"], str(u["lines"]),
                              ",".join(u["families"]) or "-", ",".join(u["waits_on"]) or "-",
                              str(len(u["host_members"])), str(len(u["cuts"])), " ".join(u["groups"])]))
    return out


def design_table(graph: dict) -> str:
    """The DESIGN section 4 destination table: one row per destination, in first-move order."""
    s = graph["summary"]
    first: dict[str, int] = {}
    for u in graph["order"]:
        first.setdefault(u["destination"], u["order"])
    rows = [TABLE_BEGIN, "",
            f"Source: {graph['source']} scan of {s['files']} files, {s['lines']:,} lines, {s['types']:,} top-level types, "
            f"{s['groups']} groups. Uncut, {s['largest_scc_with_root']} groups form one component; without the "
            f"composition root's {s['root_groups']} groups the largest has {s['largest_scc']}. Cuts: "
            f"{s['cuts']['app']} into the root, {s['cuts']['upward']} upward, {s['cuts']['gated']} into owner-gated "
            f"groups, {s['cuts']['cycle']} cycle; {s['move_units']} move units. {s['ungated_units']} units "
            f"({s['ungated_lines']:,} lines) wait for no owner; after them the App has {s['app_lines_after_ungated']:,} "
            f"lines, and {s['app_lines_after_all']:,} after every unit."
            + (" Provisional: the regex scan guesses variable types, so Host members and deps are approximate until "
               "the fleet index-store run." if graph.get("provisional") else ""), "",
            "| First move | Destination | Layer | New | App groups (lines) | Lines | Deps added | Q1 tasks |",
            "|---|---|---|---|---|---|---|---|"]
    for target, d in sorted(graph["destinations"].items(), key=lambda kv: (first.get(kv[0], 10 ** 6), kv[0])):
        groups = ", ".join(f"{g} ({graph['groups'][g]['lines']:,})" for g in d["groups"])
        tasks = sorted({graph["groups"][g].get("q1_task") for g in d["groups"]} - {None})
        added = ", ".join(m.replace("CmuxNext", "") for m in d["added_deps"]) or "-"
        rows.append(f"| {first.get(target, '-')} | {target} | {d['layer']} | {('added' if d.get('added_by_map') else 'yes') if d['new'] else ''} | {groups} | "
                    f"{d['lines']:,} | {added} | {', '.join(tasks) or '-'} |")
    root = [g for g, e in graph["groups"].items() if e["destination"] == APP]
    rows.append(f"| last | {APP} (stays) | app | | " + ", ".join(
        f"{g} -> {graph['groups'][g].get('app_dir', 'Composition')}/" for g in sorted(root)) + f" | "
        f"{sum(graph['groups'][g]['lines'] for g in root):,} | - | 140, 180-182 |")
    rows += ["", TABLE_END]
    return "\n".join(rows)


def write_design(path: Path, table: str) -> None:
    text = path.read_text()
    if TABLE_BEGIN in text:
        start = text.index(TABLE_BEGIN)
        end = text.index(TABLE_END, start) + len(TABLE_END)
        text = text[:start] + table + text[end:]
    else:
        raise SystemExit(f"app-graph.py: {path} has no `{TABLE_BEGIN}` marker")
    path.write_text(text)


def summary_lines(graph: dict) -> list[str]:
    s = graph["summary"]
    out = [f"{s['files']} files, {s['lines']} lines, {s['types']} types, {s['references']} references ({graph['source']})",
           f"{s['groups']} groups ({s['root_groups']} stay in {APP}); unmapped: {', '.join(s['unmapped_groups']) or 'none'}",
           f"largest component: {s['largest_scc_with_root']} uncut, {s['largest_scc']} without root edges; "
           f"{s['cycles']} cycles",
           f"cuts: {s['cuts']}; {s['move_units']} move units"]
    bad = {t: d["violations"] for t, d in graph["destinations"].items() if d["violations"]}
    for t, v in sorted(bad.items()):
        out.append(f"  {t}: " + ", ".join(f"{x['group']} imports {x['module']} ({x['reason']})" for x in v))
    for g, e in sorted(graph["groups"].items()):
        if e["blocked_imports"]:
            out.append(f"  {g} -> {e['destination']} blocked by {', '.join(e['blocked_imports'])}; legal: "
                       f"{', '.join(e['legal_destinations']) or 'none'}")
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", type=Path, default=ROOT, help="checkout to read (default this one)")
    ap.add_argument("--index-store", type=Path, help="index store of a Debug build (exact references)")
    ap.add_argument("--libindexstore", help="path of libIndexStore.dylib/.so")
    ap.add_argument("--json", action="store_true", help="print the JSON")
    ap.add_argument("--queue", action="store_true", help="print the Q1 move queue (TSV)")
    ap.add_argument("--write", action="store_true", help=f"write {OUT} and the {DESIGN} section 4 table")
    ap.add_argument("--out", type=Path, help=f"JSON path for --write (default {OUT} in --repo)")
    args = ap.parse_args(argv)

    repo = args.repo.resolve()
    app_dir = repo / APP_DIR
    world = World.read(repo)
    if args.index_store:
        facts = index_facts(app_dir, read_index_store(args.index_store, app_dir, find_libindexstore(args.libindexstore)))
    else:
        facts = regex_facts(app_dir)
    graph = build(facts, world)
    text = to_json(graph)
    if args.write:
        (args.out or repo / OUT).write_text(text)
        write_design(repo / DESIGN, design_table(graph))
    if args.json:
        sys.stdout.write(text)
    elif args.queue:
        print("\n".join(queue_lines(graph)))
    else:
        print("\n".join(summary_lines(graph)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
