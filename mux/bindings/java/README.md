# cmux-mux Java Client

Java 17 client for the cmux-mux Unix-socket JSON-lines protocol. The build is
javac-only and uses a small vendored JSON parser/serializer in the package.

## Build

```bash
cd mux/bindings/java
scripts/build.sh
java -cp out com.manaflow.cmux.mux.JsonTest
```

On a machine without a local JRE:

```bash
docker run --rm -v "$PWD":/w -w /w eclipse-temurin:17 bash -lc 'scripts/build.sh && java -cp out com.manaflow.cmux.mux.JsonTest'
```

## Usage

```java
try (MuxClient client = MuxClient.builder()
    .socketPath(System.getenv("CMUX_MUX_SOCKET"))
    .build()) {
    IdentifyResult info = client.identify();
    SurfaceResult surface = client.newWorkspace(
        NewWorkspaceRequest.builder().name("sdk-demo").cols(80).rows(24).build());
    client.send(surface.surface(), "echo hello\r");
    System.out.println(client.readScreen(surface.surface()).text());
}
```

## E2E

```bash
cd mux/bindings/java
CMUX_MUX_SOCKET=/path/to/session.sock scripts/build.sh
CMUX_MUX_SOCKET=/path/to/session.sock java -cp out com.manaflow.cmux.mux.E2e
```
