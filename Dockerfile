ARG PG_VERSION
ARG PG_MAJOR

FROM supabase/postgres:${PG_VERSION}

ARG PG_VERSION
ARG PG_MAJOR

# Do not split the description, otherwise we will see a blank space in the labels
LABEL name="PostgreSQL Container Images" \
      vendor="The CloudNativePG Contributors" \
      version="${PG_VERSION}" \
      release="5" \
      summary="PostgreSQL Container images." \
      description="This Docker image contains PostgreSQL and Barman Cloud based on Postgres 15.8-bullseye."

LABEL org.opencontainers.image.description="This Docker image contains PostgreSQL and Barman Cloud based on Postgres 15.8-bullseye."

COPY requirements.txt /

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y postgresql-common && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

# Install additional extensions
RUN set -xe; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		# the following two are already included in the base image
		# "postgresql-${PG_MAJOR}-pgaudit" \
		# "postgresql-${PG_MAJOR}-pgvector" \
		"postgresql-${PG_MAJOR}-pg-failover-slots" \
	; \
	rm -fr /tmp/* ; \
	rm -rf /var/lib/apt/lists/*;

# Install barman-cloud
RUN set -xe; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		# We require build dependencies to build snappy 0.6
		# on Python 3.11 or greater.
		# TODO: Remove build deps once barman unpins the snappy version or
		# https://github.com/EnterpriseDB/barman/issues/905 is completed
		build-essential python3-dev libsnappy-dev \
		python3-pip \
		python3-psycopg2 \
		python3-setuptools \
	; \
	pip3 install  --upgrade pip; \
	# TODO: Remove --no-deps once https://github.com/pypa/pip/issues/9644 is solved
	pip3 install  --no-deps -r requirements.txt; \
	# We require build dependencies to build snappy 0.6
	# on Python 3.11 or greater.
	# TODO: Remove build deps once barman unpins the snappy version or
	# https://github.com/EnterpriseDB/barman/issues/905 is completed
	apt-get remove -y --purge --autoremove \
		build-essential \
		python3-dev \
		libsnappy-dev \
	; \
	rm -rf /var/lib/apt/lists/*;

# Change the uid of postgres to 26
RUN usermod -u 26 postgres
USER 26