#!/bin/bash
# Create the MOLT user on the multitenant Oracle source.
#
# Oracle Database Free is a CDB. The common user (C##...) receives the
# multitenant grants from the classic bulk load guide and the LogMiner
# grants from the delta migration guide:
# https://docs.cockroachlabs.com/docs/molt/classic-bulk-load-oracle#create-migration-user-on-source-database
# https://docs.cockroachlabs.com/docs/molt/delta-migration-oracle#grant-logminer-privileges
#
# Usage: scripts/create-oracle-migration-user.sh
# Requires scripts/start-oracle.sh. Reads users and passwords from .env.
# The same user connects to the CDB service FREE and the PDB service FREEPDB1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

ORACLE_MIGRATION_USER="$(printf '%s' "${ORACLE_MIGRATION_USER:-C##MIGRATION_USER}" | tr '[:lower:]' '[:upper:]')"
ORACLE_MIGRATION_SCHEMA="$(printf '%s' "${ORACLE_MIGRATION_SCHEMA:-HR}" | tr '[:lower:]' '[:upper:]')"
ORACLE_MIGRATION_PASSWORD="${ORACLE_MIGRATION_PASSWORD:?Set ORACLE_MIGRATION_PASSWORD in .env}"
HR_TABLESPACE="${HR_TABLESPACE:-USERS}"

if [[ ! "${ORACLE_MIGRATION_USER}" =~ ^C##[A-Z][A-Z0-9_#$]*$ ]]; then
  echo "ORACLE_MIGRATION_USER must be a common user name starting with C##." >&2
  exit 1
fi
if [[ ! "${ORACLE_MIGRATION_SCHEMA}" =~ ^[A-Z][A-Z0-9_#$]*$ ]]; then
  echo "ORACLE_MIGRATION_SCHEMA must be an unquoted Oracle schema name." >&2
  exit 1
fi
if [[ ! "${ORACLE_MIGRATION_PASSWORD}" =~ ^[A-Za-z][A-Za-z0-9_#]{7,}$ ]]; then
  echo "ORACLE_MIGRATION_PASSWORD must start with a letter and use only letters, digits, underscore, or hash (8+ characters)." >&2
  exit 1
fi
if [[ ! "${HR_TABLESPACE}" =~ ^[A-Z][A-Z0-9_#$]*$ ]]; then
  echo "HR_TABLESPACE must be an unquoted Oracle tablespace name." >&2
  exit 1
fi

if ! podman container exists "${CONTAINER_NAME}"; then
  echo "Container ${CONTAINER_NAME} does not exist. Start it with scripts/start-oracle.sh" >&2
  exit 1
fi

state="$(podman inspect -f '{{.State.Status}}' "${CONTAINER_NAME}")"
if [[ "${state}" != "running" ]]; then
  echo "Container ${CONTAINER_NAME} is ${state}. Start it with scripts/start-oracle.sh" >&2
  exit 1
fi

echo "Creating common user ${ORACLE_MIGRATION_USER} for schema ${ORACLE_MIGRATION_SCHEMA}."

podman exec -i "${CONTAINER_NAME}" sqlplus -s / as sysdba <<SQL
SET ECHO OFF
SET FEEDBACK ON
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

ALTER SESSION SET CONTAINER = CDB\$ROOT;

DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM cdb_users
   WHERE username = '${ORACLE_MIGRATION_USER}'
     AND con_id = SYS_CONTEXT('USERENV', 'CON_ID');
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER ${ORACLE_MIGRATION_USER} IDENTIFIED BY "${ORACLE_MIGRATION_PASSWORD}" DEFAULT TABLESPACE ${HR_TABLESPACE} CONTAINER=ALL';
    DBMS_OUTPUT.PUT_LINE('Created ${ORACLE_MIGRATION_USER}.');
  ELSE
    EXECUTE IMMEDIATE 'ALTER USER ${ORACLE_MIGRATION_USER} IDENTIFIED BY "${ORACLE_MIGRATION_PASSWORD}" ACCOUNT UNLOCK CONTAINER=ALL';
    DBMS_OUTPUT.PUT_LINE('Updated password for existing ${ORACLE_MIGRATION_USER}.');
  END IF;
END;
/

-- CDB grants. MOLT uses this connection with --source-cdb.
GRANT CONNECT TO ${ORACLE_MIGRATION_USER};
GRANT CREATE SESSION TO ${ORACLE_MIGRATION_USER};
GRANT EXECUTE_CATALOG_ROLE TO ${ORACLE_MIGRATION_USER};
GRANT SELECT_CATALOG_ROLE TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON V_\$LOG TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON V_\$LOGFILE TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON V_\$LOGMNR_CONTENTS TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON V_\$ARCHIVED_LOG TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON V_\$DATABASE TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON V_\$LOG_HISTORY TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON ALL_USERS TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON DBA_USERS TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON DBA_OBJECTS TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON DBA_SYNONYMS TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON DBA_TABLES TO ${ORACLE_MIGRATION_USER};

-- LogMiner privileges. MOLT Replicator uses these on the CDB.
GRANT SELECT ON SYS.V_\$LOGMNR_DICTIONARY TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON SYS.V_\$LOGMNR_LOGS TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON SYS.V_\$LOGMNR_PARAMETERS TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON SYS.V_\$LOGMNR_SESSION TO ${ORACLE_MIGRATION_USER};
GRANT LOGMINING TO ${ORACLE_MIGRATION_USER};
GRANT EXECUTE ON DBMS_LOGMNR TO ${ORACLE_MIGRATION_USER};

ALTER SESSION SET CONTAINER = ${ORACLE_SERVICE};

DECLARE
  v_tables NUMBER := 0;
BEGIN
  FOR t IN (
    SELECT table_name
      FROM all_tables
     WHERE owner = '${ORACLE_MIGRATION_SCHEMA}'
     ORDER BY table_name
  ) LOOP
    EXECUTE IMMEDIATE 'GRANT SELECT, FLASHBACK ON ${ORACLE_MIGRATION_SCHEMA}.' || t.table_name || ' TO ${ORACLE_MIGRATION_USER}';
    DBMS_OUTPUT.PUT_LINE('Granted SELECT, FLASHBACK on ${ORACLE_MIGRATION_SCHEMA}.' || t.table_name);
    v_tables := v_tables + 1;
  END LOOP;
  IF v_tables = 0 THEN
    RAISE_APPLICATION_ERROR(-20999, 'No tables found in schema ${ORACLE_MIGRATION_SCHEMA}.');
  END IF;
END;
/

-- PDB grants. MOLT uses this connection with --source.
GRANT CONNECT TO ${ORACLE_MIGRATION_USER};
GRANT CREATE SESSION TO ${ORACLE_MIGRATION_USER};
GRANT SELECT_CATALOG_ROLE TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON V_\$SESSION TO ${ORACLE_MIGRATION_USER};
GRANT SELECT ON V_\$TRANSACTION TO ${ORACLE_MIGRATION_USER};

DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM all_tables
   WHERE owner = '${ORACLE_MIGRATION_SCHEMA}'
     AND table_name = 'REPLICATOR_SENTINEL';
  IF v_count = 1 THEN
    EXECUTE IMMEDIATE 'GRANT SELECT, INSERT, UPDATE ON ${ORACLE_MIGRATION_SCHEMA}."REPLICATOR_SENTINEL" TO ${ORACLE_MIGRATION_USER}';
    DBMS_OUTPUT.PUT_LINE('Granted SELECT, INSERT, UPDATE on ${ORACLE_MIGRATION_SCHEMA}.REPLICATOR_SENTINEL.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('REPLICATOR_SENTINEL is not in ${ORACLE_MIGRATION_SCHEMA} yet. Run scripts/create-oracle-sentinel.sh, then rerun this script.');
  END IF;
END;
/

EXIT
SQL

echo "Common user ${ORACLE_MIGRATION_USER} is ready."
echo "PDB:  oracle://${ORACLE_MIGRATION_USER}@127.0.0.1:${ORACLE_PORT}/${ORACLE_SERVICE}"
echo "CDB:  oracle://${ORACLE_MIGRATION_USER}@127.0.0.1:${ORACLE_PORT}/FREE"
