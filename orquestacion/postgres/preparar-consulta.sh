#!/bin/sh
# Paso 1 de evaluation-query-api en el entorno local: ejecuta el script oficial
# evaluation-query-api/docs/operacion/01-preparar-antes-de-migrar.sql (montado en /operacion) solo si el esquema
# consulta todavía no existe, y asigna las contraseñas de los roles desde orquestacion/.env (el script oficial
# no las define: en producción se asignan con \password). Seguro de repetir en cada "docker compose up".
set -eu

ESQUEMA=consulta

existe=$(psql -v ON_ERROR_STOP=1 -tA -v esquema="$ESQUEMA" <<'EOSQL'
SELECT count(*) FROM pg_namespace WHERE nspname = :'esquema';
EOSQL
)

if [ "$existe" = "0" ]; then
    echo "Preparando el esquema $ESQUEMA con 01-preparar-antes-de-migrar.sql"
    psql -v ON_ERROR_STOP=1 \
         -v rol_app="$CONSULTA_APP_USER" -v rol_migrador="$CONSULTA_MIGRADOR_USER" \
         -v esquema="$ESQUEMA" -v base_esperada="$PGDATABASE" \
         -f /operacion/01-preparar-antes-de-migrar.sql
    # El script oficial termina sin error si la base no es la esperada: se comprueba que sí creó el esquema.
    creado=$(psql -tA -v esquema="$ESQUEMA" <<'EOSQL'
SELECT count(*) FROM pg_namespace WHERE nspname = :'esquema';
EOSQL
)
    if [ "$creado" != "1" ]; then
        echo "ERROR: 01-preparar-antes-de-migrar.sql no creó el esquema $ESQUEMA" >&2
        exit 1
    fi
else
    echo "El esquema $ESQUEMA ya existe; no se vuelve a ejecutar 01-preparar-antes-de-migrar.sql"
fi

psql -v ON_ERROR_STOP=1 -q \
     -v rol_app="$CONSULTA_APP_USER" -v clave_app="$CONSULTA_APP_PASSWORD" \
     -v rol_migrador="$CONSULTA_MIGRADOR_USER" -v clave_migrador="$CONSULTA_MIGRADOR_PASSWORD" <<'EOSQL'
ALTER ROLE :"rol_app" PASSWORD :'clave_app';
ALTER ROLE :"rol_migrador" PASSWORD :'clave_migrador';
EOSQL

echo "Roles $CONSULTA_APP_USER y $CONSULTA_MIGRADOR_USER listos"
