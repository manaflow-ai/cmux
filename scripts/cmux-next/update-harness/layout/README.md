# Old-to-new layout update driver

Helpers that drive a Sparkle update from a build with the old app layout to a
build with the new one, on a Mac, the way `../run.py` drives its scenarios:
a throwaway EdDSA key, a local feed, and ad hoc re-signing. They were written
for the update proof of cmux#44204. `keys.swift` is the harness key tool one
directory up. Every path is an argument.

## Commands

    swift ../keys.swift generate KEYDIR
        Writes KEYDIR/private.key (mode 0600), prints the public key.

    python3 upd.py prep SRC DST --bundle-id ID --build N --pubkey K [--short S] [--preserve 1]
        Copies SRC to DST, sets bundle id, build, short version, SUPublicEDKey
        and the nightly feed URL, drops restricted entitlements and the
        provisioning profile, re-signs Sparkle and then the app ad hoc.
        --preserve 1 keeps the flags and entitlements of an already ad hoc
        build. Prints one JSON line (exe size, whether CmuxNextApp.framework
        is present, dropped entitlements).

    python3 upd.py publish APP FEED --keys KEYDIR --port P [--delta-from BUILD --delta-file F]
        Zips APP into FEED, signs it, writes FEED/appcast.xml with one item
        and, with --delta-from, a signed delta for that build. Serve FEED
        over http on 127.0.0.1:P yourself.

    python3 upd.py rpc SOCK METHOD [JSON]
        One JSON request to the app's control socket; prints the reply.

    python3 upd.py detach LOG CMD...
        Starts CMD in its own session with output to LOG; prints the pid.

    python3 clones.py BUNDLE_ID APP
        Reads the Chromium code-sign clone folder for BUNDLE_ID and prints
        one JSON report of its regular files, matched by inode to APP's main
        executable and CmuxNextApp framework binary.

## Order used for the proof

1. Generate the key. Prep the old-layout build as build 1 and the new-layout
   build as build 2, both with the same bundle id and public key.
2. Publish build 2 to the feed and serve it. Install and launch build 1, then
   update it to build 2 from the feed (old to new).
3. Prep a build 3 from the new layout, publish it, and update build 2 to
   build 3 (new to new).
4. Build a delta against the old layout (`publish ... --delta-from 1
   --delta-file F`, with F made by Sparkle's delta tool from the build 1 and
   build 2 apps) and update build 1 again to check the delta path.

## What each check reads

- `launch-times.jsonl`, one line per launch, after each relaunch:
  `pre_main_ms` (time before main), `first_window_frame_ms` (time to the first
  window frame) and `prewarmed` (whether the launch used the pre-warm).
  Compare the first launch after an update with later ones.
- The clone folder: run `ls -li` on the clone folder that `clones.py` names,
  or read its report. A clone file whose inode matches the installed
  executable or framework is a link to the live file; the report's
  `bytes_held_by_links_to_files_not_in_app` is space held by links to files
  that left the app after the update.
