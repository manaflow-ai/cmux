title: A settings read never carries your enrollment token
category: fixed

A managed Mac's `settings.snapshot` reply held the forced MDM `EnrollmentToken` in the clear for every client that may read the settings. It now shows the value as present only, as the cold-start cache and the managed status report already did.
