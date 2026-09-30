# cmux-devbox wallpapers

Every desktop session paints its X root window through
`/usr/local/bin/cmux-wallpaper`. Display `:1` uses the original mountain lake;
additional displays cycle through the bundled collection by display number.
The selection is deterministic, so all clients see the same image for a given
Cloud Display and a supervisor restart does not change it.
Each display repaints after a noVNC remote resize, and an upgraded display
helper repaints the displays it adopts from its predecessor.

The image collection is hermetic: the image bake copies these files into
`/usr/share/backgrounds/cmux` and never downloads artwork at build time.
If an image or `feh` is unavailable, the helper paints a visible slate color;
startup reports failure only if even that fallback cannot be applied.

## Assets

- `wallpaper.jpg` — mountain lake landscape. Source: Wikimedia Commons,
  [File:Landscape-mountains-nature-lake (24326735085).jpg](https://commons.wikimedia.org/wiki/File:Landscape-mountains-nature-lake_(24326735085).jpg).
  Original file: [upload.wikimedia.org](https://upload.wikimedia.org/wikipedia/commons/5/5c/Landscape-mountains-nature-lake_%2824326735085%29.jpg).
  Author: www.Pixel.la Free Stock Photos (via Flickr). License: **CC0 1.0 Universal (public domain dedication)**. The 2560x1707 JPEG is checked in so
  image builds are reproducible.
- `wallpaper-aurora.jpg`, `wallpaper-desert.jpg`, `wallpaper-ocean.jpg`, and
  `wallpaper-sunset.jpg` are original procedural illustrations generated for
  cmux and checked in as 1920x1280 JPEGs. They have no external asset or
  network dependency.
