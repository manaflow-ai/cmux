// The window server's on-screen window list, sampled as fast as it answers (about 120 a second), for
// scripts/measure/graceful-relaunch.py: which process has a window over each saved frame, frame by frame, across a
// relaunch. Needs no Screen Recording grant (bounds, owner, alpha and layer only; never names or pixels).
//   osascript -l JavaScript graceful-relaunch-windows.js SECONDS OUT.jsonl [OWNER_SUBSTRING...]
// One JSON line per sample: {"t": ms since start (wall clock ms in the first line's "epoch"), "w": [[pid, owner,
// number, layer, alpha, x, y, w, h], ...]} front to back, only windows whose owner name contains a substring
// (all of them when none is given). Ends after SECONDS.
ObjC.import('Cocoa');
ObjC.import('CoreGraphics');

function run(argv) {
  const seconds = parseFloat(argv[0]);
  const path = argv[1];
  const owners = argv.slice(2);
  $.NSFileManager.defaultManager.createFileAtPathContentsAttributes(path, $(), $());
  const out = $.NSFileHandle.fileHandleForWritingAtPath(path);
  const start = Date.now();
  let samples = 0;
  out.writeData($(JSON.stringify({epoch: start}) + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
  while (Date.now() - start < seconds * 1000) {
    const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0)));
    const rows = [];
    for (const w of list || []) {
      const owner = w.kCGWindowOwnerName || '';
      if (owners.length && !owners.some((o) => owner.indexOf(o) >= 0)) continue;
      const b = w.kCGWindowBounds || {};
      rows.push([w.kCGWindowOwnerPID, owner, w.kCGWindowNumber, w.kCGWindowLayer, w.kCGWindowAlpha, b.X, b.Y, b.Width, b.Height]);
    }
    out.writeData($(JSON.stringify({t: Date.now() - start, w: rows}) + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
    samples++;
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.004));
  }
  out.closeFile;
  return 'samples ' + samples;
}
