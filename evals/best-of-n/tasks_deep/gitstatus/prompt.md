Fix the porcelain status parser in `gitstatus.py`.

Bug report: "With `status.renames = copies` set, one copied file makes the whole git badge disappear: `parse` raises
ValueError on output like `C  copy.txt\0orig.txt\0 M other.txt\0`."

Contract. The entry format is the one in the module docstring, which is git's: an entry is a rename or copy when
either status column is `R` or `C`, and only then is it followed by its source path. An entry is conflicted exactly
when its XY is one of the unmerged codes; a conflicted entry counts only as conflicted, never as staged or unstaged.
Every other entry keeps today's meaning: X other than space is staged, Y other than space is unstaged, `??` is
untracked, `!!` is ignored, and `renamed` counts the entries that carry a source path. Paths are returned exactly as
git wrote them.
