#!/bin/bash
# Remove the Oracle container and its data volume so the next start builds a new database.
set -euo pipefail

if [[ "${1:-}" != "--yes" ]]; then
  echo "This deletes the local Oracle data volume and container." >&2
  echo "Run: scripts/reset-oracle.sh --yes" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
podman volume rm oracle-source-data >/dev/null 2>&1 || true
echo "Removed ${CONTAINER_NAME} and volume oracle-source-data."
echo "Run scripts/start-oracle.sh to create a new database and load HR."
