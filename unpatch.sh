#!/bin/bash
# Reverts the Knative queue-proxy to the stock image, undoing what patch.sh did.
#
# Usage:
#   ./unpatch.sh                    # restore default queue-proxy
#   ./unpatch.sh --restart          # also restart all serving pods to pick it up
set -e

# The default image shipped with the Knative installation on this cluster.
# Taken from config-deployment's last-applied-configuration.
DEFAULT_IMAGE="gcr.io/knative-releases/knative.dev/serving/cmd/queue@sha256:f155665f3a5faad07ab4dbe7e010790383936e5864344ccca7f40bbb2fa0f30b"

kubectl patch configmap config-deployment -n knative-serving \
  --type merge \
  -p "{\"data\":{\"queue-sidecar-image\":\"${DEFAULT_IMAGE}\"}}"

kubectl patch configmap config-features -n knative-serving \
  --type merge \
  -p '{"data":{"queueproxy.mount-podinfo":"disabled"}}'

echo "Done. Queue-proxy reverted to stock Knative image."

if [[ "$1" == "--restart" ]]; then
    echo "Restarting all serving deployments in default namespace..."
    kubectl rollout restart deployment -n default -l serving.knative.dev/service
else
    echo "Restart existing serving pods to pick up the change:"
    echo "  kubectl rollout restart deployment -n <your-namespace>"
fi
