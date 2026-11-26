# prepare-nightly-variant-primary: &upload-prepared-app-for-signin

Where: the `prepare-nightly-variant-primary` job in `.github/workflows/nightly.yml`, above `- &upload-prepared-app-for-signin`.

Signing waits on this job's end. On a dedicated nightly Mac the default 5 blocks
at a time took 65-156 s (median 85 s, runs 41455121554-41488515134), against
3 s on Blacksmith Linux; 32 at a time, as the unsigned-app upload since #32343.
