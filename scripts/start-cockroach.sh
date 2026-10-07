#!/bin/bash
# Start a three-node insecure CockroachDB cluster and publish it on this Mac.
#
# Usage: scripts/start-cockroach.sh
# SQL:   postgresql://root@127.0.0.1:26257/defaultdb?sslmode=disable
# Admin: http://127.0.0.1:8080
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

IMAGE="${CRDB_IMAGE:-docker.io/cockroachdb/cockroach:v26.2.3}"
NETWORK="${CRDB_NETWORK:-crdb-net}"
SQL_PORT="${CRDB_SQL_PORT:-26257}"
HTTP_PORT="${CRDB_HTTP_PORT:-8080}"

if ! podman network exists "${NETWORK}"; then
  podman network create "${NETWORK}"
fi

podman pull "${IMAGE}"

for n in 1 2 3; do
  name="crdb${n}"
  if podman container exists "${name}"; then
    echo "Starting existing container ${name}"
    podman start "${name}"
    continue
  fi

  publish=()
  if [[ "${n}" -eq 1 ]]; then
    if nc -z -G 2 127.0.0.1 "${SQL_PORT}" >/dev/null 2>&1; then
      echo "Port ${SQL_PORT} is already in use on this Mac." >&2
      exit 1
    fi
    if nc -z -G 2 127.0.0.1 "${HTTP_PORT}" >/dev/null 2>&1; then
      echo "Port ${HTTP_PORT} is already in use on this Mac." >&2
      exit 1
    fi
    publish=(--publish "${SQL_PORT}:26257" --publish "${HTTP_PORT}:8080")
  else
    host_sql=$((SQL_PORT + n - 1))
    host_http=$((HTTP_PORT + n - 1))
    publish=(--publish "${host_sql}:26257" --publish "${host_http}:8080")
  fi

  echo "Creating ${name} on ${NETWORK}"
  podman run -d \
    --name "${name}" \
    --hostname "${name}" \
    --network "${NETWORK}" \
    "${publish[@]}" \
    --volume "${name}-data:/cockroach/cockroach-data" \
    "${IMAGE}" \
    start \
    --insecure \
    --listen-addr=":26258" \
    --advertise-addr="${name}:26258" \
    --sql-addr=":26257" \
    --advertise-sql-addr="${name}:26257" \
    --http-addr=":8080" \
    --join="crdb1:26258,crdb2:26258,crdb3:26258" \
    --cache="256MiB" \
    --max-sql-memory="256MiB"
done

echo "Waiting for the nodes, then initializing the cluster if needed."
ready=0
for _ in $(seq 1 60); do
  if podman exec crdb1 ./cockroach node status --insecure --host=crdb1:26258 >/dev/null 2>&1; then
    ready=1
    break
  fi
  if podman exec crdb1 ./cockroach init --insecure --host=crdb1:26258 >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "${ready}" -ne 1 ]]; then
  echo "The cluster did not become ready. Check: podman logs crdb1" >&2
  exit 1
fi

echo "Waiting for SQL on this Mac at 127.0.0.1:${SQL_PORT}"
sql_ready=0
for _ in $(seq 1 60); do
  if cockroach sql --insecure --host="127.0.0.1:${SQL_PORT}" -e "SELECT 1" >/dev/null 2>&1; then
    sql_ready=1
    break
  fi
  sleep 2
done
if [[ "${sql_ready}" -ne 1 ]]; then
  echo "127.0.0.1:${SQL_PORT} is not accepting SQL. Check: podman logs crdb1" >&2
  exit 1
fi

if ! nc -z -G 5 127.0.0.1 "${SQL_PORT}"; then
  echo "SQL port ${SQL_PORT} is not reachable from this Mac." >&2
  exit 1
fi

cat <<EOF

CockroachDB is ready for MOLT on this Mac.

  Nodes:    crdb1, crdb2, crdb3
  SQL:      postgresql://root@127.0.0.1:${SQL_PORT}/defaultdb?sslmode=disable
  Node 2:   127.0.0.1:$((SQL_PORT + 1))
  Node 3:   127.0.0.1:$((SQL_PORT + 2))
  Admin UI: http://127.0.0.1:${HTTP_PORT}
  Database: defaultdb

Apply the HR schema with: scripts/create-crdb-schema.sh
The cluster is insecure and is published on this Mac. Oracle remains at 127.0.0.1:1521.
EOF
