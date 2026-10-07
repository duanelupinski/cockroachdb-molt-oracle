# Oracle to CockroachDB with MOLT

Local Podman demo of an Oracle Database Free HR schema migrated to CockroachDB with MOLT Fetch, MOLT Verify, and MOLT Replicator. The source is Oracle AI Database Free 23.26.2 on Apple Silicon. The target is an insecure three-node CockroachDB cluster. Both are reachable from this Mac.

Identifiers on the target stay case-sensitive (`"HR"."EMPLOYEES"`). `LOCATION_ID`, `DEPARTMENT_ID`, and `EMPLOYEE_ID` stay `INT8` so Fetch can load the Oracle values. Each of those columns, on the parent and on every child that references it, has a stored UUID computed as `md5` of the integer. The same number always produces the same UUID. No sequences are created, and `gen_random_uuid()` is not used.

Passwords and user names live in `.env`, created from `.env.example` on the first start. MOLT commands read the Oracle migration password from `ORACLE_MIGRATION_PASSWORD` in that file. URL-encode `#` in the Oracle common user as `%23` (`C##MIGRATION_USER` becomes `C%23%23MIGRATION_USER`).

`bin/` and `instantclient/` are gitignored. They are local downloads.

## Start Oracle

```bash
scripts/start-oracle.sh
```

The first run pulls the base image, creates the database, and loads HR into `FREEPDB1`. That often takes several minutes. Later starts reuse the `oracle-source-data` volume and do not reload HR. Oracle applies `ORACLE_PASSWORD` only while the data volume is first created.

| Setting | Value |
| --- | --- |
| Host | `127.0.0.1` |
| Port | `1521` |
| PDB service | `FREEPDB1` |
| CDB service | `FREE` |
| HR user | `HR` |
| HR password | `HR_PASSWORD` in `.env` |
| `SYS` / `SYSTEM` | `ORACLE_PASSWORD` in `.env` |

JDBC:

```text
jdbc:oracle:thin:@//127.0.0.1:1521/FREEPDB1
```

SQL\*Plus as `SYSDBA` inside the container. That session starts in the CDB. Switch to the PDB before working on `HR`.

```bash
podman exec -it oracle-source sqlplus / as sysdba
```

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;
```

`scripts/load-hr.sh` drops the HR user and reloads the official sample tables: regions, countries, locations, departments, jobs, employees, and job history. The SQL comes from [oracle-samples/db-sample-schemas](https://github.com/oracle-samples/db-sample-schemas) `human_resources`, kept in `oracle/hr/` with Oracle's copyright header.

## Start CockroachDB

```bash
scripts/start-cockroach.sh
```

Three insecure nodes talk to each other on the `crdb-net` network. MOLT, running on the Mac, uses the published SQL port. Later starts reuse the node data volumes. `scripts/stop-cockroach.sh` stops the nodes and keeps those volumes.

| Setting | Value |
| --- | --- |
| SQL | `postgresql://root@127.0.0.1:26257/defaultdb?sslmode=disable` |
| Node 2 | `127.0.0.1:26258` |
| Node 3 | `127.0.0.1:26259` |
| Admin UI | `http://127.0.0.1:8080` |
| Database | `defaultdb` |
| Schema | `"HR"` |

The cluster is insecure, so CockroachDB rejects `WITH PASSWORD` (`SQLSTATE 28P01`). The migration user has no password.

## Target schema

`scripts/export-hr-ddl.sh` writes the Oracle extract to `ddl/hr_oracle.sql`. The container must already be running.

`ddl/hr_crdb.sql` is the CockroachDB schema. It adds every foreign key, then drops all ten. CockroachDB cannot disable a foreign key, and `NOT VALID` still checks new rows. `scripts/create-crdb-schema.sh` applies that file alone. The migration path below uses `scripts/prepare-crdb-target.sh`, which applies the file when `"HR"` is missing.

Stored UUID columns:

| Table | Columns |
| --- | --- |
| `LOCATIONS` | `LOCATION_UUID` |
| `DEPARTMENTS` | `DEPARTMENT_UUID`, `MANAGER_UUID`, `LOCATION_UUID` |
| `EMPLOYEES` | `EMPLOYEE_UUID`, `MANAGER_UUID`, `DEPARTMENT_UUID` |
| `JOB_HISTORY` | `EMPLOYEE_UUID`, `DEPARTMENT_UUID` |

`REGIONS.REGION_ID`, `COUNTRIES.COUNTRY_ID`, and `JOBS.JOB_ID` stay natural keys. `JOB_HISTORY` keeps the primary key (`EMPLOYEE_ID`, `START_DATE`).

## Oracle Instant Client

MOLT's Oracle build loads Instant Client at runtime. Download Instant Client Basic for macOS arm64 (this demo uses 23.26) from Oracle, mount the DMG, and copy the library directory to `instantclient/` in this repo. `genezi` in that directory should report Instant Client mode.

Every MOLT command in this README expects both library paths:

```bash
export DYLD_LIBRARY_PATH="$PWD/instantclient${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export LD_LIBRARY_PATH="$PWD/instantclient${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

## MOLT binaries

The `molt` binary on `PATH` (`/usr/local/bin/molt` in this setup) is the PostgreSQL/MySQL build. It fails Oracle connections with `failed to connect to the source database` before it opens a session. Download the Oracle build for this machine and keep it in `bin/`:

```bash
mkdir -p bin
curl -fsSL -o /tmp/molt-oracle.tgz \
  https://molt.cockroachdb.com/molt/cli/molt-latest.darwin-arm64-oracle.tgz
tar -xzf /tmp/molt-oracle.tgz -C bin
```

The archive contains `molt`, `replicator`, and the Grafana dashboards. If `tar` nests them in a subdirectory, move the files up so these paths exist:

- `bin/molt`
- `bin/replicator`
- `bin/grafana_dashboard.json` (MOLT Fetch)
- `bin/replicator_grafana_dashboard.json`
- `bin/replicator_oracle_grafana_dashboard.json` (LogMiner panels; use this one)

Each dashboard matches the binary version in that download. Run `./bin/molt` and `./bin/replicator`, not the copy on `PATH`.

## Migration users

Oracle Database Free is a multitenant database. One common user connects to the PDB (`--source`) and the CDB (`--source-cdb` / `--sourceConn`).

```bash
scripts/create-oracle-migration-user.sh
```

That script creates `C##MIGRATION_USER` with the [classic bulk load](https://docs.cockroachlabs.com/docs/molt/classic-bulk-load-oracle#create-migration-user-on-source-database) grants and the [LogMiner](https://docs.cockroachlabs.com/docs/molt/delta-migration-oracle#configure-source-database-for-replication) grants (`V$LOGMNR_*`, `LOGMINING`, `DBMS_LOGMNR`, plus `SELECT` and `FLASHBACK` on the `HR` tables). Re-run it after the sentinel table exists so the user also gets `SELECT`, `INSERT`, and `UPDATE` on `HR."REPLICATOR_SENTINEL"`.

On CockroachDB, `scripts/create-crdb-migration-user.sh` creates `crdb_user` with no password for Fetch. The replication path uses `scripts/prepare-crdb-target.sh` instead, which creates the same user and adds the delta-migration privileges.

## Archive logging and the sentinel table

Replicator reads redo through LogMiner. Enable `ARCHIVELOG`, primary-key supplemental logging, and `FORCE LOGGING` before starting it. The script creates a fast recovery area on the data volume (`/opt/oracle/oradata/fast_recovery_area`, 4G) because this container does not ship with one. Turning on `ARCHIVELOG` shuts the database down and opens it again.

```bash
scripts/enable-oracle-archivelog.sh
```

When it finishes, `V$DATABASE` reports `ARCHIVELOG`, `FORCE_LOGGING=YES`, and primary-key supplemental logging `YES` (`supplemental_log_data_min` is `YES` or `IMPLICIT`).

Create the source checkpoint table in the PDB:

```bash
scripts/create-oracle-sentinel.sh
```

That creates `HR."REPLICATOR_SENTINEL"` (`KEYCOL` number primary key, `LASTSCN` number) and grants DML to `C##MIGRATION_USER` when that user already exists. If you created the sentinel first, run `scripts/create-oracle-migration-user.sh` again so the grant is applied.

## Prepare the CockroachDB target

[Step 2 of the delta migration guide](https://docs.cockroachlabs.com/docs/molt/delta-migration-oracle#step-2-prepare-the-target-database):

```bash
scripts/prepare-crdb-target.sh
```

The script applies `ddl/hr_crdb.sql` when `"HR"` is missing. It then drops foreign keys, unique constraints, checks, non-key `NOT NULL` constraints, column defaults, and secondary indexes so replication is not blocked by them. Primary keys stay. Stored UUID columns stay. It creates `crdb_user` with `statement_timeout=0s`, `CREATEDB`, and `admin` (required for `COPY FROM`), grants DML on `"HR"`, and sets `defaultdb` `gc.ttlseconds` to `86400` (24 hours). Leave those constraints off until replication has stopped.

## MOLT Fetch

Export the Instant Client paths, then load `HR`. `--table-handling truncate-if-exists` keeps the hand-written schema. `--direct-copy` uses `COPY FROM` and does not need object storage. `--source-cdb` is required for a multitenant source. The insecure target needs `--allow-tls-mode-disable`.

```bash
export DYLD_LIBRARY_PATH="$PWD/instantclient${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export LD_LIBRARY_PATH="$PWD/instantclient${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
set -a && source .env && set +a

./bin/molt fetch \
  --source "oracle://C%23%23MIGRATION_USER:${ORACLE_MIGRATION_PASSWORD}@127.0.0.1:1521/FREEPDB1" \
  --source-cdb "oracle://C%23%23MIGRATION_USER:${ORACLE_MIGRATION_PASSWORD}@127.0.0.1:1521/FREE" \
  --target 'postgresql://crdb_user@127.0.0.1:26257/defaultdb?sslmode=disable' \
  --allow-tls-mode-disable \
  --schema-filter '^HR$' \
  --table-filter '^(REGIONS|COUNTRIES|LOCATIONS|DEPARTMENTS|JOBS|EMPLOYEES|JOB_HISTORY)$' \
  --table-handling truncate-if-exists \
  --direct-copy \
  --log-file stdout
```

`EMP_DETAILS_VIEW` is excluded. A single-table smoke test uses `--table-filter '^REGIONS$'` (5 rows). Leave `--ignore-replication-check` off this command: that flag skips Oracle `CURRENT_SCN`, and Replicator needs the cursor Fetch prints.

Fetch prints a `cdc_cursor` with `scn` and, when a transaction was open, `backfillFromSCN`. Pass `scn` to Replicator as `--scn`. The forward-replication start in this demo used SCN `2183028`.

## MOLT Verify

Compare the seven HR tables. Verify matches columns by source name, so the target-only UUID columns are not part of the row comparison. The schema phase still reports each of them as an extraneous column (`LOCATION_UUID`, `DEPARTMENT_UUID`, `MANAGER_UUID`, `EMPLOYEE_UUID`). There is no transformations rule that hides a column that exists only on the target.

```bash
set -a && source .env && set +a

./bin/molt verify \
  --source "oracle://C%23%23MIGRATION_USER:${ORACLE_MIGRATION_PASSWORD}@127.0.0.1:1521/FREEPDB1" \
  --source-cdb "oracle://C%23%23MIGRATION_USER:${ORACLE_MIGRATION_PASSWORD}@127.0.0.1:1521/FREE" \
  --target 'postgresql://crdb_user@127.0.0.1:26257/defaultdb?sslmode=disable' \
  --allow-tls-mode-disable \
  --schema-filter '^HR$' \
  --table-filter '^(REGIONS|COUNTRIES|LOCATIONS|DEPARTMENTS|JOBS|EMPLOYEES|JOB_HISTORY)$' \
  --log-file stdout
```

## MOLT Replicator

`./bin/replicator oraclelogminer` tails LogMiner from the CDB and reads table rows from the PDB. `--sourceSchema` is the table owner, `HR`. `--targetSchema` must keep the case of `"HR"`. Staging tables are created in `defaultdb._replicator` on the same CockroachDB connection. Metrics are off unless `--metricsAddr` is set.

This replicator build accepts Oracle 19 and 21 only. Oracle Database Free 23 needs `--allowUnsupportedOracleVersion`. It logs a warning and continues.

```bash
export DYLD_LIBRARY_PATH="$PWD/instantclient${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export LD_LIBRARY_PATH="$PWD/instantclient${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
set -a && source .env && set +a

./bin/replicator oraclelogminer \
  --sourceConn "oracle://C%23%23MIGRATION_USER:${ORACLE_MIGRATION_PASSWORD}@127.0.0.1:1521/FREE" \
  --sourcePDBConn "oracle://C%23%23MIGRATION_USER:${ORACLE_MIGRATION_PASSWORD}@127.0.0.1:1521/FREEPDB1" \
  --targetConn 'postgresql://crdb_user@127.0.0.1:26257/defaultdb?sslmode=disable' \
  --sourceSchema HR \
  --targetSchema 'defaultdb."HR"' \
  --scn 2183028 \
  --stagingSchema defaultdb._replicator \
  --stagingCreateSchema \
  --allowUnsupportedOracleVersion \
  --metricsAddr :30005 \
  -v
```

Replace `2183028` with the `scn` from the fetch `cdc_cursor`. If that cursor also has a smaller `backfillFromSCN`, add `--backfillFromSCN <that value>` so transactions that started before the cursor and committed after it are included. Metrics are then at `http://localhost:30005/_/varz`.

## Prometheus and Grafana

The dashboard JSON files ship in the same MOLT download as the binaries, in `bin/`. Use `bin/replicator_oracle_grafana_dashboard.json` for this Oracle source. It is the dashboard with the LogMiner panels (redo parsing timings, along with upsert and delete rates and lag). `bin/grafana_dashboard.json` is for Fetch, and `bin/replicator_grafana_dashboard.json` is the generic Replicator dashboard.

### Scrape Replicator

`--metricsAddr :30005` on the replicator command above exposes `http://localhost:30005/_/varz`. Prometheus must scrape that path. The default `/metrics` path is empty.

Save this as `prometheus.yml` in the directory you run Prometheus from:

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'molt_replicator'
    metrics_path: /_/varz
    static_configs:
      - targets: ['localhost:30005']
```

Install and start Prometheus (Homebrew on this Mac):

```bash
brew install prometheus
prometheus --config.file=prometheus.yml
```

Open `http://localhost:9090/targets`. The `molt_replicator` job should show state `UP`.

### Connect Grafana

```bash
brew install grafana
brew services start grafana
```

Open `http://localhost:3000` and sign in with `admin` / `admin`. Go to **Connections → Data sources → Add data source → Prometheus**, and set the URL to `http://localhost:9090`.

### Import the Oracle dashboard

In Grafana, open **Dashboards → New → Import**. Upload `bin/replicator_oracle_grafana_dashboard.json`, or paste its contents. Select the Prometheus data source you just added, then click **Import**.

Panels fill with live replication metrics: upsert and delete rates, lag, and LogMiner redo-log parsing timings.

### Cutover signal

On that dashboard, use the upsert/delete rate panel. The same series is:

```promql
sum by (schema) (rate(apply_upserts_total[$__rate_interval]) + rate(apply_deletes_total[$__rate_interval]))
```

When that rate flattens to 0, forward replication has drained and it is safe to stop Replicator.

## Stop and reset

```bash
scripts/stop-oracle.sh
scripts/stop-cockroach.sh
scripts/reset-oracle.sh --yes
```

Reset deletes the Oracle container and the data volume. The next start builds a new database and loads HR again. CockroachDB volumes are kept by `scripts/stop-cockroach.sh`.

`podman compose up` uses `compose.yaml` for the same Oracle image, port, and volume.
