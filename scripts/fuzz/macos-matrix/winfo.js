ObjC.import("AppKit"); ObjC.import("CoreGraphics");
function run(argv) {
  const pid = parseInt(argv[0] || "0");
  const front = $.NSWorkspace.sharedWorkspace.frontmostApplication;
  const scr = $.NSScreen.mainScreen.frame;
  const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
  const wins = list.filter(w => w.kCGWindowOwnerPID === pid && w.kCGWindowLayer === 0)
    .map(w => [w.kCGWindowBounds.X, w.kCGWindowBounds.Y, w.kCGWindowBounds.Width, w.kCGWindowBounds.Height]);
  return JSON.stringify({front_pid: front.processIdentifier, front: ObjC.unwrap(front.bundleIdentifier), screen: [scr.size.width, scr.size.height], windows: wins});
}
