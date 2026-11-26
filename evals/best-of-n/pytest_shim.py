"""The one helper the hidden tests use, so they run on a bare python3 with no pytest."""


def raises(exc, fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except exc:
        return
    except Exception as other:  # the wrong exception is a failure, with its name
        raise AssertionError(f"{fn.__name__}{args!r} raised {type(other).__name__}, not {exc.__name__}") from other
    raise AssertionError(f"{fn.__name__}{args!r} did not raise {exc.__name__}")
