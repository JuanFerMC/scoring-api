#!/bin/sh
# Paso 2 de evaluation-query-api en el entorno local: ejecuta el script oficial
# evaluation-query-api/docs/operacion/02-permisos-despues-de-migrar.sql (montado en /operacion) cuando la API ya
# aplicó sus migraciones V1 y V2 con el rol migrador. Los GRANT son idempotentes: seguro de repetir.
set -eu

psql -v ON_ERROR_STOP=1 \
     -v rol_app="$CONSULTA_APP_USER" -v esquema=consulta -v base_esperada="$PGDATABASE" \
     -f /operacion/02-permisos-despues-de-migrar.sql

echo "Permisos de $CONSULTA_APP_USER sobre el esquema consulta aplicados"
