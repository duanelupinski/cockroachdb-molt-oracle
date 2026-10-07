#!/bin/bash
# Create the Oracle HR sample schema and load its demo rows.
# Safe to run again: an existing HR user is dropped and recreated.
set -euo pipefail

HR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HR_PASSWORD="${HR_PASSWORD:?Set HR_PASSWORD}"
HR_TABLESPACE="${HR_TABLESPACE:-USERS}"

if [[ ! "${HR_PASSWORD}" =~ ^[A-Za-z][A-Za-z0-9_#]{7,}$ ]]; then
  echo "HR_PASSWORD must start with a letter and use only letters, digits, underscore, or hash (8+ characters)." >&2
  exit 1
fi

if [[ ! "${HR_TABLESPACE}" =~ ^[A-Za-z][A-Za-z0-9_#$]{0,29}$ ]]; then
  echo "HR_TABLESPACE is not a valid Oracle tablespace name." >&2
  exit 1
fi

SQL_FILE="$(mktemp /tmp/install-hr.XXXXXX.sql)"
cleanup() {
  rm -f "${SQL_FILE}"
}
trap cleanup EXIT

cat > "${SQL_FILE}" <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET ECHO OFF
SET FEEDBACK ON
SET SERVEROUTPUT ON
SET DEFINE OFF

ALTER SESSION SET CONTAINER = FREEPDB1;

DECLARE
   v_user_exists all_users.username%TYPE;
BEGIN
   FOR s IN (SELECT sid, serial# FROM v\$session WHERE username = 'HR') LOOP
      EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' || s.sid || ',' || s.serial# || ''' IMMEDIATE';
   END LOOP;

   SELECT MAX(username) INTO v_user_exists
     FROM all_users
    WHERE username = 'HR';
   IF v_user_exists IS NOT NULL THEN
      EXECUTE IMMEDIATE 'DROP USER HR CASCADE';
      DBMS_OUTPUT.PUT_LINE('Dropped existing HR schema.');
   END IF;
END;
/

CREATE USER hr IDENTIFIED BY "${HR_PASSWORD}"
  DEFAULT TABLESPACE ${HR_TABLESPACE}
  QUOTA UNLIMITED ON ${HR_TABLESPACE};

GRANT CREATE MATERIALIZED VIEW,
      CREATE PROCEDURE,
      CREATE SEQUENCE,
      CREATE SESSION,
      CREATE SYNONYM,
      CREATE TABLE,
      CREATE TRIGGER,
      CREATE TYPE,
      CREATE VIEW
  TO hr;

ALTER SESSION SET CURRENT_SCHEMA = HR;
ALTER SESSION SET NLS_LANGUAGE = American;
ALTER SESSION SET NLS_TERRITORY = America;

@"${HR_DIR}/hr_create.sql"
@"${HR_DIR}/hr_populate.sql"
@"${HR_DIR}/hr_code.sql"

SET HEADING ON
SET FEEDBACK OFF
SET PAGESIZE 50
COLUMN "Table" FORMAT A16
COLUMN "provided" FORMAT 999999
COLUMN "actual" FORMAT 999999

SELECT 'regions' AS "Table", 5 AS "provided", COUNT(1) AS "actual" FROM hr.regions
UNION ALL
SELECT 'countries', 25, COUNT(1) FROM hr.countries
UNION ALL
SELECT 'departments', 27, COUNT(1) FROM hr.departments
UNION ALL
SELECT 'locations', 23, COUNT(1) FROM hr.locations
UNION ALL
SELECT 'employees', 107, COUNT(1) FROM hr.employees
UNION ALL
SELECT 'jobs', 19, COUNT(1) FROM hr.jobs
UNION ALL
SELECT 'job_history', 10, COUNT(1) FROM hr.job_history;

DECLARE
   v_regions      NUMBER;
   v_countries    NUMBER;
   v_departments  NUMBER;
   v_locations    NUMBER;
   v_employees    NUMBER;
   v_jobs         NUMBER;
   v_job_history  NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_regions FROM hr.regions;
   SELECT COUNT(*) INTO v_countries FROM hr.countries;
   SELECT COUNT(*) INTO v_departments FROM hr.departments;
   SELECT COUNT(*) INTO v_locations FROM hr.locations;
   SELECT COUNT(*) INTO v_employees FROM hr.employees;
   SELECT COUNT(*) INTO v_jobs FROM hr.jobs;
   SELECT COUNT(*) INTO v_job_history FROM hr.job_history;

   IF v_regions <> 5
      OR v_countries <> 25
      OR v_departments <> 27
      OR v_locations <> 23
      OR v_employees <> 107
      OR v_jobs <> 19
      OR v_job_history <> 10 THEN
      RAISE_APPLICATION_ERROR(-20001, 'HR row counts do not match the sample schema.');
   END IF;
END;
/

EXIT
SQL

echo "Installing HR sample schema into FREEPDB1."
sqlplus -s / as sysdba @"${SQL_FILE}"
