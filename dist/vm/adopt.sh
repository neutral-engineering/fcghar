#!/usr/bin/env bash
# Register the runner with a GitHub repo and start gha.service.
# Usage: PROJECT=owner/repo TOKEN=<registration token> ./adopt.sh
#  (or:  URL=https://github.com/owner/repo TOKEN=<token> ./adopt.sh)
#
# The token is short-lived (~1h). Get one from:
#   github.com/<owner>/<repo>/settings/actions/runners/new
# (or via the API: POST /repos/<owner>/<repo>/actions/runners/registration-token)
set -euo pipefail

cd "$(dirname "$0")"

: "${TOKEN:?usage: PROJECT=owner/repo TOKEN=<token> $0}"
if [ -z "${URL:-}" ]; then
    : "${PROJECT:?usage: PROJECT=owner/repo TOKEN=<token> $0}"
    URL="https://github.com/$PROJECT"
fi

SLOT="${SLOT:-0}"
VM_IP="${VM_IP:-192.168.43.$((10 + SLOT))}"
RUNNER_NAME="${RUNNER_NAME:-fcghar-${HOSTNAME%%.*}-$SLOT}"
RUNNER_LABELS="${RUNNER_LABELS:-fcghar,firecracker}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

echo ">> waiting for sshd on $VM_IP"
for _ in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "root@$VM_IP" true 2>/dev/null; then
        break
    fi
    sleep 1
done
ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "root@$VM_IP" true \
    || { echo "error: sshd never came up at $VM_IP" >&2; exit 1; }

echo ">> running config.sh as gha (url=$URL, name=$RUNNER_NAME)"
# Pass values as positional args — sudo strips env, so heredoc env-prefix
# wouldn't survive into the inner `sudo -u gha bash -c`.
ssh "${SSH_OPTS[@]}" "root@$VM_IP" \
    bash -s -- "$URL" "$TOKEN" "$RUNNER_NAME" "$RUNNER_LABELS" <<'REMOTE'
set -euo pipefail
URL="$1"; TOKEN="$2"; NAME="$3"; LABELS="$4"
cd /home/gha/runner
if [ -f .runner ]; then
    echo "   already configured — removing old registration"
    sudo -u gha -- ./config.sh remove --token "$TOKEN" || true
fi
sudo -u gha -- ./config.sh \
    --unattended \
    --url "$URL" \
    --token "$TOKEN" \
    --name "$NAME" \
    --labels "$LABELS" \
    --replace
systemctl enable --now gha.service
systemctl --no-pager status gha.service --lines=0 || true
REMOTE

echo
echo "ok. Runner registered. Tail logs with: journalctl -u gha.service -f (over ssh)"
