#!/bin/bash
# Runs automatically at WSL boot (via systemd, see wsl-boot-recovery.service).
# Nothing that runs as a plain background process (nohup, disown, etc.) can
# survive a PC reboot, because the whole WSL VM — including PID 1 itself —
# is destroyed and recreated. Only a systemd unit re-runs automatically.
#
# This script:
#   1. waits for Docker to be ready
#   2. makes sure every kind node container is actually running
#   3. detects and fixes the "containerd came back but is unresponsive"
#      issue that can follow an abrupt host reboot
#   4. re-establishes the ArgoCD port-forward (the app itself needs no
#      port-forward at all — it's reachable via the Ingress controller's
#      published Docker ports, which persist on their own)

set -u
LOG=/tmp/wsl-boot-recovery.log
exec > >(tee -a "$LOG") 2>&1
echo "=== wsl-boot-recovery run at $(date) ==="

echo "Waiting for Docker..."
for i in $(seq 1 60); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done

echo "Ensuring kind node containers are running..."
for c in cka-lab-control-plane cka-lab-worker cka-lab-worker2; do
  status=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
  if [ "$status" = "exited" ] || [ "$status" = "created" ]; then
    echo "Starting $c ($status)..."
    docker start "$c"
  elif [ "$status" = "missing" ]; then
    echo "WARNING: $c does not exist. Cluster may need to be recreated with 'kind create cluster --config kind-cluster.yaml'."
  fi
done

echo "Waiting for kubectl to reach the API server..."
for i in $(seq 1 30); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 2
done

echo "Checking for stuck containerd on any node..."
for node in $(kubectl get nodes --no-headers -o custom-columns=":metadata.name" 2>/dev/null); do
  ready=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$ready" != "True" ]; then
    echo "Node $node not Ready — restarting its containerd..."
    docker exec "$node" systemctl restart containerd 2>/dev/null
  fi
done

echo "Waiting for all nodes to become Ready (up to 2 minutes)..."
for i in $(seq 1 40); do
  states=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | sort -u)
  [ "$states" = "Ready" ] && break
  sleep 3
done
kubectl get nodes 2>&1

echo "Re-establishing ArgoCD port-forward..."
pkill -f "port-forward svc/argocd-server" 2>/dev/null
sleep 1
nohup kubectl port-forward svc/argocd-server -n argocd 8081:443 >/tmp/argocd-pf.log 2>&1 &
disown

sleep 2
echo "Final check:"
curl -s -o /dev/null -w "App  (http://localhost/)        -> HTTP %{http_code}\n" http://localhost/
curl -sk -o /dev/null -w "ArgoCD (https://127.0.0.1:8081/) -> HTTP %{http_code}\n" https://127.0.0.1:8081/
echo "=== done ==="
