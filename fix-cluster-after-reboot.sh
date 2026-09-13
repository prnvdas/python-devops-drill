#!/bin/bash
# Run this after any PC/WSL reboot if `kubectl get nodes` shows NotReady
# nodes that don't recover on their own within a minute or two.
#
# Root cause: kind nodes run their own nested containerd, which can come
# back as a *process* after an abrupt shutdown without actually being able
# to serve kubelet's requests (visible as "container runtime is down" /
# "context deadline exceeded" in `journalctl -u kubelet` inside the node).
# Restarting containerd inside the affected node(s) fixes it immediately.

set -e

echo "Checking node status..."
kubectl get nodes

for node in $(kubectl get nodes --no-headers -o custom-columns=":metadata.name"); do
  status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  if [ "$status" != "True" ]; then
    echo "Restarting containerd on stuck node: $node"
    docker exec "$node" systemctl restart containerd
  fi
done

echo "Waiting for all nodes to become Ready..."
until [ "$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | sort -u)" = "Ready" ]; do
  sleep 3
done

echo "All nodes Ready. Current pod status:"
kubectl get pods -A | grep -v "Running\|Completed" || echo "Everything Running/Completed."

echo ""
echo "Site check:"
curl -s -o /dev/null -w "http://pythonfordevops.local/ -> HTTP %{http_code}\n" -H "Host: pythonfordevops.local" http://localhost/
