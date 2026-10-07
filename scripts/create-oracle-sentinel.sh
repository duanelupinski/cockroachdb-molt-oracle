#!/bin/bash
# Create the MOLT Replicator checkpoint table in the source schema.
#
# Follows the MOLT delta migration guide:
# https://docs.cockroachlabs.com/docs/molt/delta-migration-oracle#create-source-sentinel-table
#
# Usage: scripts/create-oracle-sentinel.sh
# Requires scripts/start-oracle.sh. Grants DML on the table when the
# migration user already exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

ORACLE_MIGRATION_USER="$(printf '%s' "${ORACLE_MIGRATION_USER:-C##MIGRATION_USER}" | tr '[:lower:]' '[:upper:]')"
ORACLE_MIGRATION_SCHEMA="$(printf '%s' "${ORACLE_MIGRATION_SCHEMA:-HR}" | tr '[:lower:]' '[:upper:]')"

if [[ ! "${ORACLE_MIGRATION_USER}" =~ ^C##[A-Z][A-Z0-9_#$]*$ ]]; then
  echo "ORACLE_MIGRATION_USER must be a common user name starting with C##." >&2
  exit 1
fi
if [[ ! "${ORACLE_MIGRATION_SCHEMA}" =~ ^[A-Z][A-Z0-9_#$]*$ ]]; then
  echo "ORACLE_MIGRATION_SCHEMA must be an unquoted Oracle schema name." >&2
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

echo "Creating ${ORACLE_MIGRATION_SCHEMA}.REPLICATOR_SENTINEL in ${ORACLE_SERVICE}."

podman exec -i "${CONTAINER_NAME}" sqlplus -s / as sysdba <<SQL
SET ECHO OFF
SET FEEDBACK ON
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

ALTER SESSION SET CONTAINER = ${ORACLE_SERVICE};

DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM all_tables
   WHERE owner = '${ORACLE_MIGRATION_SCHEMA}'
     AND table_name = 'REPLICATOR_SENTINEL';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE TABLE ${ORACLE_MIGRATION_SCHEMA}."REPLICATOR_SENTINEL" (keycol NUMBER PRIMARY KEY, lastSCN NUMBER)';
    DBMS_OUTPUT.PUT_LINE('Created ${ORACLE_MIGRATION_SCHEMA}.REPLICATOR_SENTINEL.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('${ORACLE_MIGRATION_SCHEMA}.REPLICATOR_SENTINEL already exists.');
  END IF;
END;
/

DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM dba_users
   WHERE username = '${ORACLE_MIGRATION_USER}';
  IF v_count = 1 THEN
    EXECUTE IMMEDIATE 'GRANT SELECT, INSERT, UPDATE ON ${ORACLE_MIGRATION_SCHEMA}."REPLICATOR_SENTINEL" TO ${ORACLE_MIGRATION_USER}';
    DBMS_OUTPUT.PUT_LINE('Granted SELECT, INSERT, UPDATE on ${ORACLE_MIGRATION_SCHEMA}.REPLICATOR_SENTINEL to ${ORACLE_MIGRATION_USER}.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('${ORACLE_MIGRATION_USER} does not exist yet. Run scripts/create-oracle-migration-user.sh to grant access.');
  END IF;
END;
/

EXIT
SQL

echo "Sentinel table ${ORACLE_MIGRATION_SCHEMA}.REPLICATOR_SENTINEL is ready."
