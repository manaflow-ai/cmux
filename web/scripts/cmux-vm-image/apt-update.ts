/**
 * One apt index update with the snapshot mirror outage fallback, shared by the base image's apt
 * (bake.ts APT_UPDATE_COMMAND) and the browser role's first-use install (browser-probe.ts).
 *
 * `--error-on=any`: without it apt-get update exits 0 when an index fails to download (it warns
 * and keeps the old or no index), so a mirror outage surfaced later as a locked pin with no size,
 * or as "Unable to locate package" in the browser role's install (bake run 41990682146).
 *
 * The dated snapshot stays the source, for one bounded attempt (90 s). Any failure of it, an error or the
 * timeout, falls back at once: the public archive and security mirrors go into `sources` (the snapshot source
 * kept at `saved` for diagnosis) and one more 60 s update runs. The exact pins that follow still decide whether
 * the archive has every locked version. A 20 s probe of the snapshot's InRelease goes first, so an unreachable
 * mirror falls back without the attempt. POSIX sh: the browser role's phases run under dash.
 *
 * Before (bake runs 41857345925, 42012003953): two attempts, 180 s then 30 s after a 5 s backoff. The mirror
 * answered the probe but its update hung, so every bake spent 226 to 230 s here before the archive answered in
 * about 10 s. A retry of a hung mirror never succeeded in those runs.
 */
const ARCHIVE_SOURCES_BASE64 = "VHlwZXM6IGRlYgpVUklzOiBodHRwOi8vYXJjaGl2ZS51YnVudHUuY29tL3VidW50dS8KU3VpdGVzOiBub2JsZSBub2JsZS11cGRhdGVzIG5vYmxlLWJhY2twb3J0cwpDb21wb25lbnRzOiBtYWluIHJlc3RyaWN0ZWQgdW5pdmVyc2UgbXVsdGl2ZXJzZQpTaWduZWQtQnk6IC91c3Ivc2hhcmUva2V5cmluZ3MvdWJ1bnR1LWFyY2hpdmUta2V5cmluZy5ncGcKClR5cGVzOiBkZWIKVVJJczogaHR0cDovL3NlY3VyaXR5LnVidW50dS5jb20vdWJ1bnR1LwpTdWl0ZXM6IG5vYmxlLXNlY3VyaXR5CkNvbXBvbmVudHM6IG1haW4gcmVzdHJpY3RlZCB1bml2ZXJzZSBtdWx0aXZlcnNlClNpZ25lZC1CeTogL3Vzci9zaGFyZS9rZXlyaW5ncy91YnVudHUtYXJjaGl2ZS1rZXlyaW5nLmdwZwo=";

export function aptUpdateCommand(options: { aptArgs?: string; log: string; sources: string; saved: string }): string {
  const aptGet = options.aptArgs ? `apt-get ${options.aptArgs}` : "apt-get";
  return [
    "apt_update_ok=0;",
    `probe_url="$(awk '/^URIs:/{u=$2} /^Suites:/{s=$2} END{sub(/\\/$/, "", u); print u "/dists/" s "/InRelease"}' ${options.sources})";`,
    `if curl -fsS -o /dev/null -r 0-0 -m 20 "$probe_url" >${options.log} 2>&1; then mirror_up=1; else mirror_up=0; echo "apt-update: probe $probe_url failed" >> ${options.log}; fi;`,
    `if [ "$mirror_up" -eq 1 ]; then if timeout 90s ${aptGet} update -q --error-on=any >${options.log} 2>&1; then apt_update_ok=1; else echo "apt-update: snapshot update failed (exit $?)" >> ${options.log}; fi; fi;`,
    "if [ \"$apt_update_ok\" -eq 0 ]; then",
    `  echo 'apt-update: snapshot mirror unavailable; falling back to archive.ubuntu.com/security.ubuntu.com' | tee -a ${options.log};`,
    `  cp ${options.sources} ${options.saved};`,
    `  printf %s ${ARCHIVE_SOURCES_BASE64} | base64 -d > ${options.sources};`,
    `  if timeout 60s ${aptGet} update -q --error-on=any >>${options.log} 2>&1; then apt_update_ok=1; fi;`,
    "fi;",
    `if [ "$apt_update_ok" -ne 1 ]; then tail -30 ${options.log}; exit 1; fi`,
  ].join(" ");
}
