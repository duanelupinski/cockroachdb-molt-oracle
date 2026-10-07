#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

if podman container exists "${CONTAINER_NAME}"; then
  podman stop "${CONTAINER_NAME}"
  echo "Stopped ${CONTAINER_NAME}. The data volume was kept."
else
  echo "Container ${CONTAINER_NAME} does not exist."
fi
