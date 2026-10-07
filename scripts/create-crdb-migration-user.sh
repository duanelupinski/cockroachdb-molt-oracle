#!/bin/bash
# Create the MOLT Fetch user on the CockroachDB target.
#
# Privileges follow the classic bulk load guide for a manually created
# schema and the default IMPORT INTO load mode:
# https://docs.cockroachlabs.com/docs/molt/classic-bulk-load-oracle#create-the-sql-user
#
# Usage: scripts/create-crdb-migration-user.sh
# Requires the cluster from scripts/start-cockroach.sh and the schema from
# scripts/create-crdb-schema.sh. The cluster is insecure, so the user is
# created without a password.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

SQL_PORT="${CRDB_SQL_PORT:-26257}"
SQL_HOST="${CRDB_SQL_HOST:-127.0.0.1}"
CRDB_DATABASE="${CRDB_DATABASE:-defaultdb}"
CRDB_MIGRATION_USER="${CRDB_MIGRATION_USER:-crdb_user}"
CRDB_MIGRATION_SCHEMA="${CRDB_MIGRATION_SCHEMA:-HR}"

if [[ ! "${CRDB_DATABASE}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "CRDB_DATABASE must be an unquoted database name." >&2
  exit 1
fi
if [[ ! "${CRDB_MIGRATION_USER}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "CRDB_MIGRATION_USER must be an unquoted SQL user name." >&2
  exit 1
fi
if [[ ! "${CRDB_MIGRATION_SCHEMA}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "CRDB_MIGRATION_SCHEMA must be a schema name without quotes." >&2
  exit 1
fi

if ! cockroach sql --insecure --host="${SQL_HOST}:${SQL_PORT}" -e "SELECT 1" >/dev/null 2>&1; then
  echo "CockroachDB is not accepting SQL at ${SQL_HOST}:${SQL_PORT}. Start it with scripts/start-cockroach.sh" >&2
  exit 1
fi

schema_present="$(cockroach sql --insecure --host="${SQL_HOST}:${SQL_PORT}" --database="${CRDB_DATABASE}" --format=tsv -e "SELECT count(*) FROM information_schema.schemata WHERE catalog_name = '${CRDB_DATABASE}' AND schema_name = '${CRDB_MIGRATION_SCHEMA}'")"
if [[ "${schema_present##*$'\n'}" != "1" ]]; then
  echo "Schema \"${CRDB_MIGRATION_SCHEMA}\" is not in ${CRDB_DATABASE}. Apply it with scripts/create-crdb-schema.sh first." >&2
  exit 1
fi

echo "Creating ${CRDB_MIGRATION_USER} on ${SQL_HOST}:${SQL_PORT}/${CRDB_DATABASE}."

cockroach sql --insecure --host="${SQL_HOST}:${SQL_PORT}" --database="${CRDB_DATABASE}" <<SQL
CREATE USER IF NOT EXISTS ${CRDB_MIGRATION_USER};
ALTER ROLE ${CRDB_MIGRATION_USER} SET statement_timeout = '0s';

GRANT ALL ON DATABASE ${CRDB_DATABASE} TO ${CRDB_MIGRATION_USER};
GRANT SYSTEM MODIFYCLUSTERSETTING TO ${CRDB_MIGRATION_USER};

GRANT USAGE ON SCHEMA "${CRDB_MIGRATION_SCHEMA}" TO ${CRDB_MIGRATION_USER};
GRANT USAGE ON SCHEMA public TO ${CRDB_MIGRATION_USER};
GRANT CREATE ON SCHEMA "${CRDB_MIGRATION_SCHEMA}" TO ${CRDB_MIGRATION_USER};
GRANT CREATE ON SCHEMA public TO ${CRDB_MIGRATION_USER};

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "${CRDB_MIGRATION_SCHEMA}" TO ${CRDB_MIGRATION_USER};
GRANT SELECT, INSERT, DROP ON ALL TABLES IN SCHEMA "${CRDB_MIGRATION_SCHEMA}" TO ${CRDB_MIGRATION_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA "${CRDB_MIGRATION_SCHEMA}" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${CRDB_MIGRATION_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA "${CRDB_MIGRATION_SCHEMA}" GRANT SELECT, INSERT, DROP ON TABLES TO ${CRDB_MIGRATION_USER};

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${CRDB_MIGRATION_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${CRDB_MIGRATION_USER};
SQL

echo "User ${CRDB_MIGRATION_USER} is ready."
echo "Target: postgresql://${CRDB_MIGRATION_USER}@${SQL_HOST}:${SQL_PORT}/${CRDB_DATABASE}?sslmode=disable"
