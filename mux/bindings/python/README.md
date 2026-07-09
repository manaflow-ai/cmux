# cmux Python Client

Synchronous Python client for the cmux-mux Unix-socket JSON-lines protocol.

## Install

```bash
pip install cmux
```

## Usage

```python
import os

from cmux import CmuxClient

with CmuxClient(socket_path=os.environ["CMUX_MUX_SOCKET"]) as client:
    info = client.identify()
    surface = client.new_workspace(name="sdk-demo", cols=80, rows=24)
    client.send(surface.surface, text="echo hello\r")
    print(client.read_screen(surface.surface).text)
```
