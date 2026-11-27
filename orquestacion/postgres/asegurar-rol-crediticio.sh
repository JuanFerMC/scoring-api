#!/bin/sh
# Asegura, en cada despliegue, el rol de scoring-api y auth-api: lo crea si falta y sincroniza su contraseña con
# la del Secret/.env. Complementa a initdb/01-rol-crediticio.sh, que PostgreSQL solo ejecuta con el volumen vacío:
# si esa primera inicialización se interrumpe, el volumen queda con datos pero sin el rol. Seguro de repetir.
#
# Variables: PGHOST, PGDATABASE, PGUSER, PGPASSWORD (administrador), CREDITICIO_DB_USER, CREDITICIO_DB_PASSWORD.
set -eu

until pg_isready -q; do
    echo "Esperando PostgreSQL..."
    sleep 3
done

psql -v ON_ERROR_STOP=1 -q \
     -v rol="$CREDITICIO_DB_USER" -v clave="$CREDITICIO_DB_PASSWORD" -v base="$PGDATABASE" <<'EOSQL'
SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', :'rol')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'rol')
\gexec
ALTER ROLE :"rol" WITH LOGIN PASSWORD :'clave';
COMMENT ON ROLE :"rol" IS 'scoring-api y auth-api (entorno local): propietario de public';
GRANT CONNECT ON DATABASE :"base" TO :"rol";
-- Desde PostgreSQL 15 PUBLIC ya no puede crear objetos en public; el rol de las APIs pasa a ser su propietario.
ALTER SCHEMA public OWNER TO :"rol";
EOSQL

echo "Rol $CREDITICIO_DB_USER asegurado como propietario del esquema public de $PGDATABASE"
