This repo is not needed anymore. To have supabase postgres running inside cloudnative pg, this is needed:

No pg_ident.conf and pg_hba.conf needed, but this settings for the cloud native pg Cluster resource:
```
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ include "supabase.db.fullname" . }}
  labels:
    {{- include "supabase.labels" . | nindent 4 }}
spec:
  instances: 2
  primaryUpdateStrategy: unsupervised
  imageName: "{{ .Values.db.image.repository }}:{{ .Values.db.image.tag | default .Chart.AppVersion }}"
  imagePullPolicy: {{ .Values.db.image.pullPolicy }}
  postgresUID: 101
  postgresGID: 102
  # I tried a bit with pg_hba and pg_init, but not sure if it actually worked, but now its not needed, but I keep it commented
  # postgresql:
    # parameters:
    #   ident_file: /postgresconf/pg_ident.conf
    # pg_hba:
    #   - local all  supabase_admin      scram-sha-256
    #   - local all  all                 peer map=supabase_map
    #   - host  all  all  127.0.0.1/32   trust
    #   - host  all  all  ::1/128        trust
    #   - host  all  all  10.0.0.0/8     scram-sha-256
    #   - host  all  all  172.16.0.0/12  scram-sha-256
    #   - host  all  all  192.168.0.0/16 scram-sha-256
    #   - host  all  all  0.0.0.0/0      scram-sha-256
    
    # pg_ident:
    #   # MAPNAME       SYSTEM-USERNAME         PG-USERNAME
    #   - supabase_map  postgres   postgres
    #   - supabase_map  root       postgres
    #   - supabase_map  ubuntu     postgres

    #   # supabase-specific users
    #   - supabase_map  gotrue     supabase_auth_admin
    #   - supabase_map  postgrest  authenticator
    #   - supabase_map  adminapi   postgres
  resources: 
    limits:
      memory: 1Gi
      cpu: 1
    requests:
      memory: 1Gi
      cpu: 1
  storage:
    size: 2Gi
    storageClass: {{ .Values.db.storage.storageClassName }}
  monitoring:
    enablePodMonitor: false
  enableSuperuserAccess: true
  bootstrap:
    initdb:
      database: app
      owner: app
      dataChecksums: true
      encoding: 'UTF8'
      postInitApplicationSQLRefs:
        configMapRefs:
        - name: {{ include "supabase.db.fullname" . }}-init
          key: configmap.sql
```
with values.yaml
```
db:
 # we disable the supabase db, but use the values in cloud native pq
  enabled: false
  secretName: "supabase-db"
  userName: postgres
  image:
    repository: supabase/postgres
    pullPolicy: IfNotPresent
    tag: "15.1.1.26"
  imagePullSecrets: []
  replicaCount: 2
  nameOverride: ""
  fullnameOverride: ""
  serviceAccount:
    create: true
    annotations: {}
    name: ""
  podAnnotations: {}
  podSecurityContext: {}
  securityContext: {}
  service:
    type: ClusterIP
    port: 5432
  persistence:
    enabled: false
  storage:
    mountPath: /var/lib/postgresql/data
    storageClassName: "openebs-jiva-csi-default"
    annotations: 
      helm.sh/resource-policy: "keep"
    size: 5Gi
    accessModes:
      - ReadWriteOnce
    class: ""
  autoscaling:
    enabled: false
    minReplicas: 1
    maxReplicas: 100
    targetCPUUtilizationPercentage: 80
  nodeSelector: {}
  tolerations: []
  affinity: {}
```
It is important to change the default Postgres user id and group, cause they are not set to 26 in the supabase image. I got them by running
`docker run --rm -it supabase/postgres:15.1.1.26 getent passwd`
and at the point of creation oct 2023 I copied all migrations from https://github.com/supabase/postgres/tree/develop/migrations/db to my init.yaml: (I think I should change that to a better way that keeps it up to date...)
```
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "supabase.db.fullname" . }}-init
data:
 # drop role authenticator;
  configmap.sql: |
    -- migrate:up migrations/db/init-scripts/00000000000000-initial-schema.sql

    -- Set up realtime
    -- defaults to empty publication
    create publication supabase_realtime;

    -- Supabase super admin
    create user supabase_admin;
    alter user  supabase_admin with superuser createdb createrole replication bypassrls;

    -- Supabase replication user
    create user supabase_replication_admin with login replication;

    -- Supabase read-only user
    create role supabase_read_only_user with login bypassrls;
    grant pg_read_all_data to supabase_read_only_user;

    -- Extension namespacing
    create schema if not exists extensions;
    create extension if not exists "uuid-ossp"      with schema extensions;
    create extension if not exists pgcrypto         with schema extensions;
    create extension if not exists pgjwt            with schema extensions;

    -- Set up auth roles for the developer
    create role anon                nologin noinherit;
    create role authenticated       nologin noinherit; -- "logged in" user: web_user, app_user, etc
    create role service_role        nologin noinherit bypassrls; -- allow developers to create JWT's that bypass their policies

    create user authenticator noinherit;
    grant anon              to authenticator;
    grant authenticated     to authenticator;
    grant service_role      to authenticator;
    grant supabase_admin    to authenticator;

    grant usage                     on schema public to postgres, anon, authenticated, service_role;
    alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
    alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;
    alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;

    -- Allow Extensions to be used in the API
    grant usage                     on schema extensions to postgres, anon, authenticated, service_role;

    -- Set up namespacing
    alter user supabase_admin SET search_path TO public, extensions; -- don't include the "auth" schema

    -- These are required so that the users receive grants whenever "supabase_admin" creates tables/function
    alter default privileges for user supabase_admin in schema public grant all
        on sequences to postgres, anon, authenticated, service_role;
    alter default privileges for user supabase_admin in schema public grant all
        on tables to postgres, anon, authenticated, service_role;
    alter default privileges for user supabase_admin in schema public grant all
        on functions to postgres, anon, authenticated, service_role;

    -- Set short statement/query timeouts for API roles
    alter role anon set statement_timeout = '3s';
    alter role authenticated set statement_timeout = '8s';

    -- migrate:down

    -- migrate:up migrations/db/init-scripts/00000000000001-auth-schema.sql

    CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION supabase_admin;

    -- auth.users definition

    CREATE TABLE auth.users (
        instance_id uuid NULL,
        id uuid NOT NULL UNIQUE,
        aud varchar(255) NULL,
        "role" varchar(255) NULL,
        email varchar(255) NULL UNIQUE,
        encrypted_password varchar(255) NULL,
        confirmed_at timestamptz NULL,
        invited_at timestamptz NULL,
        confirmation_token varchar(255) NULL,
        confirmation_sent_at timestamptz NULL,
        recovery_token varchar(255) NULL,
        recovery_sent_at timestamptz NULL,
        email_change_token varchar(255) NULL,
        email_change varchar(255) NULL,
        email_change_sent_at timestamptz NULL,
        last_sign_in_at timestamptz NULL,
        raw_app_meta_data jsonb NULL,
        raw_user_meta_data jsonb NULL,
        is_super_admin bool NULL,
        created_at timestamptz NULL,
        updated_at timestamptz NULL,
        CONSTRAINT users_pkey PRIMARY KEY (id)
    );
    CREATE INDEX users_instance_id_email_idx ON auth.users USING btree (instance_id, email);
    CREATE INDEX users_instance_id_idx ON auth.users USING btree (instance_id);
    comment on table auth.users is 'Auth: Stores user login data within a secure schema.';

    -- auth.refresh_tokens definition

    CREATE TABLE auth.refresh_tokens (
        instance_id uuid NULL,
        id bigserial NOT NULL,
        "token" varchar(255) NULL,
        user_id varchar(255) NULL,
        revoked bool NULL,
        created_at timestamptz NULL,
        updated_at timestamptz NULL,
        CONSTRAINT refresh_tokens_pkey PRIMARY KEY (id)
    );
    CREATE INDEX refresh_tokens_instance_id_idx ON auth.refresh_tokens USING btree (instance_id);
    CREATE INDEX refresh_tokens_instance_id_user_id_idx ON auth.refresh_tokens USING btree (instance_id, user_id);
    CREATE INDEX refresh_tokens_token_idx ON auth.refresh_tokens USING btree (token);
    comment on table auth.refresh_tokens is 'Auth: Store of tokens used to refresh JWT tokens once they expire.';

    -- auth.instances definition

    CREATE TABLE auth.instances (
        id uuid NOT NULL,
        uuid uuid NULL,
        raw_base_config text NULL,
        created_at timestamptz NULL,
        updated_at timestamptz NULL,
        CONSTRAINT instances_pkey PRIMARY KEY (id)
    );
    comment on table auth.instances is 'Auth: Manages users across multiple sites.';

    -- auth.audit_log_entries definition

    CREATE TABLE auth.audit_log_entries (
        instance_id uuid NULL,
        id uuid NOT NULL,
        payload json NULL,
        created_at timestamptz NULL,
        CONSTRAINT audit_log_entries_pkey PRIMARY KEY (id)
    );
    CREATE INDEX audit_logs_instance_id_idx ON auth.audit_log_entries USING btree (instance_id);
    comment on table auth.audit_log_entries is 'Auth: Audit trail for user actions.';

    -- auth.schema_migrations definition

    CREATE TABLE auth.schema_migrations (
        "version" varchar(255) NOT NULL,
        CONSTRAINT schema_migrations_pkey PRIMARY KEY ("version")
    );
    comment on table auth.schema_migrations is 'Auth: Manages updates to the auth system.';

    INSERT INTO auth.schema_migrations (version)
    VALUES  ('20171026211738'),
            ('20171026211808'),
            ('20171026211834'),
            ('20180103212743'),
            ('20180108183307'),
            ('20180119214651'),
            ('20180125194653');

    -- Gets the User ID from the request cookie
    create or replace function auth.uid() returns uuid as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
    $$ language sql stable;

    -- Gets the User ID from the request cookie
    create or replace function auth.role() returns text as $$
    select nullif(current_setting('request.jwt.claim.role', true), '')::text;
    $$ language sql stable;

    -- Gets the User email
    create or replace function auth.email() returns text as $$
    select nullif(current_setting('request.jwt.claim.email', true), '')::text;
    $$ language sql stable;

    -- usage on auth functions to API roles
    GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

    -- Supabase super admin
    CREATE USER supabase_auth_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION;
    GRANT ALL PRIVILEGES ON SCHEMA auth TO supabase_auth_admin;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA auth TO supabase_auth_admin;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA auth TO supabase_auth_admin;
    ALTER USER supabase_auth_admin SET search_path = "auth";
    ALTER table "auth".users OWNER TO supabase_auth_admin;
    ALTER table "auth".refresh_tokens OWNER TO supabase_auth_admin;
    ALTER table "auth".audit_log_entries OWNER TO supabase_auth_admin;
    ALTER table "auth".instances OWNER TO supabase_auth_admin;
    ALTER table "auth".schema_migrations OWNER TO supabase_auth_admin;

    -- migrate:down

    -- migrate:up migrations/db/init-scripts/00000000000002-storage-schema.sql

    CREATE SCHEMA IF NOT EXISTS storage AUTHORIZATION supabase_admin;

    grant usage on schema storage to postgres, anon, authenticated, service_role;
    alter default privileges in schema storage grant all on tables to postgres, anon, authenticated, service_role;
    alter default privileges in schema storage grant all on functions to postgres, anon, authenticated, service_role;
    alter default privileges in schema storage grant all on sequences to postgres, anon, authenticated, service_role;

    CREATE TABLE "storage"."buckets" (
        "id" text not NULL,
        "name" text NOT NULL,
        "owner" uuid,
        "created_at" timestamptz DEFAULT now(),
        "updated_at" timestamptz DEFAULT now(),
        CONSTRAINT "buckets_owner_fkey" FOREIGN KEY ("owner") REFERENCES "auth"."users"("id"),
        PRIMARY KEY ("id")
    );
    CREATE UNIQUE INDEX "bname" ON "storage"."buckets" USING BTREE ("name");

    CREATE TABLE "storage"."objects" (
        "id" uuid NOT NULL DEFAULT extensions.uuid_generate_v4(),
        "bucket_id" text,
        "name" text,
        "owner" uuid,
        "created_at" timestamptz DEFAULT now(),
        "updated_at" timestamptz DEFAULT now(),
        "last_accessed_at" timestamptz DEFAULT now(),
        "metadata" jsonb,
        CONSTRAINT "objects_bucketId_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id"),
        CONSTRAINT "objects_owner_fkey" FOREIGN KEY ("owner") REFERENCES "auth"."users"("id"),
        PRIMARY KEY ("id")
    );
    CREATE UNIQUE INDEX "bucketid_objname" ON "storage"."objects" USING BTREE ("bucket_id","name");
    CREATE INDEX name_prefix_search ON storage.objects(name text_pattern_ops);

    ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

    CREATE FUNCTION storage.foldername(name text)
    RETURNS text[]
    LANGUAGE plpgsql
    AS $function$
    DECLARE
    _parts text[];
    BEGIN
        select string_to_array(name, '/') into _parts;
        return _parts[1:array_length(_parts,1)-1];
    END
    $function$;

    CREATE FUNCTION storage.filename(name text)
    RETURNS text
    LANGUAGE plpgsql
    AS $function$
    DECLARE
    _parts text[];
    BEGIN
        select string_to_array(name, '/') into _parts;
        return _parts[array_length(_parts,1)];
    END
    $function$;

    CREATE FUNCTION storage.extension(name text)
    RETURNS text
    LANGUAGE plpgsql
    AS $function$
    DECLARE
    _parts text[];
    _filename text;
    BEGIN
        select string_to_array(name, '/') into _parts;
        select _parts[array_length(_parts,1)] into _filename;
        -- @todo return the last part instead of 2
        return split_part(_filename, '.', 2);
    END
    $function$;

    CREATE FUNCTION storage.search(prefix text, bucketname text, limits int DEFAULT 100, levels int DEFAULT 1, offsets int DEFAULT 0)
    RETURNS TABLE (
        name text,
        id uuid,
        updated_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ,
        last_accessed_at TIMESTAMPTZ,
        metadata jsonb
    )
    LANGUAGE plpgsql
    AS $function$
    DECLARE
    _bucketId text;
    BEGIN
        -- will be replaced by migrations when server starts
        -- saving space for cloud-init
    END
    $function$;

    -- create migrations table
    -- https://github.com/ThomWright/postgres-migrations/blob/master/src/migrations/0_create-migrations-table.sql
    -- we add this table here and not let it be auto-created so that the permissions are properly applied to it
    CREATE TABLE IF NOT EXISTS storage.migrations (
    id integer PRIMARY KEY,
    name varchar(100) UNIQUE NOT NULL,
    hash varchar(40) NOT NULL, -- sha1 hex encoded hash of the file name and contents, to ensure it hasn't been altered since applying the migration
    executed_at timestamp DEFAULT current_timestamp
    );

    CREATE USER supabase_storage_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION;
    GRANT ALL PRIVILEGES ON SCHEMA storage TO supabase_storage_admin;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA storage TO supabase_storage_admin;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA storage TO supabase_storage_admin;
    ALTER USER supabase_storage_admin SET search_path = "storage";
    ALTER table "storage".objects owner to supabase_storage_admin;
    ALTER table "storage".buckets owner to supabase_storage_admin;
    ALTER table "storage".migrations OWNER TO supabase_storage_admin;
    ALTER function "storage".foldername(text) owner to supabase_storage_admin;
    ALTER function "storage".filename(text) owner to supabase_storage_admin;
    ALTER function "storage".extension(text) owner to supabase_storage_admin;
    ALTER function "storage".search(text,text,int,int,int) owner to supabase_storage_admin;

    -- migrate:down

    -- migrate:up migrations/db/init-scripts/00000000000003-post-setup.sql

    ALTER ROLE supabase_admin SET search_path TO "\$user",public,auth,extensions;
    ALTER ROLE postgres SET search_path TO "\$user",public,extensions;

    -- Trigger for pg_cron
    CREATE OR REPLACE FUNCTION extensions.grant_pg_cron_access()
    RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
    schema_is_cron bool;
    BEGIN
    schema_is_cron = (
        SELECT n.nspname = 'cron'
        FROM pg_event_trigger_ddl_commands() AS ev
        LEFT JOIN pg_catalog.pg_namespace AS n
        ON ev.objid = n.oid
    );

    IF schema_is_cron
    THEN
        grant usage on schema cron to postgres with grant option;

        alter default privileges in schema cron grant all on tables to postgres with grant option;
        alter default privileges in schema cron grant all on functions to postgres with grant option;
        alter default privileges in schema cron grant all on sequences to postgres with grant option;

        alter default privileges for user supabase_admin in schema cron grant all
            on sequences to postgres with grant option;
        alter default privileges for user supabase_admin in schema cron grant all
            on tables to postgres with grant option;
        alter default privileges for user supabase_admin in schema cron grant all
            on functions to postgres with grant option;

        grant all privileges on all tables in schema cron to postgres with grant option;

    END IF;

    END;
    $$;
    CREATE EVENT TRIGGER issue_pg_cron_access ON ddl_command_end WHEN TAG in ('CREATE SCHEMA')
    EXECUTE PROCEDURE extensions.grant_pg_cron_access();
    COMMENT ON FUNCTION extensions.grant_pg_cron_access IS 'Grants access to pg_cron';

    -- Event trigger for pg_net
    CREATE OR REPLACE FUNCTION extensions.grant_pg_net_access()
    RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_event_trigger_ddl_commands() AS ev
        JOIN pg_extension AS ext
        ON ev.objid = ext.oid
        WHERE ext.extname = 'pg_net'
    )
    THEN
        IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'supabase_functions_admin'
        )
        THEN
        CREATE USER supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION;
        END IF;

        GRANT USAGE ON SCHEMA net TO supabase_functions_admin, postgres, anon, authenticated, service_role;

        ALTER function net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) SECURITY DEFINER;
        ALTER function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) SECURITY DEFINER;

        ALTER function net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) SET search_path = net;
        ALTER function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) SET search_path = net;

        REVOKE ALL ON FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) FROM PUBLIC;
        REVOKE ALL ON FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) FROM PUBLIC;

        GRANT EXECUTE ON FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) TO supabase_functions_admin, postgres, anon, authenticated, service_role;
        GRANT EXECUTE ON FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) TO supabase_functions_admin, postgres, anon, authenticated, service_role;
    END IF;
    END;
    $$;
    COMMENT ON FUNCTION extensions.grant_pg_net_access IS 'Grants access to pg_net';

    DO
    $$
    BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_event_trigger
        WHERE evtname = 'issue_pg_net_access'
    ) THEN
        CREATE EVENT TRIGGER issue_pg_net_access
        ON ddl_command_end
        WHEN TAG IN ('CREATE EXTENSION')
        EXECUTE PROCEDURE extensions.grant_pg_net_access();
    END IF;
    END
    $$;

    -- Supabase dashboard user
    CREATE ROLE dashboard_user NOSUPERUSER CREATEDB CREATEROLE REPLICATION;
    GRANT ALL ON DATABASE postgres TO dashboard_user;
    GRANT ALL ON SCHEMA auth TO dashboard_user;
    GRANT ALL ON SCHEMA extensions TO dashboard_user;
    GRANT ALL ON SCHEMA storage TO dashboard_user;
    GRANT ALL ON ALL TABLES IN SCHEMA auth TO dashboard_user;
    GRANT ALL ON ALL TABLES IN SCHEMA extensions TO dashboard_user;
    -- GRANT ALL ON ALL TABLES IN SCHEMA storage TO dashboard_user;
    GRANT ALL ON ALL SEQUENCES IN SCHEMA auth TO dashboard_user;
    GRANT ALL ON ALL SEQUENCES IN SCHEMA storage TO dashboard_user;
    GRANT ALL ON ALL SEQUENCES IN SCHEMA extensions TO dashboard_user;
    GRANT ALL ON ALL ROUTINES IN SCHEMA auth TO dashboard_user;
    GRANT ALL ON ALL ROUTINES IN SCHEMA storage TO dashboard_user;
    GRANT ALL ON ALL ROUTINES IN SCHEMA extensions TO dashboard_user;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20211115181400_update-auth-permissions.sql

    -- update auth schema permissions
    GRANT ALL PRIVILEGES ON SCHEMA auth TO supabase_auth_admin;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA auth TO supabase_auth_admin;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA auth TO supabase_auth_admin;

    ALTER table IF EXISTS "auth".users OWNER TO supabase_auth_admin;
    ALTER table IF EXISTS "auth".refresh_tokens OWNER TO supabase_auth_admin;
    ALTER table IF EXISTS "auth".audit_log_entries OWNER TO supabase_auth_admin;
    ALTER table IF EXISTS "auth".instances OWNER TO supabase_auth_admin;
    ALTER table IF EXISTS "auth".schema_migrations OWNER TO supabase_auth_admin;

    GRANT USAGE ON SCHEMA auth TO postgres;
    GRANT ALL ON ALL TABLES IN SCHEMA auth TO postgres, dashboard_user;
    GRANT ALL ON ALL SEQUENCES IN SCHEMA auth TO postgres, dashboard_user;
    GRANT ALL ON ALL ROUTINES IN SCHEMA auth TO postgres, dashboard_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON TABLES TO postgres, dashboard_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON SEQUENCES TO postgres, dashboard_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin IN SCHEMA auth GRANT ALL ON ROUTINES TO postgres, dashboard_user;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20211118015519_create-realtime-schema.sql

    -- create realtime schema for Realtime RLS (WALRUS)
    CREATE SCHEMA IF NOT EXISTS _realtime;
    CREATE SCHEMA IF NOT EXISTS realtime;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20211122051245_update-realtime-permissions.sql

    -- update realtime schema permissions
    GRANT USAGE ON SCHEMA realtime TO postgres;
    GRANT ALL ON ALL TABLES IN SCHEMA realtime TO postgres, dashboard_user;
    GRANT ALL ON ALL SEQUENCES IN SCHEMA realtime TO postgres, dashboard_user;
    GRANT ALL ON ALL ROUTINES IN SCHEMA realtime TO postgres, dashboard_user;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20211124212715_update-auth-owner.sql

    -- update owner for auth.uid, auth.role and auth.email functions
    ALTER FUNCTION auth.uid owner to supabase_auth_admin;
    ALTER FUNCTION auth.role owner to supabase_auth_admin;
    ALTER FUNCTION auth.email owner to supabase_auth_admin;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20211130151719_update-realtime-permissions.sql

    -- Update future objects' permissions
    ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA realtime GRANT ALL ON TABLES TO postgres, dashboard_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA realtime GRANT ALL ON SEQUENCES TO postgres, dashboard_user;
    ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA realtime GRANT ALL ON ROUTINES TO postgres, dashboard_user;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20220118070449_enable-safeupdate-postgrest.sql

    ALTER ROLE authenticator SET session_preload_libraries = 'safeupdate';

    -- migrate:down

    -- migrate:up migrations/db/migrations/20220126121436_finer-postgrest-triggers.sql

    drop event trigger if exists api_restart;
    drop function if exists extensions.notify_api_restart();

    -- https://postgrest.org/en/latest/schema_cache.html#finer-grained-event-trigger
    -- watch create and alter
    CREATE OR REPLACE FUNCTION extensions.pgrst_ddl_watch() RETURNS event_trigger AS $$
    DECLARE
    cmd record;
    BEGIN
    FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        IF cmd.command_tag IN (
        'CREATE SCHEMA', 'ALTER SCHEMA'
        , 'CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO', 'ALTER TABLE'
        , 'CREATE FOREIGN TABLE', 'ALTER FOREIGN TABLE'
        , 'CREATE VIEW', 'ALTER VIEW'
        , 'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW'
        , 'CREATE FUNCTION', 'ALTER FUNCTION'
        , 'CREATE TRIGGER'
        , 'CREATE TYPE'
        , 'CREATE RULE'
        , 'COMMENT'
        )
        -- don't notify in case of CREATE TEMP table or other objects created on pg_temp
        AND cmd.schema_name is distinct from 'pg_temp'
        THEN
        NOTIFY pgrst, 'reload schema';
        END IF;
    END LOOP;
    END; $$ LANGUAGE plpgsql;

    -- watch drop
    CREATE OR REPLACE FUNCTION extensions.pgrst_drop_watch() RETURNS event_trigger AS $$
    DECLARE
    obj record;
    BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects()
    LOOP
        IF obj.object_type IN (
        'schema'
        , 'table'
        , 'foreign table'
        , 'view'
        , 'materialized view'
        , 'function'
        , 'trigger'
        , 'type'
        , 'rule'
        )
        AND obj.is_temporary IS false -- no pg_temp objects
        THEN
        NOTIFY pgrst, 'reload schema';
        END IF;
    END LOOP;
    END; $$ LANGUAGE plpgsql;

    DROP EVENT TRIGGER IF EXISTS pgrst_ddl_watch;
    CREATE EVENT TRIGGER pgrst_ddl_watch
    ON ddl_command_end
    EXECUTE PROCEDURE extensions.pgrst_ddl_watch();

    DROP EVENT TRIGGER IF EXISTS pgrst_drop_watch;
    CREATE EVENT TRIGGER pgrst_drop_watch
    ON sql_drop
    EXECUTE PROCEDURE extensions.pgrst_drop_watch();


    -- migrate:down

    -- migrate:up migrations/db/migrations/20220224211803_fix-postgrest-supautils.sql

    -- Note: supatils extension is not installed in docker image.

    DO $$
    DECLARE
    supautils_exists boolean;
    BEGIN
    supautils_exists = (
        select count(*) = 1
        from pg_available_extensions
        where name = 'supautils'
    );

    IF supautils_exists
    THEN
    ALTER ROLE authenticator SET session_preload_libraries = supautils, safeupdate;
    END IF;
    END $$;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20220317095840_pg_graphql.sql

    create schema if not exists graphql_public;

    -- GraphQL Placeholder Entrypoint
    create or replace function graphql_public.graphql(
        "operationName" text default null,
        query text default null,
        variables jsonb default null,
        extensions jsonb default null
    )
        returns jsonb
        language plpgsql
    as $$
        DECLARE
            server_version float;
        BEGIN
            server_version = (SELECT (SPLIT_PART((select version()), ' ', 2))::float);

            IF server_version >= 14 THEN
                RETURN jsonb_build_object(
                    'data', null::jsonb,
                    'errors', array['pg_graphql extension is not enabled.']
                );
            ELSE
                RETURN jsonb_build_object(
                    'data', null::jsonb,
                    'errors', array['pg_graphql is only available on projects running Postgres 14 onwards.']
                );
            END IF;
        END;
    $$;

    grant usage on schema graphql_public to postgres, anon, authenticated, service_role;
    alter default privileges in schema graphql_public grant all on tables to postgres, anon, authenticated, service_role;
    alter default privileges in schema graphql_public grant all on functions to postgres, anon, authenticated, service_role;
    alter default privileges in schema graphql_public grant all on sequences to postgres, anon, authenticated, service_role;

    alter default privileges for user supabase_admin in schema graphql_public grant all
        on sequences to postgres, anon, authenticated, service_role;
    alter default privileges for user supabase_admin in schema graphql_public grant all
        on tables to postgres, anon, authenticated, service_role;
    alter default privileges for user supabase_admin in schema graphql_public grant all
        on functions to postgres, anon, authenticated, service_role;

    -- Trigger upon enabling pg_graphql
    CREATE OR REPLACE FUNCTION extensions.grant_pg_graphql_access()
    RETURNS event_trigger
    LANGUAGE plpgsql
    AS $func$
        DECLARE
        func_is_graphql_resolve bool;
        BEGIN
        func_is_graphql_resolve = (
            SELECT n.proname = 'resolve'
            FROM pg_event_trigger_ddl_commands() AS ev
            LEFT JOIN pg_catalog.pg_proc AS n
            ON ev.objid = n.oid
        );

        IF func_is_graphql_resolve
        THEN
            grant usage on schema graphql to postgres, anon, authenticated, service_role;
            grant all on function graphql.resolve to postgres, anon, authenticated, service_role;

            alter default privileges in schema graphql grant all on tables to postgres, anon, authenticated, service_role;
            alter default privileges in schema graphql grant all on functions to postgres, anon, authenticated, service_role;
            alter default privileges in schema graphql grant all on sequences to postgres, anon, authenticated, service_role;

            DROP FUNCTION IF EXISTS graphql_public.graphql;
            create or replace function graphql_public.graphql(
                "operationName" text default null,
                query text default null,
                variables jsonb default null,
                extensions jsonb default null
            )
                returns jsonb
                language sql
            as $$
                SELECT graphql.resolve(query, coalesce(variables, '{}'));
            $$;

            grant execute on function graphql.resolve to postgres, anon, authenticated, service_role;
        END IF;

        END;
    $func$;

    DROP EVENT TRIGGER IF EXISTS issue_pg_graphql_access;
    CREATE EVENT TRIGGER issue_pg_graphql_access ON ddl_command_end WHEN TAG in ('CREATE FUNCTION')
    EXECUTE PROCEDURE extensions.grant_pg_graphql_access();
    COMMENT ON FUNCTION extensions.grant_pg_graphql_access IS 'Grants access to pg_graphql';

    -- Trigger upon dropping the pg_graphql extension
    CREATE OR REPLACE FUNCTION extensions.set_graphql_placeholder()
    RETURNS event_trigger
    LANGUAGE plpgsql
    AS $func$
        DECLARE
        graphql_is_dropped bool;
        BEGIN
        graphql_is_dropped = (
            SELECT ev.schema_name = 'graphql_public'
            FROM pg_event_trigger_dropped_objects() AS ev
            WHERE ev.schema_name = 'graphql_public'
        );

        IF graphql_is_dropped
        THEN
            create or replace function graphql_public.graphql(
                "operationName" text default null,
                query text default null,
                variables jsonb default null,
                extensions jsonb default null
            )
                returns jsonb
                language plpgsql
            as $$
                DECLARE
                    server_version float;
                BEGIN
                    server_version = (SELECT (SPLIT_PART((select version()), ' ', 2))::float);

                    IF server_version >= 14 THEN
                        RETURN jsonb_build_object(
                            'data', null::jsonb,
                            'errors', array['pg_graphql extension is not enabled.']
                        );
                    ELSE
                        RETURN jsonb_build_object(
                            'data', null::jsonb,
                            'errors', array['pg_graphql is only available on projects running Postgres 14 onwards.']
                        );
                    END IF;
                END;
            $$;
        END IF;

        END;
    $func$;

    DROP EVENT TRIGGER IF EXISTS issue_graphql_placeholder;
    CREATE EVENT TRIGGER issue_graphql_placeholder ON sql_drop WHEN TAG in ('DROP EXTENSION')
    EXECUTE PROCEDURE extensions.set_graphql_placeholder();
    COMMENT ON FUNCTION extensions.set_graphql_placeholder IS 'Reintroduces placeholder function for graphql_public.graphql';

    -- migrate:down

    -- migrate:up migrations/db/migrations/20220321174452_fix-postgrest-alter-type-event-trigger.sql

    drop event trigger if exists api_restart;
    drop function if exists extensions.notify_api_restart();

    -- https://postgrest.org/en/latest/schema_cache.html#finer-grained-event-trigger
    -- watch create and alter
    CREATE OR REPLACE FUNCTION extensions.pgrst_ddl_watch() RETURNS event_trigger AS $$
    DECLARE
    cmd record;
    BEGIN
    FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        IF cmd.command_tag IN (
        'CREATE SCHEMA', 'ALTER SCHEMA'
        , 'CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO', 'ALTER TABLE'
        , 'CREATE FOREIGN TABLE', 'ALTER FOREIGN TABLE'
        , 'CREATE VIEW', 'ALTER VIEW'
        , 'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW'
        , 'CREATE FUNCTION', 'ALTER FUNCTION'
        , 'CREATE TRIGGER'
        , 'CREATE TYPE', 'ALTER TYPE'
        , 'CREATE RULE'
        , 'COMMENT'
        )
        -- don't notify in case of CREATE TEMP table or other objects created on pg_temp
        AND cmd.schema_name is distinct from 'pg_temp'
        THEN
        NOTIFY pgrst, 'reload schema';
        END IF;
    END LOOP;
    END; $$ LANGUAGE plpgsql;

    -- watch drop
    CREATE OR REPLACE FUNCTION extensions.pgrst_drop_watch() RETURNS event_trigger AS $$
    DECLARE
    obj record;
    BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects()
    LOOP
        IF obj.object_type IN (
        'schema'
        , 'table'
        , 'foreign table'
        , 'view'
        , 'materialized view'
        , 'function'
        , 'trigger'
        , 'type'
        , 'rule'
        )
        AND obj.is_temporary IS false -- no pg_temp objects
        THEN
        NOTIFY pgrst, 'reload schema';
        END IF;
    END LOOP;
    END; $$ LANGUAGE plpgsql;

    DROP EVENT TRIGGER IF EXISTS pgrst_ddl_watch;
    CREATE EVENT TRIGGER pgrst_ddl_watch
    ON ddl_command_end
    EXECUTE PROCEDURE extensions.pgrst_ddl_watch();

    DROP EVENT TRIGGER IF EXISTS pgrst_drop_watch;
    CREATE EVENT TRIGGER pgrst_drop_watch
    ON sql_drop
    EXECUTE PROCEDURE extensions.pgrst_drop_watch();


    -- migrate:down

    -- migrate:up migrations/db/migrations/20220322085208_gotrue-session-limit.sql

    ALTER ROLE supabase_auth_admin SET idle_in_transaction_session_timeout TO 60000;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20220404205710_pg_graphql-on-by-default.sql

    -- Update Trigger upon enabling pg_graphql
    create or replace function extensions.grant_pg_graphql_access()
        returns event_trigger
        language plpgsql
    AS $func$
    DECLARE
        func_is_graphql_resolve bool;
    BEGIN
        func_is_graphql_resolve = (
            SELECT n.proname = 'resolve'
            FROM pg_event_trigger_ddl_commands() AS ev
            LEFT JOIN pg_catalog.pg_proc AS n
            ON ev.objid = n.oid
        );

        IF func_is_graphql_resolve
        THEN
            grant usage on schema graphql to postgres, anon, authenticated, service_role;
            grant all on function graphql.resolve to postgres, anon, authenticated, service_role;

            alter default privileges in schema graphql grant all on tables to postgres, anon, authenticated, service_role;
            alter default privileges in schema graphql grant all on functions to postgres, anon, authenticated, service_role;
            alter default privileges in schema graphql grant all on sequences to postgres, anon, authenticated, service_role;

            -- Update public wrapper to pass all arguments through to the pg_graphql resolve func
            DROP FUNCTION IF EXISTS graphql_public.graphql;
            create or replace function graphql_public.graphql(
                "operationName" text default null,
                query text default null,
                variables jsonb default null,
                extensions jsonb default null
            )
                returns jsonb
                language sql
            as $$
                -- This changed
                select graphql.resolve(
                    query := query,
                    variables := coalesce(variables, '{}'),
                    "operationName" := "operationName",
                    extensions := extensions
                );
            $$;

            grant execute on function graphql.resolve to postgres, anon, authenticated, service_role;
        END IF;

    END;
    $func$;

    CREATE OR REPLACE FUNCTION extensions.set_graphql_placeholder()
    RETURNS event_trigger
    LANGUAGE plpgsql
    AS $func$
        DECLARE
        graphql_is_dropped bool;
        BEGIN
        graphql_is_dropped = (
            SELECT ev.schema_name = 'graphql_public'
            FROM pg_event_trigger_dropped_objects() AS ev
            WHERE ev.schema_name = 'graphql_public'
        );

        IF graphql_is_dropped
        THEN
            create or replace function graphql_public.graphql(
                "operationName" text default null,
                query text default null,
                variables jsonb default null,
                extensions jsonb default null
            )
                returns jsonb
                language plpgsql
            as $$
                DECLARE
                    server_version float;
                BEGIN
                    server_version = (SELECT (SPLIT_PART((select version()), ' ', 2))::float);

                    IF server_version >= 14 THEN
                        RETURN jsonb_build_object(
                            'errors', jsonb_build_array(
                                jsonb_build_object(
                                    'message', 'pg_graphql extension is not enabled.'
                                )
                            )
                        );
                    ELSE
                        RETURN jsonb_build_object(
                            'errors', jsonb_build_array(
                                jsonb_build_object(
                                    'message', 'pg_graphql is only available on projects running Postgres 14 onwards.'
                                )
                            )
                        );
                    END IF;
                END;
            $$;
        END IF;

        END;
    $func$;

    -- GraphQL Placeholder Entrypoint
    create or replace function graphql_public.graphql(
        "operationName" text default null,
        query text default null,
        variables jsonb default null,
        extensions jsonb default null
    )
        returns jsonb
        language plpgsql
    as $$
        DECLARE
            server_version float;
        BEGIN
            server_version = (SELECT (SPLIT_PART((select version()), ' ', 2))::float);

            IF server_version >= 14 THEN
                RETURN jsonb_build_object(
                    'errors', jsonb_build_array(
                        jsonb_build_object(
                            'message', 'pg_graphql extension is not enabled.'
                        )
                    )
                );
            ELSE
                RETURN jsonb_build_object(
                    'errors', jsonb_build_array(
                        jsonb_build_object(
                            'message', 'pg_graphql is only available on projects running Postgres 14 onwards.'
                        )
                    )
                );
            END IF;
        END;
    $$;


    drop extension if exists pg_graphql;
    -- Avoids limitation of only being able to load the extension via dashboard
    -- Only install as well if the extension is actually installed
    DO $$
    DECLARE
    graphql_exists boolean;
    BEGIN
    graphql_exists = (
        select count(*) = 1
        from pg_available_extensions
        where name = 'pg_graphql'
    );

    IF graphql_exists
    THEN
    create extension if not exists pg_graphql;
    END IF;
    END $$;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20220609081115_grant-supabase-auth-admin-and-supabase-storage-admin-to-postgres.sql

    -- This is done so that the `postgres` role can manage auth tables triggers,
    -- storage tables policies, etc. which unblocks the revocation of superuser
    -- access.
    --
    -- More context: https://www.notion.so/supabase/RFC-Postgres-Permissions-I-40cb4f61bd4145fd9e75ce657c0e31dd#bf5d853436384e6e8e339d0a2e684cbb
    grant supabase_auth_admin, supabase_storage_admin to postgres;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20220613123923_pg_graphql-pg-dump-perms.sql

    create or replace function extensions.grant_pg_graphql_access()
        returns event_trigger
        language plpgsql
    AS $func$
    DECLARE
        func_is_graphql_resolve bool;
    BEGIN
        func_is_graphql_resolve = (
            SELECT n.proname = 'resolve'
            FROM pg_event_trigger_ddl_commands() AS ev
            LEFT JOIN pg_catalog.pg_proc AS n
            ON ev.objid = n.oid
        );

        IF func_is_graphql_resolve
        THEN
            -- Update public wrapper to pass all arguments through to the pg_graphql resolve func
            DROP FUNCTION IF EXISTS graphql_public.graphql;
            create or replace function graphql_public.graphql(
                "operationName" text default null,
                query text default null,
                variables jsonb default null,
                extensions jsonb default null
            )
                returns jsonb
                language sql
            as $$
                select graphql.resolve(
                    query := query,
                    variables := coalesce(variables, '{}'),
                    "operationName" := "operationName",
                    extensions := extensions
                );
            $$;

            -- This hook executes when `graphql.resolve` is created. That is not necessarily the last
            -- function in the extension so we need to grant permissions on existing entities AND
            -- update default permissions to any others that are created after `graphql.resolve`
            grant usage on schema graphql to postgres, anon, authenticated, service_role;
            grant select on all tables in schema graphql to postgres, anon, authenticated, service_role;
            grant execute on all functions in schema graphql to postgres, anon, authenticated, service_role;
            grant all on all sequences in schema graphql to postgres, anon, authenticated, service_role;
            alter default privileges in schema graphql grant all on tables to postgres, anon, authenticated, service_role;
            alter default privileges in schema graphql grant all on functions to postgres, anon, authenticated, service_role;
            alter default privileges in schema graphql grant all on sequences to postgres, anon, authenticated, service_role;
        END IF;

    END;
    $func$;

    -- Cycle the extension off and back on to apply the permissions update.

    drop extension if exists pg_graphql;
    -- Avoids limitation of only being able to load the extension via dashboard
    -- Only install as well if the extension is actually installed
    DO $$
    DECLARE
    graphql_exists boolean;
    BEGIN
    graphql_exists = (
        select count(*) = 1 
        from pg_available_extensions 
        where name = 'pg_graphql'
    );

    IF graphql_exists 
    THEN
    create extension if not exists pg_graphql;
    END IF;
    END $$;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20220713082019_pg_cron-pg_net-temp-perms-fix.sql
    DO $$
    DECLARE
    pg_cron_installed boolean;
    BEGIN
    -- checks if pg_cron is enabled   
    pg_cron_installed = (
        select count(*) = 1 
        from pg_available_extensions 
        where name = 'pg_cron'
        and installed_version is not null
    );

    IF pg_cron_installed
    THEN
        grant usage on schema cron to postgres with grant option;
        grant all on all functions in schema cron to postgres with grant option;

        alter default privileges in schema cron grant all on tables to postgres with grant option;
        alter default privileges in schema cron grant all on functions to postgres with grant option;
        alter default privileges in schema cron grant all on sequences to postgres with grant option;

        alter default privileges for user supabase_admin in schema cron grant all
            on sequences to postgres with grant option;
        alter default privileges for user supabase_admin in schema cron grant all
            on tables to postgres with grant option;
        alter default privileges for user supabase_admin in schema cron grant all
            on functions to postgres with grant option;

        grant all privileges on all tables in schema cron to postgres with grant option; 
    END IF;
    END $$;

    DO $$
    DECLARE
    pg_net_installed boolean;
    BEGIN
    -- checks if pg_net is enabled
    pg_net_installed = (
        select count(*) = 1 
        from pg_available_extensions 
        where name = 'pg_net'
        and installed_version is not null
        
    );

    IF pg_net_installed 
    THEN
        IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'supabase_functions_admin'
        )
        THEN
        CREATE USER supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION;
        END IF;

        GRANT USAGE ON SCHEMA net TO supabase_functions_admin, postgres, anon, authenticated, service_role;

        ALTER function net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) SECURITY DEFINER;
        ALTER function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) SECURITY DEFINER;

        ALTER function net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) SET search_path = net;
        ALTER function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) SET search_path = net;

        REVOKE ALL ON FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) FROM PUBLIC;
        REVOKE ALL ON FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) FROM PUBLIC;

        GRANT EXECUTE ON FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) TO supabase_functions_admin, postgres, anon, authenticated, service_role;
        GRANT EXECUTE ON FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) TO supabase_functions_admin, postgres, anon, authenticated, service_role;
    END IF;
    END $$;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20221028101028_set_authenticator_timeout.sql

    alter role authenticator set statement_timeout = '8s';

    -- migrate:down

    -- migrate:up migrations/db/migrations/20221103090837_revoke_admin.sql
    revoke supabase_admin from authenticator;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20221207154255_create_pgsodium_and_vault.sql

    DO $$
    DECLARE
    pgsodium_exists boolean;
    vault_exists boolean;
    BEGIN
    pgsodium_exists = (
        select count(*) = 1 
        from pg_available_extensions 
        where name = 'pgsodium'
    );
    
    vault_exists = (
        select count(*) = 1 
        from pg_available_extensions 
        where name = 'supabase_vault'
    );

    IF pgsodium_exists 
    THEN
        create extension if not exists pgsodium;

        grant pgsodium_keyiduser to postgres with admin option;
        grant pgsodium_keyholder to postgres with admin option;
        grant pgsodium_keymaker  to postgres with admin option;

        grant execute on function pgsodium.crypto_aead_det_decrypt(bytea, bytea, uuid, bytea) to service_role;
        grant execute on function pgsodium.crypto_aead_det_encrypt(bytea, bytea, uuid, bytea) to service_role;
        grant execute on function pgsodium.crypto_aead_det_keygen to service_role;

        IF vault_exists
        THEN
        create extension if not exists supabase_vault;
        END IF;
    END IF;
    END $$;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20230201083204_grant_auth_roles_to_postgres.sql

    grant anon, authenticated, service_role to postgres;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20230224042246_grant_extensions_perms_for_postgres.sql

    grant all privileges on all tables in schema extensions to postgres with grant option;
    grant all privileges on all routines in schema extensions to postgres with grant option;
    grant all privileges on all sequences in schema extensions to postgres with grant option;
    alter default privileges in schema extensions grant all on tables to postgres with grant option;
    alter default privileges in schema extensions grant all on routines to postgres with grant option;
    alter default privileges in schema extensions grant all on sequences to postgres with grant option;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20230306081037_grant_pg_monitor_to_postgres.sql

    grant pg_monitor to postgres;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20230327032006_grant_auth_roles_to_supabase_storage_admin.sql
    grant anon, authenticated, service_role to supabase_storage_admin;

    -- migrate:down

    -- migrate:up migrations/db/migrations/20230529180330_alter_api_roles_for_inherit.sql

    ALTER ROLE authenticated inherit;
    ALTER ROLE anon inherit;
    ALTER ROLE service_role inherit;

    GRANT pgsodium_keyholder to service_role;

    -- migrate:down

    -- migrate:up migrations/db/migrations/10000000000000_demote-postgres.sql

    -- demote postgres user
    GRANT ALL ON DATABASE postgres TO postgres;
    GRANT ALL ON SCHEMA auth TO postgres;
    GRANT ALL ON SCHEMA extensions TO postgres;
    GRANT ALL ON SCHEMA storage TO postgres;
    GRANT ALL ON ALL TABLES IN SCHEMA auth TO postgres;
    GRANT ALL ON ALL TABLES IN SCHEMA storage TO postgres;
    GRANT ALL ON ALL TABLES IN SCHEMA extensions TO postgres;
    GRANT ALL ON ALL SEQUENCES IN SCHEMA auth TO postgres;
    GRANT ALL ON ALL SEQUENCES IN SCHEMA storage TO postgres;
    GRANT ALL ON ALL SEQUENCES IN SCHEMA extensions TO postgres;
    GRANT ALL ON ALL ROUTINES IN SCHEMA auth TO postgres;
    GRANT ALL ON ALL ROUTINES IN SCHEMA storage TO postgres;
    GRANT ALL ON ALL ROUTINES IN SCHEMA extensions TO postgres;
    -- ALTER ROLE postgres NOSUPERUSER CREATEDB CREATEROLE LOGIN REPLICATION BYPASSRLS;

    -- migrate:down
```
