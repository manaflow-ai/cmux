Fix the column layout in `tablefmt.py`, the table renderer behind `cmux ls` and `cmux agents`.

Bug report: "`cmux agents` lines up fine until somebody names a workspace in Japanese. With a row named
`日本語の作業`, the STATUS column on that row starts four cells to the right of the STATUS header, and every column
after it is pushed over too."

Contract: a column's width, a cell's width and every width argument are terminal cells as `text_width` counts them
(wide and fullwidth characters take 2, combining marks 0), never code points. In a rendered table every line places
each column at the same cell offset: before stripping trailing spaces each cell takes exactly its column's width,
padded per its alignment. A cell wider than its column is shown as its longest prefix that, followed by `…`, fits
the column; if a wide character does not fit, the cell is padded to the column width like any short cell. Behavior
that does not depend on how width is measured (alignment rules, None cells, the rule line, stripped trailing spaces,
`max_width`) stays as it is.
