#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

cd "${REPO_ROOT}"

if [[ ! "${ORACLE_PASSWORD}" =~ ^[A-Za-z][A-Za-z0-9_#]{7,}$ ]]; then
  echo "ORACLE_PASSWORD must start with a letter and use only letters, digits, underscore, or hash (8+ characters)." >&2
  exit 1
fi

echo "Building ${IMAGE_NAME}"
podman build -t "${IMAGE_NAME}" -f Containerfile .

if podman container exists "${CONTAINER_NAME}"; then
  echo "Starting existing container ${CONTAINER_NAME}"
  podman start "${CONTAINER_NAME}"
else
  if nc -z -G 2 127.0.0.1 "${ORACLE_PORT}" >/dev/null 2>&1; then
    echo "Port ${ORACLE_PORT} is already in use on this Mac." >&2
    exit 1
  fi

  echo "Creating ${CONTAINER_NAME} and publishing ${ORACLE_PORT}->1521 on this Mac"
  podman run -d \
    --name "${CONTAINER_NAME}" \
    --publish "${ORACLE_PORT}:1521" \
    --shm-size 1g \
    --env "ORACLE_PASSWORD=${ORACLE_PASSWORD}" \
    --env "HR_PASSWORD=${HR_PASSWORD}" \
    --env "HR_TABLESPACE=${HR_TABLESPACE}" \
    --volume oracle-source-data:/opt/oracle/oradata \
    --volume "${REPO_ROOT}/oracle/hr:/opt/oracle/hr:ro" \
    --volume "${REPO_ROOT}/oracle/init:/container-entrypoint-initdb.d:ro" \
    --health-cmd "healthcheck.sh" \
    --health-interval 15s \
    --health-timeout 10s \
    --health-retries 40 \
    --health-start-period 600s \
    "${IMAGE_NAME}"
fi

echo "Waiting for the HR schema. The first database build often takes several minutes."
ready=0
for _ in $(seq 1 120); do
  if podman exec "${CONTAINER_NAME}" \
      sqlplus -s / as sysdba @/opt/oracle/hr/check-hr.sql 2>/dev/null | grep -q 'HR_READY'; then
    ready=1
    break
  fi
  sleep 10
done

if [[ "${ready}" -ne 1 ]]; then
  echo "Oracle did not finish installing HR within 20 minutes. Check: podman logs ${CONTAINER_NAME}" >&2
  exit 1
fi

if nc -z -G 5 127.0.0.1 "${ORACLE_PORT}"; then
  echo "Listener is reachable from this Mac at 127.0.0.1:${ORACLE_PORT}."
else
  echo "HR is installed, but 127.0.0.1:${ORACLE_PORT} is not accepting connections yet." >&2
  exit 1
fi

cat <<EOF

Oracle source is ready for clients on this Mac.

  Host:          127.0.0.1
  Port:          ${ORACLE_PORT}
  Service:       ${ORACLE_SERVICE}
  HR user:       HR
  HR password:   value of HR_PASSWORD in .env
  JDBC:          jdbc:oracle:thin:@//127.0.0.1:${ORACLE_PORT}/${ORACLE_SERVICE}
  Container:     ${CONTAINER_NAME}

Reload the HR demo rows with: scripts/load-hr.sh
Follow the database build with: podman logs -f ${CONTAINER_NAME}
EOF
