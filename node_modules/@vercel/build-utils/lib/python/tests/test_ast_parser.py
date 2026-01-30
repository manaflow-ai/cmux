import unittest
import tempfile
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from ast_parser import contains_app_or_handler


class TestContainsAppOrHandler(unittest.TestCase):
    def _check(self, code: str) -> bool:
        """Helper to test code snippets without needing fixture files."""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write(code)
            f.flush()
            try:
                return contains_app_or_handler(f.name)
            finally:
                os.unlink(f.name)

    def test_flask_app(self):
        self.assertTrue(self._check("from flask import Flask\napp = Flask(__name__)"))

    def test_fastapi_app(self):
        self.assertTrue(self._check("from fastapi import FastAPI\napp = FastAPI()"))

    def test_sanic_app(self):
        self.assertTrue(self._check("from sanic import Sanic\napp = Sanic('app')"))

    def test_annotated_app(self):
        self.assertTrue(self._check("from fastapi import FastAPI\napp: FastAPI = FastAPI()"))

    def test_wsgi_function(self):
        self.assertTrue(self._check("def app(environ, start_response):\n    pass"))

    def test_asgi_function(self):
        self.assertTrue(self._check("async def app(scope, receive, send):\n    pass"))

    def test_imported_app(self):
        self.assertTrue(self._check("from server import app"))

    def test_imported_app_aliased(self):
        self.assertTrue(self._check("from server import application as app"))

    def test_handler_class(self):
        self.assertTrue(self._check("class Handler:\n    pass"))

    def test_handler_class_lowercase(self):
        self.assertTrue(self._check("class handler:\n    pass"))

    def test_no_app_or_handler(self):
        self.assertFalse(self._check("def hello():\n    return 'world'"))

    def test_app_in_function_not_toplevel(self):
        # app defined inside a function should NOT match
        self.assertFalse(self._check("def create():\n    app = Flask(__name__)\n    return app"))

    def test_syntax_error(self):
        self.assertFalse(self._check("def broken("))

    def test_empty_file(self):
        self.assertFalse(self._check(""))

    def test_only_comments(self):
        self.assertFalse(self._check("# just a comment\n# another comment"))


if __name__ == "__main__":
    unittest.main()

