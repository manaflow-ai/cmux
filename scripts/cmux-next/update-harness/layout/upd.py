#!/usr/bin/env python3
"""cmux#44204 old-to-new layout update proof helpers (run on a Mac).

  upd.py prep SRC DST --bundle-id ID --build N --pubkey K [--short S]
      ditto SRC to DST, stamp Info.plist (bundle id, build, short version, SUPublicEDKey,
      nightly-next SUFeedURL), drop restricted entitlements, re-sign the top bundle ad hoc
      (hardened runtime kept; nested code keeps its own signature: the app has
      disable-library-validation).
  upd.py publish APP FEED --keys DIR --port P [--delta-from BUILD --delta-file F]
      zip APP into FEED, EdDSA-sign it with the throwaway key, write FEED/appcast.xml with one
      item (and an optional signed delta for BUILD).
  (make the throwaway key first: swift ../keys.swift generate DIR; it prints the public key for --pubkey)
  upd.py rpc SOCK METHOD [JSON]
  upd.py detach LOG CMD...   start CMD in its own session (survives the reach call), print pid
  upd.py install-cold APP DST --bundle-id ID
      the skipped pre-warm arm: put a copy of APP in place at DST by a rename on DST's volume, as Sparkle's
      installer does, but never exec'd, and remove the app's pre-warm marker, so the next launch is a new copy's
      first exec with no pre-warm (`prewarm_reason` reads `no_record`).
  upd.py launches ID [N]
      the last N (default 3) lines of the app's launch-times.jsonl, one JSON line each with the marks the
      comparison reads.
"""
import json, os, plistlib, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
KEYS_SWIFT = os.path.join(HERE, "..", "keys.swift")  # the harness key tool, one level up
FEED_URL = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
RESTRICTED = ("com.apple.application-identifier", "com.apple.developer.", "keychain-access-groups")


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f"failed ({r.returncode}): {cmd}\n{r.stdout}{r.stderr}")
    return r.stdout.strip()


def prep(a):
    src, dst = a[0], a[1]
    opts = dict(zip(a[2::2], a[3::2]))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    run(["/usr/bin/ditto", src, dst])
    path = os.path.join(dst, "Contents/Info.plist")
    with open(path, "rb") as f:
        info = plistlib.load(f)
    info["CFBundleIdentifier"] = opts["--bundle-id"]
    info["CFBundleVersion"] = opts["--build"]
    info["CFBundleShortVersionString"] = opts.get("--short", f"1.0.0-nightly.{opts['--build']}")
    info["SUPublicEDKey"] = opts["--pubkey"]
    info["SUFeedURL"] = FEED_URL
    with open(path, "wb") as f:
        plistlib.dump(info, f)
    xml = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", dst],
                         capture_output=True).stdout
    ents = plistlib.loads(xml) if xml.strip() else {}
    kept = {k: v for k, v in ents.items() if not k.startswith(RESTRICTED)}
    ent_path = dst.rstrip("/") + ".entitlements.plist"
    with open(ent_path, "wb") as f:
        plistlib.dump(kept, f)
    profile = os.path.join(dst, "Contents/embedded.provisionprofile")
    if os.path.exists(profile):
        os.remove(profile)
    # Sparkle's installer (Autoupdate) puts a code-signing requirement on its XPC peer derived from its
    # own signature (Developer ID team): sign Sparkle ad hoc too, so host and installer agree.
    sparkle = os.path.join(dst, "Contents/Frameworks/Sparkle.framework")
    if os.path.isdir(sparkle):
        run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", "--options", "runtime", sparkle])
    if opts.get("--preserve") == "1":
        # A fleet DEV build is ad hoc already (no hardened runtime): re-seal with its own flags and entitlements.
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
             "--preserve-metadata=entitlements,flags,requirements", dst])
    else:
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime",
             "--entitlements", ent_path, dst])
    run(["/usr/bin/codesign", "--verify", dst])
    exe = os.path.join(dst, "Contents/MacOS", info["CFBundleExecutable"])
    print(json.dumps({"app": dst, "build": info["CFBundleVersion"], "id": info["CFBundleIdentifier"],
                      "exe_bytes": os.path.getsize(exe),
                      "framework": os.path.isdir(os.path.join(dst, "Contents/Frameworks/CmuxNextApp.framework")),
                      "dropped_entitlements": sorted(set(ents) - set(kept))}))


def sign(keys, path):
    return run(["swift", KEYS_SWIFT, "sign", keys, path])


def publish(a):
    app, feed = a[0], a[1]
    opts = dict(zip(a[2::2], a[3::2]))
    os.makedirs(feed, exist_ok=True)
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
        info = plistlib.load(f)
    build, short = info["CFBundleVersion"], info["CFBundleShortVersionString"]
    name = f"update-{build}.zip"
    archive = os.path.join(feed, name)
    if not os.path.exists(archive):
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
    port = opts["--port"]
    deltas = ""
    if "--delta-from" in opts:
        dname = os.path.basename(opts["--delta-file"])
        deltas = f"""
      <sparkle:deltas>
        <enclosure url="http://127.0.0.1:{port}/{dname}" sparkle:version="{build}" sparkle:shortVersionString="{short}" sparkle:deltaFrom="{opts['--delta-from']}" length="{os.path.getsize(opts['--delta-file'])}" type="application/octet-stream" sparkle:edSignature="{sign(opts['--keys'], opts['--delta-file'])}"/>
      </sparkle:deltas>"""
    appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>cmux#44204 updater proof</title>
    <item>
      <title>{short}</title>
      <pubDate>{time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime())}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{short}</sparkle:shortVersionString>
      <sparkle:channel>cmux-next</sparkle:channel>
      <description><![CDATA[cmux#44204 proof]]></description>
      <enclosure url="http://127.0.0.1:{port}/{name}" length="{os.path.getsize(archive)}" type="application/octet-stream" sparkle:edSignature="{sign(opts['--keys'], archive)}"/>{deltas}
    </item>
  </channel>
</rss>
"""
    with open(os.path.join(feed, "appcast.xml"), "w") as f:
        f.write(appcast)
    print(appcast)


def rpc(a):
    import socket
    c = socket.socket(socket.AF_UNIX)
    c.settimeout(20)
    c.connect(a[0])
    c.sendall((json.dumps({"id": 1, "method": a[1], "params": json.loads(a[2]) if len(a) > 2 else {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    print(buf.decode())


def support_dir(bundle_id):
    return os.path.expanduser(f"~/Library/Application Support/{bundle_id}")


def install_cold(a):
    app, dst = a[0].rstrip("/"), a[1].rstrip("/")
    opts = dict(zip(a[2::2], a[3::2]))
    # Copy beside DST (same volume), then two renames: the installed copy is the new inode, as after Sparkle's
    # RENAME_SWAP, but no process has run from it. ditto, not cp: it keeps the signature's extended attributes.
    staged, old = dst + ".cold-new", dst + ".cold-old"
    for leftover in (staged, old):
        if os.path.exists(leftover):
            run(["/bin/rm", "-rf", leftover])
    run(["/usr/bin/ditto", app, staged])
    if os.path.exists(dst):
        os.rename(dst, old)
    os.rename(staged, dst)
    if os.path.exists(old):
        run(["/bin/rm", "-rf", old])
    marker = os.path.join(support_dir(opts["--bundle-id"]), "launch-prewarm")
    had_marker = os.path.exists(marker)
    if had_marker:
        os.remove(marker)
    print(json.dumps({"installed": dst, "from": app, "removed_marker": had_marker}))


def launches(a):
    path = os.path.join(support_dir(a[0]), "launch-times.jsonl")
    with open(path) as f:
        lines = [line for line in f if line.strip()]
    keys = ("started_at", "build", "pre_main_ms", "main_ms", "first_window_frame_ms", "home_first_page_ms",
            "prewarmed", "prewarm_reason", "first_launch_of_build")
    for line in lines[-int(a[1]) if len(a) > 1 else -3:]:
        record = json.loads(line)
        print(json.dumps({k: record.get(k) for k in keys}))


if __name__ == "__main__":
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == "detach":
        pid = os.fork()
        if pid == 0:
            os.setsid()
            out = os.open(rest[0], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            null = os.open("/dev/null", os.O_RDONLY)
            os.dup2(null, 0); os.dup2(out, 1); os.dup2(out, 2)
            os.execvp(rest[1], rest[1:])
        print(pid)
    else:
        {"prep": prep, "publish": publish, "rpc": rpc, "install-cold": install_cold, "launches": launches}[cmd](rest)
