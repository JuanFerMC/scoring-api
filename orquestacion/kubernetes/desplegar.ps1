<#
.SYNOPSIS
  Despliega el entorno local integrado en el Kubernetes de Docker Desktop (namespace "crediticio").

.DESCRIPTION
  1. Comprueba el contexto de kubectl (docker-desktop) y el nodo.
  2. Construye las imágenes de las tres APIs con docker compose (una a la vez), salvo -OmitirConstruccion.
  3. Crea el Secret "crediticio-credenciales" desde orquestacion/.env (el mismo de Docker Compose).
  4. Genera las claves RSA en una carpeta temporal y crea los Secret "claves-auth", "claves-servicio-scoring" y
     "claves-publicas" (solo si no existen, para que los tokens emitidos sigan siendo válidos). La carpeta
     temporal se borra al terminar.
  5. Crea el ConfigMap "operacion-consulta" con los scripts SQL oficiales de evaluation-query-api.
  6. Aplica orquestacion/kustomization.yaml y espera a que cada pieza esté lista, en el orden del Compose.

  Ningún secreto se escribe en el repositorio ni se pasa por la línea de comandos.

.EXAMPLE
  .\desplegar.ps1
  .\desplegar.ps1 -OmitirConstruccion
  .\desplegar.ps1 -OmitirConstruccion -SinObservabilidad   # equipos con poca memoria: sin Prometheus ni Grafana
#>
[CmdletBinding()]
param(
    [switch] $OmitirConstruccion,
    # No despliega Prometheus ni Grafana (y los retira si ya estaban): PostgreSQL, las tres APIs y sus Jobs bastan
    # para la orquestación; la observabilidad sigue disponible en Docker Compose.
    [switch] $SinObservabilidad,
    [string] $Contexto = 'docker-desktop'
)

Set-StrictMode -Version Latest
$Namespace = 'crediticio'
$Orquestacion = Split-Path -Parent $PSScriptRoot
$Utf8SinBom = New-Object System.Text.UTF8Encoding($false)

function Paso([string] $texto) { Write-Host ''; Write-Host "==> $texto" -ForegroundColor Cyan }

function Fallar([string] $texto) { Write-Host "ERROR: $texto" -ForegroundColor Red; exit 1 }

# Ejecuta un comando externo y detiene el script si termina con error.
function Ejecutar([string] $descripcion, [scriptblock] $comando) {
    & $comando
    if ($LASTEXITCODE -ne 0) { Fallar "$descripcion (código $LASTEXITCODE)" }
}

function Existe([string] $tipo, [string] $nombre) {
    kubectl -n $Namespace get $tipo $nombre *> $null
    return ($LASTEXITCODE -eq 0)
}

# --- 1. Contexto ---------------------------------------------------------------------------------------------
Paso 'Comprobando kubectl y el contexto'
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { Fallar 'kubectl no está instalado o no está en el PATH.' }
$contextoActual = (kubectl config current-context) 2>$null
if ($contextoActual -ne $Contexto) {
    Fallar "El contexto actual de kubectl es '$contextoActual' y se esperaba '$Contexto'. Cámbialo con: kubectl config use-context $Contexto"
}
$nodos = (kubectl get nodes -o 'jsonpath={.items[*].metadata.name}') 2>$null
if ($LASTEXITCODE -ne 0) { Fallar 'No se pudo consultar el clúster. ¿Está Kubernetes activado y en verde en Docker Desktop?' }
Write-Host "Contexto: $contextoActual | Nodos: $nodos"
if ($nodos -ne 'docker-desktop') {
    Write-Host "AVISO: el clúster no es el nodo único 'docker-desktop' (modo kubeadm). Si usas el modo 'kind', las imágenes locales no son visibles para Kubernetes y los pods quedarán en ErrImageNeverPull: cambia el modo a kubeadm en Settings > Kubernetes." -ForegroundColor Yellow
}

# --- 2. Configuración desde .env -----------------------------------------------------------------------------
Paso 'Leyendo orquestacion/.env'
$archivoEnv = Join-Path $Orquestacion '.env'
if (-not (Test-Path $archivoEnv)) { Fallar "No existe $archivoEnv. Cópialo desde .env.example y complétalo." }
$cfg = @{}
foreach ($linea in Get-Content -LiteralPath $archivoEnv -Encoding UTF8) {
    if ($linea -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
        $valor = $Matches[2].Trim()
        # Misma semántica que Docker Compose: comillas simples o dobles que rodean el valor no forman parte de él.
        if ($valor.Length -ge 2 -and (($valor.StartsWith("'") -and $valor.EndsWith("'")) -or ($valor.StartsWith('"') -and $valor.EndsWith('"')))) {
            $valor = $valor.Substring(1, $valor.Length - 2)
        }
        $cfg[$Matches[1]] = $valor
    }
}
$porDefecto = @{
    POSTGRES_DB = 'db_scoring'; POSTGRES_ADMIN_USER = 'postgres'; CREDITICIO_DB_USER = 'crediticio_app'
    CONSULTA_APP_USER = 'consulta_app'; CONSULTA_MIGRADOR_USER = 'consulta_migrador'
    INIT_ADMIN_NOMBRE = 'Administrador'; GRAFANA_ADMIN_USER = 'admin'
    EVALUATION_QUERY_API_DIR = '../../evaluation-query-api'
}
foreach ($clave in $porDefecto.Keys) {
    if (-not $cfg.ContainsKey($clave) -or [string]::IsNullOrWhiteSpace($cfg[$clave])) { $cfg[$clave] = $porDefecto[$clave] }
}
$obligatorias = 'POSTGRES_ADMIN_PASSWORD', 'CREDITICIO_DB_PASSWORD', 'CONSULTA_APP_PASSWORD', 'CONSULTA_MIGRADOR_PASSWORD',
                'INIT_ADMIN_EMAIL', 'INIT_ADMIN_PASSWORD', 'METRICS_SCRAPER_PASSWORD', 'GRAFANA_ADMIN_PASSWORD'
$faltan = @($obligatorias | Where-Object { -not $cfg.ContainsKey($_) -or [string]::IsNullOrWhiteSpace($cfg[$_]) })
if ($faltan.Count -gt 0) { Fallar ("Faltan valores en .env: " + ($faltan -join ', ')) }

$dirQuery = $cfg['EVALUATION_QUERY_API_DIR']
if (-not [System.IO.Path]::IsPathRooted($dirQuery)) { $dirQuery = Join-Path $Orquestacion $dirQuery }
$sql01 = Join-Path $dirQuery 'docs/operacion/01-preparar-antes-de-migrar.sql'
$sql02 = Join-Path $dirQuery 'docs/operacion/02-permisos-despues-de-migrar.sql'
foreach ($sql in $sql01, $sql02) { if (-not (Test-Path -LiteralPath $sql)) { Fallar "No se encontró $sql (revisa EVALUATION_QUERY_API_DIR en .env)." } }

# --- 3. Imágenes ---------------------------------------------------------------------------------------------
$compose = Join-Path $Orquestacion 'docker-compose.yml'
if ($OmitirConstruccion) {
    Paso 'Se omite la construcción de imágenes (-OmitirConstruccion)'
} else {
    foreach ($servicio in 'auth-api', 'scoring-api', 'evaluation-query-api') {
        Paso "Construyendo la imagen de $servicio"
        Ejecutar "docker compose build $servicio" { docker compose -f $compose build $servicio }
    }
}

# --- 4. Namespace y Secret de credenciales -------------------------------------------------------------------
Paso "Creando el namespace $Namespace"
Ejecutar 'kubectl apply namespace' { kubectl apply -f (Join-Path $PSScriptRoot 'namespace.yaml') }

Paso 'Creando el Secret crediticio-credenciales desde .env'
$clavesSecreto = 'POSTGRES_DB', 'POSTGRES_ADMIN_USER', 'POSTGRES_ADMIN_PASSWORD', 'CREDITICIO_DB_USER', 'CREDITICIO_DB_PASSWORD',
                 'CONSULTA_APP_USER', 'CONSULTA_APP_PASSWORD', 'CONSULTA_MIGRADOR_USER', 'CONSULTA_MIGRADOR_PASSWORD',
                 'INIT_ADMIN_EMAIL', 'INIT_ADMIN_PASSWORD', 'INIT_ADMIN_NOMBRE', 'METRICS_SCRAPER_PASSWORD',
                 'GRAFANA_ADMIN_USER', 'GRAFANA_ADMIN_PASSWORD'
$temporal = Join-Path ([System.IO.Path]::GetTempPath()) ("crediticio-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporal | Out-Null
try {
    $archivoSecreto = Join-Path $temporal 'credenciales.env'
    [System.IO.File]::WriteAllLines($archivoSecreto, [string[]]($clavesSecreto | ForEach-Object { "$_=$($cfg[$_])" }), $Utf8SinBom)
    kubectl -n $Namespace delete secret crediticio-credenciales --ignore-not-found | Out-Null
    Ejecutar 'kubectl create secret crediticio-credenciales' {
        kubectl -n $Namespace create secret generic crediticio-credenciales "--from-env-file=$archivoSecreto"
    }

    # --- 5. Claves RSA ---------------------------------------------------------------------------------------
    if ((Existe 'secret' 'claves-auth') -and (Existe 'secret' 'claves-servicio-scoring') -and (Existe 'secret' 'claves-publicas')) {
        Paso 'Las claves RSA ya existen en el clúster: se conservan'
    } else {
        Paso 'Generando claves RSA (contenedor alpine, carpeta temporal)'
        foreach ($sub in 'auth', 'servicio', 'publicas') { New-Item -ItemType Directory -Path (Join-Path $temporal $sub) | Out-Null }
        $script = Join-Path $Orquestacion 'claves/generar-claves.sh'
        Ejecutar 'generar claves RSA' {
            docker run --rm -v "${temporal}:/claves" -v "${script}:/scripts/generar-claves.sh:ro" alpine:3.20 sh /scripts/generar-claves.sh
        }
        foreach ($nombre in 'claves-auth', 'claves-servicio-scoring', 'claves-publicas') {
            kubectl -n $Namespace delete secret $nombre --ignore-not-found | Out-Null
        }
        $a = Join-Path $temporal 'auth'; $s = Join-Path $temporal 'servicio'; $p = Join-Path $temporal 'publicas'
        Ejecutar 'Secret claves-auth' {
            kubectl -n $Namespace create secret generic claves-auth "--from-file=jwt-privada.pem=$a/jwt-privada.pem" "--from-file=jwt-publica.pem=$a/jwt-publica.pem"
        }
        Ejecutar 'Secret claves-servicio-scoring' {
            kubectl -n $Namespace create secret generic claves-servicio-scoring "--from-file=scoring-service-private.pem=$s/scoring-service-private.pem" "--from-file=scoring-service-public.pem=$s/scoring-service-public.pem"
        }
        Ejecutar 'Secret claves-publicas' {
            kubectl -n $Namespace create secret generic claves-publicas "--from-file=jwt-publica.pem=$p/jwt-publica.pem" "--from-file=scoring-service-public.pem=$p/scoring-service-public.pem"
        }
    }
} finally {
    # Las credenciales y las claves privadas nunca quedan en disco fuera del clúster.
    Remove-Item -LiteralPath $temporal -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 6. Scripts SQL oficiales de evaluation-query-api --------------------------------------------------------
Paso 'Creando el ConfigMap operacion-consulta (scripts SQL oficiales de evaluation-query-api)'
kubectl -n $Namespace delete configmap operacion-consulta --ignore-not-found | Out-Null
Ejecutar 'kubectl create configmap operacion-consulta' {
    kubectl -n $Namespace create configmap operacion-consulta "--from-file=01-preparar-antes-de-migrar.sql=$sql01" "--from-file=02-permisos-despues-de-migrar.sql=$sql02"
}

# --- 7. Aplicar ----------------------------------------------------------------------------------------------
Paso 'Aplicando los manifiestos (kubectl apply -k)'
# Un Job no admite cambios una vez creado; sus scripts son seguros de repetir, así que se recrean.
kubectl -n $Namespace delete job rol-crediticio consulta-preparar consulta-permisos --ignore-not-found | Out-Null
$selectorObservabilidad = 'app.kubernetes.io/component=observabilidad'
if ($SinObservabilidad) {
    Ejecutar 'kubectl apply -k (sin observabilidad)' { kubectl apply -k $Orquestacion -l 'app.kubernetes.io/component!=observabilidad' }
    # Por etiqueta (ConfigMap generados) y por nombre: los objetos creados antes de existir la etiqueta no la tienen.
    kubectl -n $Namespace delete deployment,service,configmap -l $selectorObservabilidad --ignore-not-found
    kubectl -n $Namespace delete deployment/prometheus deployment/grafana service/prometheus service/grafana --ignore-not-found
} else {
    Ejecutar 'kubectl apply -k' { kubectl apply -k $Orquestacion }
}

# --- 8. Esperar en el orden del Compose ----------------------------------------------------------------------
$esperas = @(
    @{ desc = 'PostgreSQL';                     cmd = { kubectl -n $Namespace rollout status statefulset/postgres --timeout=600s } },
    @{ desc = 'Job rol-crediticio';             cmd = { kubectl -n $Namespace wait --for=condition=complete job/rol-crediticio --timeout=300s } },
    @{ desc = 'scoring-api (migra public)';     cmd = { kubectl -n $Namespace rollout status deployment/scoring-api --timeout=1800s } },
    @{ desc = 'auth-api';                       cmd = { kubectl -n $Namespace rollout status deployment/auth-api --timeout=1800s } },
    @{ desc = 'Job consulta-preparar';          cmd = { kubectl -n $Namespace wait --for=condition=complete job/consulta-preparar --timeout=1800s } },
    @{ desc = 'evaluation-query-api';           cmd = { kubectl -n $Namespace rollout status deployment/evaluation-query-api --timeout=1800s } },
    @{ desc = 'Job consulta-permisos';          cmd = { kubectl -n $Namespace wait --for=condition=complete job/consulta-permisos --timeout=1800s } },
    @{ desc = 'Prometheus'; obs = $true;        cmd = { kubectl -n $Namespace rollout status deployment/prometheus --timeout=600s } },
    @{ desc = 'Grafana';    obs = $true;        cmd = { kubectl -n $Namespace rollout status deployment/grafana --timeout=600s } }
)
foreach ($espera in $esperas) {
    if ($SinObservabilidad -and $espera.ContainsKey('obs')) { continue }
    Paso "Esperando: $($espera.desc)"
    Ejecutar "Esperando $($espera.desc). Revisa: kubectl -n $Namespace get pods; kubectl -n $Namespace describe pod <pod>; kubectl -n $Namespace logs <pod>" $espera.cmd
}

Paso 'Despliegue completo'
kubectl -n $Namespace get pods,svc,jobs,pvc
Write-Host ''
Write-Host "Acceso desde el equipo: .\acceder.ps1  (port-forward a 127.0.0.1; detén antes Docker Compose)." -ForegroundColor Green
