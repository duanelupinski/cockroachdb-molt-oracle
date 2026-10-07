#!/bin/bash
# Apply ddl/hr_crdb.sql to the CockroachDB cluster published on this Mac.
#
# Usage: scripts/create-crdb-schema.sh
# Requires scripts/start-cockroach.sh to have started the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

SQL_PORT="${CRDB_SQL_PORT:-26257}"
SQL_HOST="${CRDB_SQL_HOST:-127.0.0.1}"
SCHEMA_FILE="${REPO_ROOT}/ddl/hr_crdb.sql"

if [[ ! -f "${SCHEMA_FILE}" ]]; then
  echo "Missing ${SCHEMA_FILE}" >&2
  exit 1
fi

if ! cockroach sql --insecure --host="${SQL_HOST}:${SQL_PORT}" -e "SELECT 1" >/dev/null 2>&1; then
  echo "CockroachDB is not accepting SQL at ${SQL_HOST}:${SQL_PORT}. Start it with scripts/start-cockroach.sh" >&2
  exit 1
fi

echo "Applying ${SCHEMA_FILE} to ${SQL_HOST}:${SQL_PORT}/defaultdb"
cockroach sql --insecure --host="${SQL_HOST}:${SQL_PORT}" -f "${SCHEMA_FILE}"
echo "Applied the HR schema in defaultdb."
