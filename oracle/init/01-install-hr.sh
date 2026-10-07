#!/bin/bash
# Runs once, the first time the database files are created.
set -euo pipefail
exec bash /opt/oracle/hr/install-hr.sh
