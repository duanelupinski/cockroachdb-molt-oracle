#!/bin/bash
# Export schema-qualified HR table and secondary-index DDL for MOLT Convert.
#
# Usage: scripts/export-hr-ddl.sh
# Requires the Oracle container to be running (scripts/start-oracle.sh).
# Writes ddl/hr_oracle.sql. The CockroachDB schema is ddl/hr_crdb.sql.
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

REMOTE_DDL="/tmp/hr_ddl.sql"
LOCAL_DDL="${REPO_ROOT}/ddl/hr_oracle.sql"
mkdir -p "${REPO_ROOT}/ddl"

podman exec -i "${CONTAINER_NAME}" sqlplus -s / as sysdba <<SQL
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET LINESIZE 32767
SET LONG 1000000
SET LONGCHUNKSIZE 1000000
SET TRIMSPOOL ON
SET VERIFY OFF
SET TERMOUT OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE

ALTER SESSION SET CONTAINER = FREEPDB1;

BEGIN
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'PRETTY', TRUE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SQLTERMINATOR', TRUE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'EMIT_SCHEMA', TRUE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'STORAGE', FALSE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'TABLESPACE', FALSE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SEGMENT_ATTRIBUTES', FALSE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'CONSTRAINTS', TRUE);
  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'REF_CONSTRAINTS', TRUE);
END;
/

SPOOL ${REMOTE_DDL}
PROMPT /* tables */
SELECT DBMS_METADATA.GET_DDL('TABLE', table_name, 'HR')
  FROM all_tables
 WHERE owner = 'HR'
 ORDER BY table_name;

PROMPT /* secondary indexes */
SELECT DBMS_METADATA.GET_DDL('INDEX', i.index_name, i.owner)
  FROM all_indexes i
 WHERE i.owner = 'HR'
   AND NOT EXISTS (
         SELECT 1
           FROM all_constraints c
          WHERE c.owner = i.owner
            AND c.index_name = i.index_name
       )
 ORDER BY i.table_name, i.index_name;
SPOOL OFF
EXIT
SQL

podman cp "${CONTAINER_NAME}:${REMOTE_DDL}" "${LOCAL_DDL}"
podman exec "${CONTAINER_NAME}" rm -f "${REMOTE_DDL}"

# GET_DDL emits a separate CREATE UNIQUE INDEX when a primary key uses a
# pre-created index. Keep the constraint and drop that index statement so
# primary-key indexes are not scripted twice.
python3 - "${LOCAL_DDL}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r"[ \t]*CREATE UNIQUE INDEX\s+\"[^\"]+\"\.\"[^\"]+\"\s+ON\s+\"[^\"]+\"\.\"[^\"]+\"\s*\(.*?\n[ \t]*;\n?",
    "",
    text,
    flags=re.DOTALL,
)
text = re.sub(
    r"\n[ \t]*USING INDEX\s+\"[^\"]+\"\.\"[^\"]+\"[ \t]*",
    "\n  ",
    text,
)
# DBMS_METADATA quotes every identifier. Keep parentheses, and write
# schema, object, and column names without those double quotes.
text = text.replace('"', "")
path.write_text(text)
PY

echo "Wrote ${LOCAL_DDL}"
echo "CockroachDB schema is ${REPO_ROOT}/ddl/hr_crdb.sql"
