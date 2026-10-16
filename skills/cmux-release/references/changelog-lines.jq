# Classifies the PRs merged since the last stable tag for /release.
# Input: the PR objects printed by the gather query in .claude/commands/release.md, slurped (jq -s).
# $log: `git log --first-parent --format='%H%n%B%n@@end@@' <tag>..HEAD`, main's commits in the range
#   with their messages.
# Output, one TSV row per PR: status, #number, url, author, credit, line.
#   entry          every line of the PR's Changelog section starts with Added/Changed/Fixed/Removed
#                  (several lines are joined with a literal \n; each becomes its own bullet)
#   check-line     the Changelog section has a line without that prefix; line is the section as written
#   check-title    no Changelog section, or an empty one; line is the PR title
#   skip-none      the Changelog section says none
#   skip-reverted  undone later in the range by a revert that was not itself reverted
#   skip-revert    a revert or reapply whose targets are all in the range; their own rows already
#                  reflect it
#   revert-of-X    a revert or reapply of X (#N or a commit SHA) from an earlier release, or `?` when
#                  the target can't be found
def core_team: ["lawrencecchen", "austinywang", "teamleaderleo"];
def person: select(. != null and .login != null and .login != "ghost" and .__typename != "Bot"
                   and (.login | test("\\[bot\\]$") | not)) | .login;
def handles: map("@" + .) | if length > 1 then "\(.[:-1] | join(", ")) and \(.[-1])" else .[0] end;
def credit:
  (.author.login // "") as $login
  | [.author | person | select(. as $a | core_team | index($a) | not)] as $author
  | [.closingIssuesReferences.nodes[]?.author | person
     | select(. as $r | (core_team | index($r) | not) and ($r | ascii_downcase) != ($login | ascii_downcase))]
    | unique_by(ascii_downcase) | sort_by(ascii_downcase) as $reporters
  | (if ($reporters | length) > 1 then "the reports" else "the report" end) as $report
  | if ($author | length) > 0 and ($reporters | length) > 0 then
      "-- thanks \($author | handles), and thanks \($reporters | handles) for \($report)!"
    elif ($author | length) > 0 then "-- thanks \($author | handles)!"
    elif ($reporters | length) > 0 then "-- thanks \($reporters | handles) for \($report)!"
    else "" end;
def section_lines:
  (.body // "") | gsub("\r"; "") | gsub("<!--[\\s\\S]*?-->"; "")
  | [scan("(?m)^#{1,6}[ \\t]*Changelog[ \\t]*\\n((?:(?!#{1,6}[ \\t]).*\\n?)*)")[0]] | first // ""
  | split("\n") | map(gsub("^\\s+|\\s+$"; "") | sub("^[-*+][ \\t]+"; "")) | map(select(length > 0));
def is_none: gsub("[`*_]"; "") | ascii_downcase | test("^none\\s*($|[.(:;,-])");
def has_prefix: test("^(added|changed|fixed|removed)\\b"; "i");
def is_revert_title: .title | test("^(Revert|Reapply) \"");

($log | split("@@end@@\n") | map(sub("^\\s+"; "") | select(length > 0)
   | {sha: (split("\n")[0]), targets: [scan("This reverts commit ([0-9a-f]{40})")[0]]})) as $commits
| ($commits | map({(.sha): true}) | add // {}) as $in
| map(select(. != null and .number != null and $in[.mergeCommit.oid // ""])) | unique_by(.number) as $prs
| ($prs | map({(.mergeCommit.oid): "#\(.number)"}) | add // {}) as $pr_of
# Undo edges between nodes: "#N" for a PR in the range, a SHA for any other commit.
| ([$commits[] | ($pr_of[.sha] // .sha) as $from | .targets[] | {from: $from, to: ($pr_of[.] // .)}]
   + [$prs[] | "#\(.number)" as $from
      # The body's `Reverts #N` wins. The title is a fallback, and never for a revert of a
      # revert or reapply, whose nested title also names the original PR.
      | [(.body // "") | scan("Reverts (?:[A-Za-z0-9_.-]+/cmux)?#([0-9]+)")[0]] as $body
      | if ($body | length) > 0 then $body[]
        elif (.title | test("^Revert \"(Revert|Reapply) ")) then empty
        else (.title | capture("^Revert \".*\\(#(?<n>[0-9]+)\\)\"").n) end
      | {from: $from, to: "#\(.)"}]
   | unique) as $edges
| ($edges | group_by(.to) | map({(.[0].to): map(.from)}) | add // {}) as $undoers
| ($prs | map({("#\(.number)"): true}) | add // {}) as $pr_in
| def live($n; $depth): $depth > 50 or ([$undoers[$n][]? | select(live(.; $depth + 1))] | length) == 0;
  def in_range($n): $pr_in[$n] or $in[$n];
  $prs[]
| "#\(.number)" as $node
| section_lines as $lines
| [ (if (live($node; 0) | not) then "skip-reverted"
     elif is_revert_title then
       [$edges[] | select(.from == $node) | .to] as $targets
       | [$targets[] | select(in_range(.) | not) | if startswith("#") then . else .[:10] end] as $outside
       | if ($targets | length) == 0 then "revert-of-?"
         elif ($outside | length) == 0 then "skip-revert"
         else "revert-of-\($outside | join(","))" end
     elif ($lines | length) == 0 then "check-title"
     elif ($lines | length) == 1 and ($lines[0] | is_none) then "skip-none"
     elif all($lines[]; has_prefix) then "entry"
     else "check-line" end),
    $node, .url, (.author.login // "ghost"), credit,
    (if ($lines | length) == 0 or (($lines | length) == 1 and ($lines[0] | is_none)) then .title
     else $lines | join("\n") end) ]
| @tsv
