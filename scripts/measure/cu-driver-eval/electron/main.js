// The input A/B's Electron target (scripts/measure/cu-driver-eval/README.md):
//   Electron main.js LOG x,y,w,h
// The same page and listeners as the WebKit target; the page reports each DOM event as a console
// line "CUEV {...}" and this process appends it to LOG in the shape apps.swift writes.
const { app, BrowserWindow } = require("electron");
const fs = require("fs");
const path = require("path");

const [log, frame] = process.argv.slice(-2);
const [x, y, width, height] = frame.split(",").map(Number);
const start = Date.now();
const write = (line) => fs.appendFileSync(log, JSON.stringify({ ...line, t: Date.now() - start }) + "\n");
fs.writeFileSync(log, "");

app.whenReady().then(() => {
  const win = new BrowserWindow({ x, y, width, height, show: true, title: "cu-eval electron" });
  // Electron 35+ puts the text on event.message; older builds pass it third, after the level.
  win.webContents.on("console-message", (event, _level, positionalMessage) => {
    const message = String(event.message ?? positionalMessage ?? "");
    if (!message.startsWith("CUEV ")) return;
    write({ kind: "event", layer: "dom", ...JSON.parse(message.slice(5)) });
  });
  win.on("focus", () => write({ kind: "state", type: "key" }));
  win.on("blur", () => write({ kind: "state", type: "resign-key" }));
  win.webContents.once("did-finish-load", () => {
    const b = win.getBounds();
    write({ kind: "ready", pid: process.pid, mode: "electron", frame: [b.x, b.y, b.width, b.height],
      scale: require("electron").screen.getPrimaryDisplay().scaleFactor,
      title_bar: b.height - win.getContentBounds().height });
  });
  win.loadFile(path.join(__dirname, "page.html"));
});
app.on("window-all-closed", () => app.quit());
