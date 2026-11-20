# Zero-touch remote screen sharing

This experiment keeps a joined machine's screen-share host available while cmux is
closed. The daemon owns the host lifecycle, signs in with the machine credential,
and publishes the machine's screen-share status to the device hub. A viewer opens
the existing Screen Sharing helper through the host session path.

The opt-in is `experiments.remote_screen_share_zero_touch`, which is off by
default. With the setting absent, malformed, or false, the daemon records
`experiment_disabled` and does not start the share host. Existing explicit screen
sharing remains unchanged.

The web gallery keeps the chosen screen-sharing row beside the machine details and
covers local, cloud, SSH, narrow, and wide states in
`EnvironmentScreenSharing.gallery.tsx`.
