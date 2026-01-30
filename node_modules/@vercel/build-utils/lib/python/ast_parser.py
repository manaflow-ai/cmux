import sys
import ast


def contains_app_or_handler(file_path: str) -> bool:
    """
    Check if a Python file contains or exports:
    - A top-level 'app' callable (e.g., Flask, FastAPI, Sanic apps)
    - A top-level 'handler' class (e.g., BaseHTTPRequestHandler subclass)
    """
    with open(file_path, "r") as file:
        code = file.read()

    try:
        tree = ast.parse(code)
    except SyntaxError:
        return False

    for node in ast.iter_child_nodes(tree):
        # Check for top-level assignment to 'app'
        # e.g., app = Sanic() or app = Flask(__name__) or app = create_app()
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == "app":
                    return True

        # Check for annotated assignment to 'app'
        # e.g., app: Sanic = Sanic()
        if isinstance(node, ast.AnnAssign):
            if isinstance(node.target, ast.Name) and node.target.id == "app":
                return True

        # Check for function named 'app'
        # e.g., def app(environ, start_response): ...
        if isinstance(node, ast.FunctionDef) and node.name == "app":
            return True

        # Check for async function named 'app'
        # e.g., async def app(scope, receive, send): ...
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "app":
            return True

        # Check for import of 'app'
        # e.g., from server import app
        # e.g., from server import application as app
        if isinstance(node, ast.ImportFrom):
            for alias in node.names:
                # alias.asname is the 'as' name, alias.name is the original name
                # If aliased, check asname; otherwise check the original name
                imported_as = alias.asname if alias.asname else alias.name
                if imported_as == "app":
                    return True

        # Check for top-level class named 'handler'
        # e.g., class handler(BaseHTTPRequestHandler):
        if isinstance(node, ast.ClassDef) and node.name.lower() == "handler":
            return True

    return False


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python ast_parser.py <file_path>")
        sys.exit(1)

    file_path = sys.argv[1]
    result = contains_app_or_handler(file_path)

    # Exit with 0 if found, 1 if not found
    sys.exit(0 if result else 1)

