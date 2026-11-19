
FROM postgres:17

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/patroni

RUN /opt/patroni/bin/pip install --no-cache-dir \
    "patroni[etcd3]" \
    "psycopg2-binary"

ENV PATH="/opt/patroni/bin:${PATH}"

COPY patroni-entrypoint.sh /usr/local/bin/patroni-entrypoint.sh

RUN chmod +x /usr/local/bin/patroni-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]
