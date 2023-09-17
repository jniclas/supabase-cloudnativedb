ARG PG_VERSION
ARG PG_MAJOR

FROM supabase/postgres:${PG_VERSION}

ARG PG_VERSION
ARG PG_MAJOR

# Do not split the description, otherwise we will see a blank space in the labels
LABEL name="PostgreSQL Container Images" \
      vendor="The CloudNativePG Contributors" \
      version="$PG_VERSION" \
      release="10" \
      summary="PostgreSQL Container images." \
      description="This Docker image contains PostgreSQL and Barman Cloud based on Postgres 15.4-bullseye."

LABEL org.opencontainers.image.description="This Docker image contains PostgreSQL and Barman Cloud based on Postgres 15.4-bullseye."

COPY requirements.txt /

# Install additional extensions
# RUN set -xe; \
RUN apt-get update; \
	apt-get install -y --no-install-recommends \
		# "postgresql-$PG_MAJOR-pgaudit" \
		# "postgresql-$PG_MAJOR-pgvector" \
		# "postgresql-${PG_MAJOR}-pg-failover-slots" \
		pg-failover-slots \
	;
RUN rm -fr /tmp/* ; \
	rm -rf /var/lib/apt/lists/*;

# Install barman-cloud
# RUN set -xe; \
RUN apt-get update; \
	apt-get install -y --no-install-recommends \
		python3-pip \
		python3-psycopg2 \
		python3-setuptools \
	; \
	pip3 install --upgrade pip; \
# TODO: Remove --no-deps once https://github.com/pypa/pip/issues/9644 is solved
	pip3 install --no-deps -r requirements.txt; \
	rm -rf /var/lib/apt/lists/*;

# Change the uid of postgres to 26
RUN usermod -u 26 postgres
USER 26