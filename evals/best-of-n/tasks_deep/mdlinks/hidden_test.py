from mdlinks import all_urls, code_ranges, find_autolinks, find_images, find_links, rewrite_links

ABS = lambda u: u if "://" in u else "https://x.test/" + u


def test_reported_fenced_block_not_rewritten():
    md = "See [guide](docs/guide.md).\n\n```sh\ncurl [docs](docs/guide.md)\n```\n"
    out = rewrite_links(md, ABS)
    assert out == "See [guide](https://x.test/docs/guide.md).\n\n```sh\ncurl [docs](docs/guide.md)\n```\n"


def test_rewrite_skips_spans_and_images_are_rewritten():
    md = "a `[x](y)` b ![pic](img.png) [t](u \"title\")"
    assert rewrite_links(md, ABS) == "a `[x](y)` b ![pic](https://x.test/img.png) [t](https://x.test/u \"title\")"


def test_tilde_fences():
    md = "~~~\n[in](code) <https://in.code>\n~~~\n[out](yes)\n"
    assert find_links(md) == [("out", "yes")]
    assert find_autolinks(md) == []
    assert rewrite_links(md, ABS) == "~~~\n[in](code) <https://in.code>\n~~~\n[out](https://x.test/yes)\n"


def test_fence_closes_only_on_matching_fence():
    md = "````md\n```\n[still](code)\n```\n````\n[out](yes)\n"
    assert find_links(md) == [("out", "yes")]
    md = "```\n~~~\n[still](code)\n```\n[out](yes)"
    assert find_links(md) == [("out", "yes")]
    md = "```\n[a](b)\n``` not a close\n[c](d)\n"
    assert find_links(md) == []
    assert find_links("```\n[never](closed)\n") == []


def test_multi_backtick_code_spans():
    md = "use ``[a](b) ` [c](d)`` then [e](f) and ```x``` [g](h)"
    assert find_links(md) == [("e", "f"), ("g", "h")]
    md = "``not closed [x](y)` and `[z](w)`"
    assert find_links(md) == [("x", "y"), ("z", "w")]  # `` is unmatched; the code span is "` and `"
    assert find_links("`a`` [x](y) ``b` [z](w)") == [("z", "w")]
    assert find_images("`` ![i](j.png) `` ![k](l.png)") == [("k", "l.png")]


def test_code_ranges_exact():
    md = "a ``b`c`` d\n~~~~\nx\n~~~~\ne `f`"
    ranges = code_ranges(md)
    assert [md[s:e] for s, e in ranges] == ["``b`c``", "~~~~\nx\n~~~~\n", "`f`"]
    assert code_ranges("no code here [a](b)") == []


def test_all_urls_skip_all_code():
    md = "[a](1) `[b](2)` ``<https://3>`` <https://4>\n~~~\n![c](5)\n~~~\n![d](6) [a](1)"
    assert all_urls(md) == ["1", "https://4", "6"]


def test_regressions_outside_code():
    md = "[one](http://a) ![img](b.png) <mailto:x@y.z> [two](c \"T\") [bad link](has space)\n```\n```\n[three](d)"
    assert find_links(md) == [("one", "http://a"), ("two", "c"), ("three", "d")]
    assert find_images(md) == [("img", "b.png")]
    assert find_autolinks(md) == ["mailto:x@y.z"]
    assert rewrite_links("[a](b) [c](d)", lambda u: u.upper()) == "[a](B) [c](D)"
    assert find_links("unmatched ` tick [a](b)") == [("a", "b")]
