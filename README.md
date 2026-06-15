# knative-freezer-plugin

A custom Knative queue-proxy that automatically freezes idle serverless containers using CRIU checkpoint/restore and thaws them on incoming requests.

This is the **queue-proxy plugin** component. It works together with the [container-freezer-criu](https://github.com/ATNoG/container-freezer) daemon, which performs the actual CRIU checkpoint/restore operations.

## How It Works

The plugin is compiled into a custom Knative queue-proxy binary that replaces the stock one cluster-wide. It uses Knative's [QPOption plugin interface](https://github.com/knative-extensions/security-guard) to intercept requests.

```
                    incoming request
                         │
                         ▼
┌─────────────────────────────────────────────┐
│  Queue-Proxy (with freezer plugin)          │
│                                              │
│  1. ApproveRequest() intercepts request      │
│  2. If container is frozen:                  │
│     a. Call daemon "resume" (CRIU restore)   │
│     b. Poll app port until ready             │
│     c. Forward request to app                │
│  3. Reset idle timer                         │
│                                              │
│  Background freeze loop:                     │
│  - Check idle timeout every 5s               │
│  - If idle > 30s: call daemon "pause"        │
│    (CRIU checkpoint → kill → free RAM)       │
└──────────────────────┬──────────────────────┘
                       │ HTTP POST
                       ▼
┌─────────────────────────────────────────────┐
│  Freeze Daemon (container-freezer-criu)     │
│  DaemonSet on each node, port 9696          │
│  pause  → containerd → criu dump            │
│  resume → containerd → criu restore         │
└─────────────────────────────────────────────┘
```

### Freeze/Thaw Lifecycle

1. **Request arrives** → `ApproveRequest()` resets the idle timer. If the container was frozen, it calls the daemon to restore it and waits for the app port to accept connections before forwarding.
2. **No requests for 30s** → the background `freezeLoop` calls the daemon to checkpoint the container. CRIU dumps full process state to disk and kills the process, freeing RAM.
3. **Next request arrives** → triggers restore (~641ms), then the request is forwarded transparently. The caller sees a slightly slower response for that first request, but no error.
4. **Shutdown** → if the container is frozen when the queue-proxy shuts down, it restores it first.

## Prerequisites

- [container-freezer-criu](https://github.com/ATNoG/container-freezer) daemon deployed on the cluster
- Knative Serving installed
- Docker buildx with a builder named `mec-builder`

## Installation

### 1. Build and push the custom queue-proxy

```bash
./build.sh          # pushes ghcr.io/pmacoutinho/freezer-queue-proxy:latest (linux/arm64)
./build.sh v1.0.0   # or with a specific tag
```

> To build for amd64, edit `build.sh` and change `--platform linux/arm64` to `--platform linux/amd64`.

### 2. Patch Knative to use the custom queue-proxy

```bash
./patch.sh
```

This does two things:
1. Sets `queue-sidecar-image` in `config-deployment` to the custom image
2. Enables `queueproxy.mount-podinfo` in `config-features` (required for the plugin to read pod annotations)

Verify:
```bash
kubectl get configmap config-deployment -n knative-serving \
  -o jsonpath='{.data.queue-sidecar-image}'
# → ghcr.io/pmacoutinho/freezer-queue-proxy:latest

kubectl get configmap config-features -n knative-serving \
  -o jsonpath='{.data.queueproxy\.mount-podinfo}'
# → enabled
```

### 3. Restart existing serving pods

Knative only injects the new queue-proxy into **new** pods. Restart existing ones:

```bash
kubectl rollout restart deployment -n default
kubectl rollout status deployment -n default --timeout=60s
```

### 4. Activate on a Knative Service

The plugin only activates for services with the annotation `qpoption.knative.dev/freezer-activate=enable`:

```bash
kubectl patch ksvc <service-name> --type merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"qpoption.knative.dev/freezer-activate":"enable"}}}}}'
```

Verify the plugin is active:
```bash
kubectl logs -l serving.knative.dev/service=<service-name> \
  -c queue-proxy --tail=20 | grep -i freez
# → "Freezer plug initializing for <namespace>/<pod-name>"
```

## Configuration

The plugin reads its configuration from environment variables, which are automatically available in the queue-proxy container:

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST_IP` | (required) | Node IP where the freeze daemon listens |
| `SERVING_POD` | (required) | Pod name (set by Knative) |
| `SERVING_NAMESPACE` | (required) | Namespace (set by Knative) |
| `USER_PORT` | `8080` | App container port to poll for readiness |
| `FREEZER_PORT` | `9696` | Freeze daemon host port |
| `FREEZER_IDLE_TIMEOUT_SECONDS` | `30` | Seconds of idle before freezing |
| `FREEZER_API_KEY` | (optional) | Bearer token for daemon authentication |

`HOST_IP`, `SERVING_POD`, and `SERVING_NAMESPACE` are automatically set by Knative Serving — no manual configuration needed.

## Project Structure

```
cmd/queue/         # Queue-proxy entry point (imports freezer plugin via blank import)
pkg/freezer/       # Plugin implementation (QPOption interface)
  plug.go          # Freeze loop, thaw-on-request, daemon HTTP calls
build.sh           # Docker buildx build + push
patch.sh           # Patch Knative configmaps to use this queue-proxy
Dockerfile         # Multi-stage build (Go 1.24 → distroless)
```

## Related

- [container-freezer-criu](https://github.com/ATNoG/container-freezer) — the CRIU checkpoint/restore daemon (companion component)
- [knative-extensions/security-guard](https://github.com/knative-extensions/security-guard) — QPOption plugin interface used by this plugin

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
