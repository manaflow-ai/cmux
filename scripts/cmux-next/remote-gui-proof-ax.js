// A person's click on one native control of a process, for the Remote GUI proof (remote-gui-proof.py).
//   osascript -l JavaScript remote-gui-proof-ax.js PID AX_IDENTIFIER find|click|press
// find: the control's centre in screen points; click: a real left click there (CGEvent mouse down and up,
// through the window server, as a mouse makes it); press: the control's AXPress (what VoiceOver does).
// Prints one JSON line. A native panel (Add Device) is no web page and no main window, so neither
// debug.page nor debug.mouse reaches it.
ObjC.import('CoreGraphics');

function run(argv) {
  const pid = parseInt(argv[0], 10), ident = argv[1], mode = argv[2] || 'click';
  const se = Application('System Events');
  const procs = se.processes.whose({unixId: pid});
  if (procs.length === 0) return JSON.stringify({error: 'no process ' + pid});
  const proc = procs[0];
  const wins = proc.windows();
  const seen = [];
  for (const w of wins) {
    let els;
    try { els = w.entireContents(); } catch (e) { seen.push('window: ' + e); continue; }
    for (const el of els) {
      let id = null;
      try { id = el.attributes.byName('AXIdentifier').value(); } catch (e) { continue; }
      if (id && id.indexOf('cmux.addDevice') === 0 && seen.length < 60) seen.push(id);
      if (id !== ident) continue;
      const pos = el.position(), size = el.size();
      const x = pos[0] + size[0] / 2, y = pos[1] + size[1] / 2;
      if (mode === 'find') return JSON.stringify({found: true, x: x, y: y, w: size[0], h: size[1]});
      if (mode === 'press') {
        el.actions.byName('AXPress').perform();
        return JSON.stringify({found: true, pressed: true, x: x, y: y});
      }
      const point = {x: x, y: y};
      const kinds = [$.kCGEventMouseMoved, $.kCGEventLeftMouseDown, $.kCGEventLeftMouseUp];
      for (const kind of kinds) {
        const event = $.CGEventCreateMouseEvent(null, kind, point, $.kCGMouseButtonLeft);
        $.CGEventPost($.kCGHIDEventTap, event);
        delay(0.06);
      }
      return JSON.stringify({found: true, clicked: true, x: x, y: y});
    }
  }
  return JSON.stringify({found: false, windows: wins.length, ids: seen});
}
