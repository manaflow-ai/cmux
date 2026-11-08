"""Drive a blocking browser operation and answer native dialogs on another socket."""

import time
from concurrent.futures import ThreadPoolExecutor

from cmux import cmux, cmuxError


def run_with_dialogs(socket_path, method, params, answers):
    def invoke():
        with cmux(socket_path) as page:
            return page._call(method, params)

    responses = []
    with ThreadPoolExecutor(max_workers=1) as pool:
        operation = pool.submit(invoke)
        with cmux(socket_path) as responder:
            for accept, text in answers:
                deadline = time.monotonic() + 4
                while True:
                    response_params = {"surface_id": params["surface_id"]}
                    if text is not None:
                        response_params["text"] = text
                    try:
                        response = responder._call(
                            "browser.dialog.accept" if accept else "browser.dialog.dismiss",
                            response_params,
                        )
                        responses.append(response)
                        break
                    except cmuxError as error:
                        if "not_found" not in str(error) or time.monotonic() >= deadline:
                            raise
                        time.sleep(0.02)
                        # The operation and responder intentionally race. Each
                        # request checks native state; no page evaluation can
                        # run here while WebKit waits for the answer.
        return operation.result(timeout=10), responses
