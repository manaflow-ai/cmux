#!/usr/bin/env python3
"""Trims an embedded CEF framework's paks of what cmux never shows.

  cef-pak-drop.py <resources.pak> <cef_pack_resources.h> [--webui <framework binary>]
  cef-pak-drop.py --strings <cef_pack_strings.h> <locale.pak>...

resources.pak:
- Chromium's first-run intro sounds, IDR_INTRO_SOUND_* (six FLAC tracks, 4.8 MB
  that do not compress). Their ids are read by name from the framework's own
  include/cef_pack_resources.h, and an entry goes only when its bytes start
  with the FLAC magic.
- With --webui, the chrome:// pages of WEBUI_PAGES: Chrome's own browser UI
  (New Tab page, History, Bookmarks, Password Manager, the omnibox popup,
  side panels, its AI assistant, first run). cmux shows its own page instead, or
  never opens them. CEF's header does not name these resources, so they are
  found from the framework binary's own WebUI resource maps (path -> id
  arrays in its data segments): a page's map is the run of entries with
  consecutive ids, and it goes only when the top-level .html files of that
  run are exactly one group of WEBUI_PAGES. An id that any other map also
  lists, or that the header names, stays. So does every entry Chromium's native
  code may load as an image (native_image): a raster image (PNG, JPEG, GIF,
  WebP) or a native Lottie, plain or gzip, and any entry whose compression the
  script cannot read. A missing bitmap is LOG(FATAL) ("Unable to load bitmap
  image with id N"); the omnibox popup's images/create_images.png (20900) is
  one such entry, and dropping it crashed every launch (PR 42293). After the
  trim the script checks that every such entry is still there and fails the
  build when one is gone.

locale.pak (--strings): the strings of STRING_PREFIXES (Chrome features
cmux does not have) become empty. Their ids stay in the table, because
Chromium CHECK-fails on a string id it cannot find; an empty entry reads as
"". Names in KEEP_STRINGS, which pages cmux keeps (Settings, Extensions,
Downloads, Print, PDF, Policy, Management) read, and KEEP_PREFIXES, keep
their text. A data
entry that another, kept id aliases keeps its text too.

Every pak is rewritten in place (format 5: header, entry table, alias table,
data); every other resource keeps its bytes. With no header, no matching
names, no maps or a pak in another format it prints a warning and leaves the
file as it is. A missing resource id has no entry, and Chromium's resource
bundle answers an empty resource for it.
"""
import gzip
import os
import re
import struct
import sys

PREFIX = "IDR_INTRO_SOUND_"
MAGIC = b"fLaC"

# Each group: the top-level .html files of one chrome:// page's resource map.
WEBUI_PAGES = {
    "first-run intro": {"intro.html", "intro_refresh.html"},
    "first-run feature showcase": {"feature_showcase.html"},
    # chrome://newtab is cmux's own blank page (BrowserNewTabPage).
    "New Tab page": {"new_tab_page.html"},
    "New Tab page footer": {"new_tab_footer.html"},
    "split view New Tab page and tab search": {"split_new_tab_page.html", "tab_search.html"},
    # chrome://history, chrome://bookmarks and chrome://password-manager are
    # cmux's own pages (ChromiumPageRoute).
    "History": {"history.html"},
    "Bookmarks": {"bookmarks.html"},
    "Password Manager": {"password_manager.html"},
    # Chrome's own toolbar, omnibox and side panels; cmux draws its own.
    "omnibox popup": {"omnibox_popup.html", "omnibox_popup_aim.html", "omnibox_popup_full.html"},
    "omnibox everywhere": {"omnibox_everywhere.html"},
    "WebUI toolbar": {"webui_toolbar.html"},
    "WebUI browser": {"webui_browser.html"},
    "history clusters side panel": {"history_clusters.html"},
    "bookmarks side panel": {"power_bookmarks.html"},
    "reading list side panel": {"reading_list.html"},
    "customize Chrome side panel": {"customize_chrome.html"},
    "tab organizer": {"organizer_panel.html"},
    "shopping insights side panel": {"shopping_insights.html"},
    "profile picker": {"profile_picker.html"},
    "default browser prompt": {"default_browser_modal.html"},
    "search engine choice": {"search_engine_choice.html", "search_engine_choice_refresh.html"},
    # Chrome's AI assistant, visual search and writing help.
    "AI assistant": {"glic.html", "glic_overlay.html"},
    "AI assistant selection overlay": {"selection_overlay.html"},
    "AI assistant context hub": {"context_hub.html", "save_to_memory_bank.html", "topic_details.html"},
    "AI assistant contextual tasks": {"contextual_tasks.html", "ghost_loader.html", "toolbar.html"},
    "AI assistant skills": {"skills.html", "skills_dialog.html"},
    "AI overlay": {"ai_overlay_dialog.html"},
    "visual search overlay": {"lens_overlay.html"},
    "Help me write": {"compose.html"},
}

# Strings of Chrome features cmux does not have: their pages above, and
# browser-window UI CEF never draws.
STRING_PREFIXES = (
    "IDS_NTP_",                      # New Tab page and its customize panel
    "IDS_NEW_TAB_PAGE_",
    "IDS_PASSWORD_MANAGER_UI_",      # chrome://password-manager
    "IDS_BOOKMARK_MANAGER_",         # chrome://bookmarks
    "IDS_HISTORY_CLUSTERS_",         # history side panel and search
    "IDS_HISTORY_EMBEDDINGS_",
    "IDS_READING_MODE_",             # side panels
    "IDS_READ_ANYTHING_",
    "IDS_READING_LIST_",
    "IDS_SIDE_PANEL_",
    "IDS_TAB_SEARCH_",               # Chrome's tab strip, its menus and groups
    "IDS_TAB_ORGANIZATION_",
    "IDS_TAB_GROUP",
    "IDS_SAVED_TAB_GROUP",
    "IDS_TAB_CXMENU_",
    "IDS_TAB_AX_",
    "IDS_BOOKMARK_BAR_",             # Chrome's bookmark bar
    "IDS_SEND_TAB_TO_SELF_",         # Chrome's share menu
    "IDS_SHARING_HUB_",
    "IDS_DATA_SHARING_",             # shared tab groups
    "IDS_COLLABORATION_",
    "IDS_PROFILE_PICKER_",           # Chrome profiles, accounts and sign-in
    "IDS_PROFILE_MENU_",
    "IDS_ACCOUNT_PREVIEW_",
    "IDS_SIGNIN_",
    "IDS_BATCH_UPLOAD_",
    "IDS_TUTORIAL_",                 # Chrome's feature tutorials
    "IDS_IWA_",                      # installing web apps
    "IDS_WEB_APP_",
    "IDS_GLIC_",                     # Chrome's AI assistant
    "IDS_CONTEXTUAL_TASKS_",
    "IDS_LENS_",                     # visual search
    "IDS_COMPOSE_",                  # Help me write
    "IDS_OMNIBOX_PEDAL_",            # Chrome's omnibox; cmux has its own omnibar
    "IDS_ACC_OMNIBOX_",
    "IDS_NEARBY_",                   # ChromeOS and iOS only
    "IDS_POLICY_DLP_",
    "IDS_POLICY_SKYVAULT_",
    "IDS_IOS_DESKTOP_",
)

# Strings under STRING_PREFIXES that kept pages read (Chromium 157's
# chrome/browser/ui/webui/{settings,extensions,downloads,print_preview,policy,
# management} and chrome/browser/pdf sources). Settings > Appearance shares
# the New Tab page's theme and color pickers, so those keep their text too.
KEEP_PREFIXES = ("IDS_NTP_CUSTOMIZE_", "IDS_NTP_THEME")
KEEP_STRINGS = frozenset({
    "IDS_BATCH_UPLOAD_PROMO_SUBTITLE_ITEMS_WITH_LINK",
    "IDS_COMPOSE_SUGGESTION_MAIN_TEXT",
    "IDS_PROFILE_MENU_SIGNIN_PROMO_BUTTON",
})


def intro_sound_ids(header_text):
    """{id: name} of the #define IDR_INTRO_SOUND_* lines of cef_pack_resources.h."""
    found = {}
    for name, value in re.findall(r"^\s*#define\s+(" + PREFIX + r"\w+)\s+(\d+)\s*$", header_text, re.M):
        found[int(value)] = name
    return found


def header_names(header_text):
    """{id: name} of every #define of a cef_pack_*.h header."""
    return {int(value): name for name, value in re.findall(r"^\s*#define\s+([A-Z]\w*)\s+(\d+)\s*$", header_text, re.M)}


def parse(pak):
    """(encoding, [(id, data)], [(alias id, entry index)]) of a format 5 pak."""
    version, = struct.unpack_from("<I", pak, 0)
    if version != 5:
        raise ValueError(f"pak format {version}, not 5")
    encoding, count, aliases = struct.unpack_from("<B3xHH", pak, 4)
    table = 12
    entries = [struct.unpack_from("<HI", pak, table + 6 * i) for i in range(count + 1)]
    alias_at = table + 6 * (count + 1)
    alias_list = [struct.unpack_from("<HH", pak, alias_at + 4 * i) for i in range(aliases)]
    if entries[-1][1] != len(pak) or any(a[1] > b[1] for a, b in zip(entries, entries[1:])):
        raise ValueError("entry offsets do not match the file")
    if entries and entries[0][1] < alias_at + 4 * aliases or any(idx >= count for _, idx in alias_list):
        raise ValueError("entry table does not match the file")
    return encoding, [(entries[i][0], pak[entries[i][1]:entries[i + 1][1]]) for i in range(count)], alias_list


def build(encoding, kept, aliases):
    """Format 5 pak bytes of [(id, data)] and [(alias id, entry index)]."""
    offset = 12 + 6 * (len(kept) + 1) + 4 * len(aliases)
    out = bytearray(struct.pack("<IB3xHH", 5, encoding, len(kept), len(aliases)))
    for rid, data in kept:
        out += struct.pack("<HI", rid, offset)
        offset += len(data)
    out += struct.pack("<HI", 0, offset)
    for rid, idx in aliases:
        out += struct.pack("<HH", rid, idx)
    for _, data in kept:
        out += data
    return bytes(out)


def remove(pak, should_drop, held_ids=frozenset()):
    """(new pak bytes, [dropped ids]) without the entries where should_drop(id, data).
    An entry that an alias of held_ids points to stays, so that alias does too."""
    encoding, entries, alias_list = parse(pak)
    held = {idx for rid, idx in alias_list if rid in held_ids}
    kept, dropped, index_map = [], [], {}
    for i, (rid, data) in enumerate(entries):
        if i not in held and should_drop(rid, data):
            dropped.append(rid)
            continue
        index_map[i] = len(kept)
        kept.append((rid, data))
    if not dropped:
        return pak, []
    new_aliases = [(rid, index_map[idx]) for rid, idx in alias_list if idx in index_map]
    return build(encoding, kept, new_aliases), dropped


def drop(pak, ids):
    """(new pak bytes, [dropped ids]) without the entries of ids whose data is FLAC."""
    return remove(pak, lambda rid, data: rid in ids and data.startswith(MAGIC))


def empty_strings(pak, ids):
    """(new pak bytes, [emptied ids]): the entries of ids keep their id and read as "".
    An entry that a kept alias (an id not in ids) points to keeps its data."""
    encoding, entries, alias_list = parse(pak)
    held = {idx for rid, idx in alias_list if rid not in ids}
    emptied, out = [], []
    for i, (rid, data) in enumerate(entries):
        if rid in ids and data and i not in held:
            emptied.append(rid)
            data = b""
        out.append((rid, data))
    if not emptied:
        return pak, []
    return build(encoding, out, alias_list), emptied


def string_ids(header_text):
    """{id: name} of the strings of STRING_PREFIXES that no kept page reads."""
    return {rid: name for rid, name in header_names(header_text).items()
            if name.startswith(STRING_PREFIXES) and not name.startswith(KEEP_PREFIXES) and name not in KEEP_STRINGS}


# Leading bytes of the entries Chromium's native code may decode as an image.
IMAGE_MAGICS = (b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF87a", b"GIF89a", b"LOTTIE")
GZIP_MAGIC = b"\x1f\x8b"
BROTLI_MAGIC = b"\x1e\x9b"  # grit's brotli header; Python cannot read brotli


def native_image(data):
    """True when native code may load data as an image (a missing bitmap is LOG(FATAL)):
    a raster image or native Lottie, plain or gzip, or an entry the script cannot read."""
    if data.startswith(GZIP_MAGIC):
        try:
            data = gzip.decompress(data)
        except (OSError, EOFError, ValueError):
            return True
    elif data.startswith(BROTLI_MAGIC):
        return True
    return data.startswith(IMAGE_MAGICS) or (data[:4] == b"RIFF" and data[8:12] == b"WEBP")


def lost_images(before, after):
    """Ids of entries native code may load as an image that are in pak before, not after."""
    _, entries, aliases = parse(before)
    images = {rid for rid, data in entries if native_image(data)}
    images |= {rid for rid, idx in aliases if native_image(entries[idx][1])}
    _, kept, kept_aliases = parse(after)
    return sorted(images - {rid for rid, _ in kept} - {rid for rid, _ in kept_aliases})


# --- WebUI resource maps in the framework binary --------------------------------------------

CPU_ARM64, CPU_X86_64 = 0x0100000C, 0x01000007


def macho_slice(binary):
    """The arm64 (else x86_64) Mach-O of a universal binary, or the thin binary itself."""
    magic, = struct.unpack_from(">I", binary, 0)
    if magic == 0xCAFEBABE:
        count, = struct.unpack_from(">I", binary, 4)
        slices = {}
        for i in range(count):
            cpu, _, offset, size, _ = struct.unpack_from(">iiIII", binary, 8 + 20 * i)
            slices[cpu] = binary[offset:offset + size]
        for cpu in (CPU_ARM64, CPU_X86_64):
            if cpu in slices:
                return slices[cpu]
        raise ValueError("no arm64 or x86_64 slice")
    if struct.unpack_from("<I", binary, 0)[0] != 0xFEEDFACF:
        raise ValueError("not a 64-bit Mach-O")
    return binary


def sections(macho):
    """[(segment, section, vm address, size, file offset)] of a 64-bit Mach-O."""
    ncmds, = struct.unpack_from("<I", macho, 16)
    at, out = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", macho, at)
        if cmd == 0x19:  # LC_SEGMENT_64
            segment = macho[at + 8:at + 24].rstrip(b"\0").decode()
            nsects, = struct.unpack_from("<I", macho, at + 64)
            for i in range(nsects):
                s = at + 72 + 80 * i
                name = macho[s:s + 16].rstrip(b"\0").decode()
                addr, length, offset = struct.unpack_from("<QQI", macho, s + 32)
                out.append((segment, name, addr, length, offset))
        at += size
    return out


def resource_maps(macho, ids):
    """Runs of WebUI resource map entries: [[(path, id)]], one run per map.

    A map entry starts with a pointer to its path (a rebase in the chained
    fixup format: the low 36 bits are the target's address) and then the
    32-bit resource id. Entries of one map sit at a fixed stride and the
    generator numbers them in order, so a run is cut where the stride or the
    id sequence breaks."""
    secs = sections(macho)
    cstrings = [(addr, addr + length, offset) for _, name, addr, length, offset in secs if name == "__cstring"]

    def cstring(target):
        for start, end, offset in cstrings:
            if start <= target < end:
                at = offset + (target - start)
                stop = macho.find(b"\0", at, at + 300)
                return macho[at:stop].decode("utf-8", "replace") if stop > at else None
        return None

    found = []
    for segment, name, _, length, offset in secs:
        if not segment.startswith("__DATA") or name not in ("__const", "__data"):
            continue
        for at in range(offset, offset + length - 15, 8):
            pointer, rid, pad = struct.unpack_from("<QiI", macho, at)
            if pointer >> 63 or pad or rid not in ids:
                continue
            path = cstring(pointer & 0xFFFFFFFFF)
            if path:
                found.append((at, path, rid))
    runs, run, stride = [], [], None
    for entry in found:
        if run:
            gap = entry[0] - run[-1][0]
            if (gap == stride or (stride is None and gap in (16, 32))) and entry[2] == run[-1][2] + 1:
                stride = gap
                run.append(entry)
                continue
            runs.append(run)
        run, stride = [entry], None
    if run:
        runs.append(run)
    return [[(path, rid) for _, path, rid in run] for run in runs]


def webui_ids(maps, named):
    """({id: page group}, [page groups found]) of the maps WEBUI_PAGES names."""
    groups = {frozenset(files): label for label, files in WEBUI_PAGES.items()}
    drop, keep, found = {}, set(), []
    for run in maps:
        pages = frozenset(path for path, _ in run if path.endswith(".html") and "/" not in path)
        label = groups.get(pages)
        if label:
            found.append(label)
            for _, rid in run:
                drop[rid] = label
        else:
            keep.update(rid for _, rid in run)
    return {rid: label for rid, label in drop.items() if rid not in keep and rid not in named}, found


# --- command line ------------------------------------------------------------------------------

def rewrite(path, new):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(new)
    os.replace(tmp, path)


def read_text(path, what):
    try:
        with open(path) as f:
            return f.read()
    except OSError as error:
        print(f"warning: cef-pak-drop: cannot read {path} ({error}); {what}")
        return None


def trim_resources(pak_path, header_path, framework):
    header = read_text(header_path, "resources.pak keeps its intro sounds and pages")
    if header is None:
        return 0
    try:
        with open(pak_path, "rb") as f:
            pak = f.read()
        parse(pak)
    except (OSError, ValueError, struct.error) as error:
        print(f"warning: cef-pak-drop: {pak_path}: {error}; left as it is")
        return 0
    sounds = intro_sound_ids(header)
    if not sounds:
        print(f"warning: cef-pak-drop: {header_path} names no {PREFIX}*; resources.pak keeps its intro sounds")
    pages, listed, named = {}, set(), set(header_names(header))
    if framework:
        try:
            with open(framework, "rb") as f:
                macho = macho_slice(f.read())
            _, entries, aliases = parse(pak)
            maps = resource_maps(macho, {rid for rid, _ in entries} | {rid for rid, _ in aliases})
            pages, found = webui_ids(maps, header_names(header))
            listed = {rid for run in maps for _, rid in run}
            missing = sorted(set(WEBUI_PAGES) - set(found))
            if not found:
                print(f"warning: cef-pak-drop: no WebUI resource map in {framework}; resources.pak keeps its pages")
            elif missing:
                print(f"note: cef-pak-drop: no resource map for {', '.join(missing)}")
        except (OSError, ValueError, struct.error, IndexError) as error:
            print(f"warning: cef-pak-drop: {framework}: {error}; resources.pak keeps its pages")
            pages, listed = {}, set()
    new, dropped = remove(pak, lambda rid, data: (rid in sounds and data.startswith(MAGIC))
                          or (rid in pages and not native_image(data)),
                          held_ids=(listed - set(pages)) | named)
    lost = lost_images(pak, new)
    if lost:
        print(f"error: cef-pak-drop: the trim would drop {len(lost)} image resources native code may load"
              f" ({', '.join(map(str, lost[:20]))}); a missing bitmap crashes Chromium at launch", file=sys.stderr)
        return 1
    if not dropped:
        print(f"note: cef-pak-drop: nothing to drop in {pak_path}")
        return 0
    rewrite(pak_path, new)
    sound_names = [sounds[rid] for rid in dropped if rid in sounds]
    groups = sorted({pages[rid] for rid in dropped if rid in pages})
    print(f"note: cef-pak-drop: dropped {len(pak) - len(new)} bytes from resources.pak"
          f" ({len(sound_names)} intro sounds, {len(dropped) - len(sound_names)} page resources)")
    if sound_names:
        print(f"note: cef-pak-drop: intro sounds: {', '.join(sound_names)}")
    if groups:
        print(f"note: cef-pak-drop: pages: {'; '.join(groups)}")
    return 0


def trim_strings(header_path, paks):
    header = read_text(header_path, "the locale paks keep every string")
    if header is None:
        return 0
    ids = string_ids(header)
    if not ids:
        print(f"warning: cef-pak-drop: {header_path} names no string of the trimmed features; locale paks left as they are")
        return 0
    total = 0
    for pak_path in paks:
        try:
            with open(pak_path, "rb") as f:
                pak = f.read()
            new, emptied = empty_strings(pak, ids)
        except (OSError, ValueError, struct.error) as error:
            print(f"warning: cef-pak-drop: {pak_path}: {error}; left as it is")
            continue
        if emptied:
            rewrite(pak_path, new)
            total += len(pak) - len(new)
    print(f"note: cef-pak-drop: emptied {len(ids)} strings of {len(paks)} locale paks, {total} bytes")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] == "--strings":
        return trim_strings(argv[1], argv[2:])
    if len(argv) == 2:
        return trim_resources(argv[0], argv[1], None)
    if len(argv) == 4 and argv[2] == "--webui":
        return trim_resources(argv[0], argv[1], argv[3])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
