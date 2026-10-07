#!/bin/bash
# Prepare the CockroachDB target for a MOLT delta migration.
#
# Covers step 2 of the Oracle delta migration guide:
# https://docs.cockroachlabs.com/docs/molt/delta-migration-oracle#step-2-prepare-the-target-database
#
# Usage: scripts/prepare-crdb-target.sh
# Requires the cluster from scripts/start-cockroach.sh.
# The cluster is insecure, so the migration user has no password.
#
# Primary keys stay in place. Foreign keys, unique constraints, checks,
# non-key NOT NULL constraints, defaults, and secondary indexes are removed
# so the load is not blocked by them. Stored UUID columns stay.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

SQL_PORT="${CRDB_SQL_PORT:-26257}"
SQL_HOST="${CRDB_SQL_HOST:-127.0.0.1}"
CRDB_DATABASE="${CRDB_DATABASE:-defaultdb}"
CRDB_MIGRATION_USER="${CRDB_MIGRATION_USER:-crdb_user}"
CRDB_MIGRATION_SCHEMA="${CRDB_MIGRATION_SCHEMA:-HR}"
CRDB_GC_TTL_SECONDS="${CRDB_GC_TTL_SECONDS:-86400}"
SCHEMA_FILE="${REPO_ROOT}/ddl/hr_crdb.sql"

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
if [[ ! "${CRDB_GC_TTL_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "CRDB_GC_TTL_SECONDS must be a positive number of seconds." >&2
  exit 1
fi

crdb_sql() {
  cockroach sql --insecure --host="${SQL_HOST}:${SQL_PORT}" --database="${CRDB_DATABASE}" "$@"
}

if ! crdb_sql -e "SELECT 1" >/dev/null 2>&1; then
  echo "CockroachDB is not accepting SQL at ${SQL_HOST}:${SQL_PORT}. Start it with scripts/start-cockroach.sh" >&2
  exit 1
fi

schema_present="$(crdb_sql --format=tsv -e "SELECT count(*) FROM information_schema.schemata WHERE catalog_name = '${CRDB_DATABASE}' AND schema_name = '${CRDB_MIGRATION_SCHEMA}'")"
if [[ "${schema_present##*$'\n'}" != "1" ]]; then
  echo "Applying ${SCHEMA_FILE}"
  crdb_sql -f "${SCHEMA_FILE}"
else
  echo "Schema \"${CRDB_MIGRATION_SCHEMA}\" is already present."
fi

echo "Dropping non-primary-key constraints and secondary indexes in \"${CRDB_MIGRATION_SCHEMA}\"."

drop_sql=""
while IFS= read -r statement; do
  [[ -z "${statement}" ]] && continue
  printf '%s\n' "${statement};"
  drop_sql+="${statement};"$'\n'
done < <(crdb_sql --format=csv -e "
WITH pk_cols AS (
  SELECT kcu.table_name, kcu.column_name
  FROM information_schema.table_constraints AS tc
  JOIN information_schema.key_column_usage AS kcu
    ON kcu.constraint_schema = tc.constraint_schema
   AND kcu.constraint_name = tc.constraint_name
   AND kcu.table_name = tc.table_name
  WHERE tc.table_schema = '${CRDB_MIGRATION_SCHEMA}'
    AND tc.constraint_type = 'PRIMARY KEY'
)
SELECT stmt FROM (
  SELECT 1 AS ord, format('ALTER TABLE %I.%I DROP CONSTRAINT %I', '${CRDB_MIGRATION_SCHEMA}', tc.table_name, tc.constraint_name) AS stmt
  FROM information_schema.table_constraints AS tc
  WHERE tc.table_schema = '${CRDB_MIGRATION_SCHEMA}'
    AND tc.constraint_type IN ('FOREIGN KEY', 'UNIQUE')
  UNION ALL
  SELECT 2, format('ALTER TABLE %I.%I DROP CONSTRAINT %I', '${CRDB_MIGRATION_SCHEMA}', tc.table_name, tc.constraint_name)
  FROM information_schema.table_constraints AS tc
  JOIN information_schema.check_constraints AS cc
    ON cc.constraint_schema = tc.constraint_schema
   AND cc.constraint_name = tc.constraint_name
  WHERE tc.table_schema = '${CRDB_MIGRATION_SCHEMA}'
    AND tc.constraint_type = 'CHECK'
    AND cc.check_clause NOT LIKE '%IS NOT NULL'
  UNION ALL
  SELECT 3, format('ALTER TABLE %I.%I ALTER COLUMN %I DROP NOT NULL', '${CRDB_MIGRATION_SCHEMA}', c.table_name, c.column_name)
  FROM information_schema.columns AS c
  WHERE c.table_schema = '${CRDB_MIGRATION_SCHEMA}'
    AND c.is_nullable = 'NO'
    AND c.is_generated = 'NEVER'
    AND NOT EXISTS (
      SELECT 1 FROM pk_cols AS p
      WHERE p.table_name = c.table_name AND p.column_name = c.column_name
    )
  UNION ALL
  SELECT 4, format('ALTER TABLE %I.%I ALTER COLUMN %I DROP DEFAULT', '${CRDB_MIGRATION_SCHEMA}', c.table_name, c.column_name)
  FROM information_schema.columns AS c
  WHERE c.table_schema = '${CRDB_MIGRATION_SCHEMA}'
    AND c.column_default IS NOT NULL
    AND c.is_generated = 'NEVER'
  UNION ALL
  SELECT 5, format('DROP INDEX %I.%I', '${CRDB_MIGRATION_SCHEMA}', i.indexname)
  FROM pg_indexes AS i
  WHERE i.schemaname = '${CRDB_MIGRATION_SCHEMA}'
    AND NOT EXISTS (
      SELECT 1
      FROM information_schema.table_constraints AS tc
      WHERE tc.table_schema = '${CRDB_MIGRATION_SCHEMA}'
        AND tc.table_name = i.tablename
        AND tc.constraint_name = i.indexname
        AND tc.constraint_type IN ('PRIMARY KEY', 'UNIQUE')
    )
)
ORDER BY ord, stmt
" | python3 -c 'import csv,sys
rows = csv.reader(sys.stdin)
next(rows, None)
for row in rows:
    if row and row[0]:
        print(row[0])')

if [[ -z "${drop_sql}" ]]; then
  echo "No non-primary-key constraints or secondary indexes to drop."
else
  crdb_sql -e "${drop_sql}"
fi

echo "Creating ${CRDB_MIGRATION_USER} and setting the GC TTL to ${CRDB_GC_TTL_SECONDS}s."

crdb_sql <<SQL
CREATE USER IF NOT EXISTS ${CRDB_MIGRATION_USER};
ALTER ROLE ${CRDB_MIGRATION_USER} SET statement_timeout = '0s';
ALTER USER ${CRDB_MIGRATION_USER} CREATEDB;
GRANT admin TO ${CRDB_MIGRATION_USER};

GRANT ALL ON DATABASE ${CRDB_DATABASE} TO ${CRDB_MIGRATION_USER};
GRANT SYSTEM MODIFYCLUSTERSETTING TO ${CRDB_MIGRATION_USER};

GRANT USAGE ON SCHEMA "${CRDB_MIGRATION_SCHEMA}" TO ${CRDB_MIGRATION_USER};
GRANT USAGE ON SCHEMA public TO ${CRDB_MIGRATION_USER};
GRANT CREATE ON SCHEMA "${CRDB_MIGRATION_SCHEMA}" TO ${CRDB_MIGRATION_USER};
GRANT CREATE ON SCHEMA public TO ${CRDB_MIGRATION_USER};

GRANT SELECT, INSERT, UPDATE, DELETE, DROP ON ALL TABLES IN SCHEMA "${CRDB_MIGRATION_SCHEMA}" TO ${CRDB_MIGRATION_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA "${CRDB_MIGRATION_SCHEMA}" GRANT SELECT, INSERT, UPDATE, DELETE, DROP ON TABLES TO ${CRDB_MIGRATION_USER};

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${CRDB_MIGRATION_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${CRDB_MIGRATION_USER};

ALTER DATABASE ${CRDB_DATABASE} CONFIGURE ZONE USING gc.ttlseconds = ${CRDB_GC_TTL_SECONDS};
SQL

echo "Target ${SQL_HOST}:${SQL_PORT}/${CRDB_DATABASE} is prepared."
echo "User: postgresql://${CRDB_MIGRATION_USER}@${SQL_HOST}:${SQL_PORT}/${CRDB_DATABASE}?sslmode=disable"
