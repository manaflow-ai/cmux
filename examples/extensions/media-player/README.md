# Media player

Run `cmux ext dev examples/extensions/media-player` from the repository root with cmux open.
Accept the install card and grant media read and control access. Place **Media player** from
the sidebar editor. Under **Settings → Extensions → Media player → Sidebar layout**, choose **compact** for a thumbnail beside the title or **card** for an
album cover above it. Open **Media player** from the command palette for the larger listening pane.

Start a track in cmux or play audio in a browser tab. The sample follows the same source as
cmux’s Now Playing card, including supported external apps when that option is enabled.
The transport offers previous, play/pause, next and 15-second skips. A source without a
timeline has no seek controls.

The only media subscription is `cmux.watch("media.now_playing")`. It reads `media.get` on
mount and again on `media.changed`. Between updates, the player advances the reported
position in seconds using the playback rate and the time since the `position_ms` timestamp.
The clock belongs to the mounted timeline. Every transport button calls `media.control`
directly from its tap handler.

To uninstall, run `cmux ext remove local/media-player`.
