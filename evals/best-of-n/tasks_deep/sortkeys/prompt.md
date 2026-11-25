Fix `sortkeys.py`, the natural ordering used for file trees, tab titles and session lists.

Bug reports:
1. "`img2.png`, `IMG2.png` and `img02.png` come out in a different order every time the folder refreshes."
2. "Opening a build folder whose files carry long timestamp-and-hash names throws a ValueError."
3. "A folder of Arabic-titled chapters sorts strangely next to the numbered ones."
4. "The file tree takes seconds to sort a big `node_modules` listing."

Contract: the module docstring is the spec; follow every rule in it exactly. `natural_key` stays usable as a sort
key on its own. Sorting 50,000 names of about 25 characters must take under 1 s.
