#!/bin/bash
# Enable ARCHIVELOG, primary-key supplemental logging, and FORCE LOGGING.
#
# Follows the MOLT delta migration guide:
# https://docs.cockroachlabs.com/docs/molt/delta-migration-oracle#enable-archivelog-and-force-logging
#
# Usage: scripts/enable-oracle-archivelog.sh
# Requires scripts/start-oracle.sh. Enabling ARCHIVELOG shuts the database
# down and opens it again, so clients lose their connections for that step.
#
# This Oracle Free container has no fast recovery area. Archived logs need a
# destination on the data volume before ARCHIVELOG can be used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/oracle-env.sh"

FRA_DEST="${ORACLE_FRA_DEST:-/opt/oracle/oradata/fast_recovery_area}"
FRA_SIZE="${ORACLE_FRA_SIZE:-4G}"

if [[ ! "${FRA_DEST}" =~ ^/opt/oracle/oradata/[A-Za-z0-9._/-]+$ ]]; then
  echo "ORACLE_FRA_DEST must be a directory under /opt/oracle/oradata." >&2
  exit 1
fi
if [[ ! "${FRA_SIZE}" =~ ^[1-9][0-9]*[MGT]$ ]]; then
  echo "ORACLE_FRA_SIZE must be a size such as 4G." >&2
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

sqlplus_sys() {
  podman exec -i "${CONTAINER_NAME}" sqlplus -s / as sysdba
}

echo "Preparing the fast recovery area on ${FRA_DEST}."
podman exec "${CONTAINER_NAME}" mkdir -p "${FRA_DEST}"

sqlplus_sys <<SQL
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
  v_dest VARCHAR2(4000);
  v_size NUMBER;
BEGIN
  SELECT value INTO v_dest FROM v\$parameter WHERE name = 'db_recovery_file_dest';
  SELECT TO_NUMBER(value) INTO v_size FROM v\$parameter WHERE name = 'db_recovery_file_dest_size';
  IF v_size IS NULL OR v_size = 0 THEN
    EXECUTE IMMEDIATE 'ALTER SYSTEM SET db_recovery_file_dest_size = ${FRA_SIZE} SCOPE=BOTH';
    DBMS_OUTPUT.PUT_LINE('Set db_recovery_file_dest_size to ${FRA_SIZE}.');
  END IF;
  IF v_dest IS NULL THEN
    EXECUTE IMMEDIATE 'ALTER SYSTEM SET db_recovery_file_dest = ''${FRA_DEST}'' SCOPE=BOTH';
    DBMS_OUTPUT.PUT_LINE('Set db_recovery_file_dest to ${FRA_DEST}.');
  END IF;
END;
/
EXIT
SQL

log_mode="$(sqlplus_sys <<'SQL' | tr -d '[:space:]'
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SELECT log_mode FROM v$database;
EXIT
SQL
)"

if [[ "${log_mode}" == "ARCHIVELOG" ]]; then
  echo "ARCHIVELOG is already enabled."
else
  echo "Restarting the database to enable ARCHIVELOG."
  sqlplus_sys <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SHUTDOWN IMMEDIATE
STARTUP MOUNT
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
EXIT
SQL
fi

status="$(sqlplus_sys <<'SQL'
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
  v_pk VARCHAR2(10);
  v_force VARCHAR2(10);
BEGIN
  SELECT supplemental_log_data_pk, force_logging
    INTO v_pk, v_force
    FROM v$database;
  IF v_pk = 'YES' THEN
    DBMS_OUTPUT.PUT_LINE('Primary-key supplemental logging is already enabled.');
  ELSE
    EXECUTE IMMEDIATE 'ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS';
    DBMS_OUTPUT.PUT_LINE('Enabled primary-key supplemental logging.');
  END IF;
  IF v_force = 'YES' THEN
    DBMS_OUTPUT.PUT_LINE('FORCE LOGGING is already enabled.');
  ELSE
    EXECUTE IMMEDIATE 'ALTER DATABASE FORCE LOGGING';
    DBMS_OUTPUT.PUT_LINE('Enabled FORCE LOGGING.');
  END IF;
END;
/

SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SELECT CASE
         WHEN log_mode = 'ARCHIVELOG'
          AND force_logging = 'YES'
          AND supplemental_log_data_pk = 'YES'
          AND supplemental_log_data_min IN ('YES', 'IMPLICIT')
         THEN 'ARCHIVELOG_READY'
         ELSE 'ARCHIVELOG_NOT_READY log_mode=' || log_mode
              || ' force_logging=' || force_logging
              || ' supplemental_log_data_min=' || supplemental_log_data_min
              || ' supplemental_log_data_pk=' || supplemental_log_data_pk
       END
  FROM v$database;
EXIT
SQL
)"
printf '%s\n' "${status}"
if ! grep -q 'ARCHIVELOG_READY' <<<"${status}"; then
  echo "ARCHIVELOG setup did not reach the expected state." >&2
  exit 1
fi
echo "ARCHIVELOG, primary-key supplemental logging, and FORCE LOGGING are enabled."
