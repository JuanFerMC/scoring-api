#!/bin/sh
# Genera las claves RSA del entorno local dentro de volúmenes Docker (nunca en el repositorio). Solo crea un par
# si no existe, así los tokens emitidos siguen siendo válidos entre reinicios. Para rotarlas:
#   docker compose down && docker volume rm crediticio_claves-auth crediticio_claves-servicio-scoring crediticio_claves-publicas
#
#   /claves/auth      -> solo auth-api:    jwt-privada.pem, jwt-publica.pem (tokens de usuario, RS256)
#   /claves/servicio  -> solo scoring-api: scoring-service-private.pem, scoring-service-public.pem (saga S1)
#   /claves/publicas  -> scoring-api y evaluation-query-api: únicamente las dos claves públicas
set -eu

if ! command -v openssl >/dev/null 2>&1; then
    apk add --no-cache openssl >/dev/null
fi

generar_par() {
    privada="$1"
    publica="$2"
    if [ -s "$privada" ] && [ -s "$publica" ]; then
        echo "Se conserva el par existente: $publica"
        return
    fi
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$privada" 2>/dev/null
    openssl pkey -in "$privada" -pubout -out "$publica"
    echo "Par RSA generado: $publica"
}

generar_par /claves/auth/jwt-privada.pem /claves/auth/jwt-publica.pem
generar_par /claves/servicio/scoring-service-private.pem /claves/servicio/scoring-service-public.pem

cp /claves/auth/jwt-publica.pem /claves/publicas/jwt-publica.pem
cp /claves/servicio/scoring-service-public.pem /claves/publicas/scoring-service-public.pem

# Las APIs corren con un usuario sin privilegios distinto de root: deben poder leer los PEM. Cada volumen con una
# clave privada se monta solo en la API dueña de esa clave y en modo de solo lectura.
chmod 0444 /claves/auth/*.pem /claves/servicio/*.pem /claves/publicas/*.pem
