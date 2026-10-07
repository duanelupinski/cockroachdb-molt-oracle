#!/bin/bash
# Drop and reload the HR sample schema in the running Oracle source.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

if ! podman container exists "${CONTAINER_NAME}"; then
  echo "Container ${CONTAINER_NAME} does not exist. Start it with scripts/start-oracle.sh" >&2
  exit 1
fi

state="$(podman inspect -f '{{.State.Status}}' "${CONTAINER_NAME}")"
if [[ "${state}" != "running" ]]; then
  echo "Container ${CONTAINER_NAME} is ${state}. Start it with scripts/start-oracle.sh" >&2
  exit 1
fi

podman exec \
  -e "HR_PASSWORD=${HR_PASSWORD}" \
  -e "HR_TABLESPACE=${HR_TABLESPACE}" \
  "${CONTAINER_NAME}" \
  bash /opt/oracle/hr/install-hr.sh
