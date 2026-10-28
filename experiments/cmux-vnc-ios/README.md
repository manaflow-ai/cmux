# cmux VNC on iOS (demo)

A demo app that shows how VNC streaming would work in the future cmux iOS
app. It runs on `Packages/Shared/CmuxVNC`, the same RFB engine the cmux-next
Mac app uses for VNC compatibility hosts in its remote view pane
(plans/cmux-next/remote-desktop.md section 12).

The home-screen name is **cmux VNC**.

## What it shows

- **Demo desktop.** A loopback VNC server inside the app (`CmuxVNCDemoServer`)
  draws an animated desktop. It needs no network and no other computer: drag to
  paint, type to echo text.
- **Real computers.** A Mac with Screen Sharing on (Apple Diffie-Hellman
  sign-in with a Mac account), or any VNC server (VNC password or none) on
  your local network or tailnet. Passwords are stored in the iPhone keychain.
- **Input.** One model, no modes: tap clicks where you touch, press-and-hold
  then drag drags, one finger pans a zoomed view, two-finger tap right-clicks,
  two fingers scroll what is under them, and pinch zooms (zoom in for small
  targets).
- **Keyboard.** A software keyboard with Esc, Tab, sticky Control, Option and
  Command, arrows and paging keys, plus hardware keyboards by HID usage.
- **Stream stats.** Frames per second, KB/s, update latency and the encoding
  the server chose (ZRLE, Zlib, Hextile, RRE, CopyRect or Raw).

## Build and run

```bash
cd experiments/cmux-vnc-ios
xcodegen generate          # after adding or removing files
xcodebuild -project CmuxVNCiOS.xcodeproj -scheme CmuxVNCiOS \
  -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

To run it on an iPhone, open the project in Xcode, choose your team under
Signing, and run. The app asks for local network access the first time it
connects to a computer on your network.

## Limits

- The connection is plain RFB: VNC streams are not encrypted. Use it on your
  own network or tailnet.
- RFB is tile-based, so motion-heavy content is slower than the video stream
  of `cmux.rd/1`, which the future iOS app uses as its primary path.
