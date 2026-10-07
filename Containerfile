FROM docker.io/gvenzl/oracle-free:23.26.2-slim

COPY oracle/hr/ /opt/oracle/hr/
COPY oracle/init/01-install-hr.sh /container-entrypoint-initdb.d/01-install-hr.sh

USER root
RUN chmod 755 /opt/oracle/hr/install-hr.sh /container-entrypoint-initdb.d/01-install-hr.sh \
    && chown -R oracle:oinstall /opt/oracle/hr /container-entrypoint-initdb.d
USER oracle

EXPOSE 1521
