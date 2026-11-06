title: A settings read never carries your enrollment token
category: fixed
docs: https://cmux.com/docs/managed-policies

On a managed Mac, a settings read handed the forced MDM `EnrollmentToken` to every client that may read your settings. It now shows the value as present only, as the cold-start cache and the managed status report already did.
