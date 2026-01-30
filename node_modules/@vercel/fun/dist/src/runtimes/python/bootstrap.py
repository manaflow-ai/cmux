# Parts of this runtime based off of:
# https://gist.github.com/avoidik/78ddc7854c7b88607f7cf56db3e591e5

import os
import sys
import json
import importlib

is_python_3 = sys.version_info > (3, 0)

if is_python_3:
    import urllib.request
else:
    import urllib2


class LambdaRequest:
    def __init__(self, path, data=None):
        req = None
        runtime_path = '/2018-06-01/runtime/'
        url = (
            'http://'
            + os.environ.get(
                'AWS_LAMBDA_RUNTIME_API', '127.0.0.1:3000'
            )
            + runtime_path
            + path
        )

        if is_python_3:
            req = urllib.request.urlopen(url, data)
        else:
            req = urllib2.urlopen(url, data)

        info = req.info()
        body = req.read()

        if is_python_3:
            body = body.decode(encoding='UTF-8')

        self.status_code = req.getcode()
        self.body = body
        self.info = info

    def get_header(self, name):
        if is_python_3:
            return self.info.get(name)
        else:
            return self.info.getheader(name)

    def get_json_body(self):
        return json.loads(self.body)


def lambda_runtime_next_invocation():
    res = LambdaRequest('invocation/next')

    if res.status_code != 200:
        raise Exception(
            'Unexpected /invocation/next response: '
            + res.body
        )

    x_amzn_trace_id = res.get_header('Lambda-Runtime-Trace-Id')
    if x_amzn_trace_id != None:
            os.environ['_X_AMZN_TRACE_ID'] = x_amzn_trace_id
    elif '_X_AMZN_TRACE_ID' in os.environ:
        del os.environ['_X_AMZN_TRACE_ID']

    aws_request_id = res.get_header('Lambda-Runtime-Aws-Request-Id')

    context = {
        # TODO: fill this out
        'aws_request_id': aws_request_id
    }

    event = res.get_json_body()

    return (event, context)


def lambda_runtime_invoke_response(result, context):
    body = json.dumps(result, separators=(',', ':')).encode(
        encoding='UTF-8'
    )
    res = LambdaRequest(
        'invocation/'
        + context['aws_request_id']
        + '/response',
        body,
    )
    if res.status_code != 202:
        raise Exception(
            'Unexpected /invocation/response response: '
            + res.body
        )


def lambda_runtime_invoke_error(err, context):
    body = json.dumps(err, separators=(',', ':')).encode(
        encoding='UTF-8'
    )
    res = LambdaRequest(
        'invocation/'
        + context['aws_request_id']
        + '/error',
        body,
    )


def lambda_runtime_get_handler():
    (module_name, handler_name) = os.environ['_HANDLER'].split('.')
    mod = importlib.import_module(module_name)
    # TODO: invoke `__init__`?
    return getattr(mod, handler_name)


def lambda_runtime_main():
    if not is_python_3:
        reload(sys)
        sys.setdefaultencoding('utf-8')

    sys.path.insert(
        0, os.environ.get('LAMBDA_TASK_ROOT', '/var/task')
    )

    fn = lambda_runtime_get_handler()

    while True:
        (event, context) = lambda_runtime_next_invocation()
        # print(event)
        # print(context)
        result = None
        try:
            result = fn(event, context)
        except:
            err = str(sys.exc_info()[0])
            print(err)
            lambda_runtime_invoke_error(
                {'error': err}, context
            )
        else:
            lambda_runtime_invoke_response(result, context)


if __name__ == '__main__':
    lambda_runtime_main()
