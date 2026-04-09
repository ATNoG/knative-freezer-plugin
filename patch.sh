#!/bin/bash
# Patches the Knative queue-proxy to use the freezer plugin image.
#
# Usage:
#   ./patch.sh                     # use "latest" tag
#   ./patch.sh v1.2                # use a specific tag
#   ./patch.sh --restart           # also restart all serving pods to pick it up
#   ./patch.sh v1.2 --restart      # specific tag + restart
set -e

REGISTRY=ghcr.io/pmacoutinho
TAG="latest"
RESTART=false

for arg in "$@"; do
    case "$arg" in
        --restart) RESTART=true ;;
        *)         TAG="$arg" ;;
    esac
done

kubectl patch configmap config-deployment -n knative-serving \
  --type merge \
  -p "{\"data\":{\"queue-sidecar-image\":\"${REGISTRY}/freezer-queue-proxy:${TAG}\"}}"

kubectl patch configmap config-features -n knative-serving \
  --type merge \
  -p '{"data":{"queueproxy.mount-podinfo":"enabled"}}'

echo "Done. Queue-proxy set to freezer plugin (tag: ${TAG})."

if [[ "$RESTART" == "true" ]]; then
    echo "Restarting all serving deployments in default namespace..."
    kubectl rollout restart deployment -n default -l serving.knative.dev/service
else
    echo "Restart existing serving pods to pick up the change:"
    echo "  kubectl rollout restart deployment -n <your-namespace>"
fi
