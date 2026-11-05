/**
 * One apt index update with the snapshot mirror outage fallback, shared by the base image's apt
 * (bake.ts APT_UPDATE_COMMAND) and the browser role's first-use install (browser-probe.ts).
 *
 * `--error-on=any`: without it apt-get update exits 0 when an index fails to download (it warns
 * and keeps the old or no index), so a mirror outage surfaced later as a locked pin with no size,
 * or as "Unable to locate package" in the browser role's install (bake run 41990682146).
 *
 * The dated snapshot stays the source: two bounded attempts (180 s, then 30 s after a 5 s
 * backoff). Only when both fail does `sources` get the public archive and security mirrors (the
 * snapshot source kept at `saved` for diagnosis) and one more 60 s update run. The exact pins
 * that follow still decide whether the archive has every locked version. POSIX sh: the browser
 * role's phases run under dash.
 *
 * A 20 s probe of the first source's InRelease goes first: when the mirror is down, the two attempts
 * waited 180 + 5 + 30 s for nothing (bake run 41857345925: apt-update 225.7 s of a 391 s bake).
 */
const ARCHIVE_SOURCES_BASE64 = "VHlwZXM6IGRlYgpVUklzOiBodHRwOi8vYXJjaGl2ZS51YnVudHUuY29tL3VidW50dS8KU3VpdGVzOiBub2JsZSBub2JsZS11cGRhdGVzIG5vYmxlLWJhY2twb3J0cwpDb21wb25lbnRzOiBtYWluIHJlc3RyaWN0ZWQgdW5pdmVyc2UgbXVsdGl2ZXJzZQpTaWduZWQtQnk6IC91c3Ivc2hhcmUva2V5cmluZ3MvdWJ1bnR1LWFyY2hpdmUta2V5cmluZy5ncGcKClR5cGVzOiBkZWIKVVJJczogaHR0cDovL3NlY3VyaXR5LnVidW50dS5jb20vdWJ1bnR1LwpTdWl0ZXM6IG5vYmxlLXNlY3VyaXR5CkNvbXBvbmVudHM6IG1haW4gcmVzdHJpY3RlZCB1bml2ZXJzZSBtdWx0aXZlcnNlClNpZ25lZC1CeTogL3Vzci9zaGFyZS9rZXlyaW5ncy91YnVudHUtYXJjaGl2ZS1rZXlyaW5nLmdwZwo=";

export function aptUpdateCommand(options: { aptArgs?: string; log: string; sources: string; saved: string }): string {
  const aptGet = options.aptArgs ? `apt-get ${options.aptArgs}` : "apt-get";
  return [
    "apt_update_ok=0;",
    `probe_url="$(awk '/^URIs:/{u=$2} /^Suites:/{s=$2} END{sub(/\\/$/, "", u); print u "/dists/" s "/InRelease"}' ${options.sources})";`,
    `if curl -fsS -o /dev/null -r 0-0 -m 20 "$probe_url" >${options.log} 2>&1; then mirror_up=1; else mirror_up=0; echo "apt-update: probe $probe_url failed" >> ${options.log}; fi;`,
    "[ \"$mirror_up\" -eq 0 ] || for attempt in 1 2; do",
    "  if [ \"$attempt\" -eq 1 ]; then timeout_s=180; else timeout_s=30; fi;",
    `  if timeout "\${timeout_s}s" ${aptGet} update -q --error-on=any >${options.log} 2>&1; then apt_update_ok=1; break; fi;`,
    "  [ \"$attempt\" -eq 2 ] || sleep 5;",
    "done;",
    "if [ \"$apt_update_ok\" -eq 0 ]; then",
    `  echo 'apt-update: snapshot mirror unavailable; falling back to archive.ubuntu.com/security.ubuntu.com' | tee -a ${options.log};`,
    `  cp ${options.sources} ${options.saved};`,
    `  printf %s ${ARCHIVE_SOURCES_BASE64} | base64 -d > ${options.sources};`,
    `  if timeout 60s ${aptGet} update -q --error-on=any >>${options.log} 2>&1; then apt_update_ok=1; fi;`,
    "fi;",
    `if [ "$apt_update_ok" -ne 1 ]; then tail -30 ${options.log}; exit 1; fi`,
  ].join(" ");
}
