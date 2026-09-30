# Classifies the PRs merged since the last stable tag for /release.
# Input: the PR objects printed by the gather query in .claude/commands/release.md, slurped (jq -s).
# $range: `git rev-list <tag>..HEAD`. $reverted: SHAs named by "This reverts commit" in that range.
# Output, one TSV row per PR: status, #number, url, credit, line.
#   entry          the PR's Changelog line, ready to categorize by its Added/Changed/Fixed/Removed prefix
#   check-title    no Changelog section; line is the PR title, for a human to rewrite or drop
#   skip-none      Changelog says none
#   skip-reverted  reverted later in the same range
#   revert-of-N    a revert PR; skip it unless N shipped in an earlier release
def team: . == "MEMBER" or . == "OWNER";
def rows($s): $s | split("\n") | map(select(length > 0));
def changelog:
  (.body // "") | gsub("\r"; "") | gsub("<!--[\\s\\S]*?-->"; "")
  | [scan("(?m)^##[ \\t]*Changelog[ \\t]*\\n((?:(?!##[ \\t]).*\\n?)*)")[0]] | first // ""
  | gsub("^\\s+|\\s+$"; "") | gsub("^[-*][ \\t]+"; "");
def reverts_pr:
  if (.title | test("^Revert \"")) then
    ([(.body // "" | capture("Reverts [A-Za-z0-9_.-]+/cmux#(?<n>[0-9]+)").n),
      (.title | capture("\\(#(?<n>[0-9]+)\\)\"").n)] | first // "?")
  else null end;
def credit:
  (.author.login // "ghost") as $a
  | if (.authorAssociation | team | not) then "-- thanks @\($a)!"
    else [.closingIssuesReferences.nodes[]
          | select((.authorAssociation | team | not) and .author.login != null and .author.login != $a)
          | "@\(.author.login)"] | unique
         | if length > 0 then "-- thanks \(join(", ")) for the report!" else "" end
    end;
(rows($range) | map({(.): true}) | add // {}) as $in
| rows($reverted) as $revshas
| map(select(. != null and $in[.mergeCommit.oid // ""])) | unique_by(.number)
| map(reverts_pr | select(. != null)) as $revnums
| .[] as $pr | $pr
| changelog as $c
| reverts_pr as $r
| [ (if $r != null then "revert-of-\($r)"
     elif ($revnums | index($pr.number | tostring)) or ($revshas | index($pr.mergeCommit.oid)) then "skip-reverted"
     elif ($c | ascii_downcase) == "none" then "skip-none"
     elif $c == "" then "check-title"
     else "entry" end),
    "#\(.number)", .url, credit,
    (if $c == "" or ($c | ascii_downcase) == "none" then .title else $c end) ]
| @tsv
