#!/bin/bash
# Primera inicialización del volumen de PostgreSQL (docker-entrypoint-initdb.d; no se vuelve a ejecutar si el
# volumen ya tiene datos). Crea el rol que usan scoring-api y auth-api: propietario del esquema public, sin
# privilegios de superusuario. Igual que en el despliegue actual, ambas APIs comparten public y su historial
# Flyway (scoring-api V1–V13, auth-api V100–V111). Los roles de evaluation-query-api los crea después el
# script oficial 01-preparar-antes-de-migrar.sql (servicio consulta-preparar).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v rol="$CREDITICIO_DB_USER" -v clave="$CREDITICIO_DB_PASSWORD" -v base="$POSTGRES_DB" <<'EOSQL'
CREATE ROLE :"rol" LOGIN PASSWORD :'clave' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE :"rol" IS 'scoring-api y auth-api (entorno local): propietario de public';
GRANT CONNECT ON DATABASE :"base" TO :"rol";
-- Desde PostgreSQL 15 PUBLIC ya no puede crear objetos en public; el rol de las APIs pasa a ser su propietario.
ALTER SCHEMA public OWNER TO :"rol";
EOSQL

echo "Rol $CREDITICIO_DB_USER creado como propietario del esquema public de $POSTGRES_DB"
