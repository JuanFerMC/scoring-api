<#
.SYNOPSIS
  Verificación de punta a punta de la seguridad JWT entre auth-api (Security-Module), scoring-api y
  evaluation-query-api, contra el sistema en marcha (Docker Compose o Kubernetes con acceder.ps1).

.DESCRIPTION
  Comprueba, con peticiones HTTP reales:
    1. Emisión: el token de auth-api es RS256 y trae iss, aud, sub (UUID), role, jti, iat y exp (<= 15 min).
    2. Aceptación del token real en las tres APIs.
    3. Rechazo (401) en las tres APIs de: token firmado con otra clave RSA, "alg":"none", HS256, escalada de rol
       manipulando el payload, token mal formado y petición sin token.
    4. Roles: 403 cuando el rol no está autorizado (analista y administrador, en las tres APIs).
    5. Sesión: rotación del refresh token, rechazo del refresh reutilizado (y revocación de la sesión), logout.
    6. Frontera de servicio: los endpoints /internal de evaluation-query-api rechazan un JWT de usuario.
    7. Desactivación: auth-api rechaza el token de un usuario desactivado (scoring-api y evaluation-query-api lo
       validan sin estado: se informa cuánto tiempo sigue vigente allí).
    8. Opcional (-EsperarExpiracion): un token real vencido se rechaza (espera ~16 min).

  Los tokens falsos se firman con claves generadas en el momento: nunca se usa ni se lee la clave privada real.
  El script no imprime tokens ni contraseñas. Crea un usuario analista temporal (correo único por ejecución) y lo
  deja desactivado al terminar.

.EXAMPLE
  .\verificar-jwt.ps1
  .\verificar-jwt.ps1 -EsperarExpiracion
#>
[CmdletBinding()]
param(
    [string] $AuthUrl = 'http://localhost:8081',
    [string] $ScoringUrl = 'http://localhost:8080',
    [string] $QueryUrl = 'http://localhost:8082',
    [string] $ArchivoEnv = (Join-Path (Split-Path -Parent $PSScriptRoot) '.env'),
    [string] $EmisorEsperado = 'crediticio-auth',
    [switch] $EsperarExpiracion
)

Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Http = [System.Net.Http.HttpClient]::new()
$Http.Timeout = [TimeSpan]::FromSeconds(60)
$Resultados = New-Object System.Collections.Generic.List[object]

# ------------------------------------------------------------------------------------------------------------
# Utilidades
# ------------------------------------------------------------------------------------------------------------
function Peticion([string] $metodo, [string] $url, [string] $bearer = $null, [string] $cuerpo = $null) {
    # Estado 0 = sin respuesta HTTP (fallo de transporte). Solo ese caso se reintenta una vez: un 401/403 nunca.
    for ($intento = 1; $intento -le 2; $intento++) {
        $msg = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($metodo), $url)
        # Conexión nueva por petición: HttpClient de .NET Framework reutiliza conexiones que el servidor ya cerró
        # por inactividad y la petición falla sin respuesta.
        $msg.Headers.ConnectionClose = $true
        if (-not [string]::IsNullOrEmpty($bearer)) { [void] $msg.Headers.TryAddWithoutValidation('Authorization', "Bearer $bearer") }
        # Un [string] con valor $null llega como '' en PowerShell: solo se adjunta cuerpo si hay contenido (un GET con
        # cuerpo lo rechaza HttpClient en .NET Framework).
        if (-not [string]::IsNullOrEmpty($cuerpo)) { $msg.Content = [System.Net.Http.StringContent]::new($cuerpo, $Utf8, 'application/json') }
        try {
            $resp = $Http.SendAsync($msg).GetAwaiter().GetResult()
            $texto = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return [pscustomobject]@{ Estado = [int] $resp.StatusCode; Cuerpo = $texto }
        } catch {
            $error0 = $_.Exception.GetBaseException().Message
            if ($intento -eq 1) { Start-Sleep -Seconds 2 }
        }
    }
    return [pscustomobject]@{ Estado = 0; Cuerpo = $error0 }
}

function Json($objeto) { return ($objeto | ConvertTo-Json -Compress -Depth 10) }

function B64UrlCodificar([byte[]] $bytes) { return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

function B64UrlDecodificar([string] $texto) {
    $t = $texto.Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    return $Utf8.GetString([Convert]::FromBase64String($t))
}

function Registrar([string] $grupo, [string] $prueba, [string] $esperado, [string] $obtenido, [bool] $ok, [string] $tipo = '') {
    if (-not $tipo) { $tipo = $(if ($ok) { 'OK' } else { 'FALLA' }) }
    $Resultados.Add([pscustomobject]@{ Grupo = $grupo; Prueba = $prueba; Esperado = $esperado; Obtenido = $obtenido; Resultado = $tipo })
    $color = switch ($tipo) { 'OK' { 'Green' } 'INFO' { 'Cyan' } default { 'Red' } }
    Write-Host ("[{0,-5}] {1,-12} {2}  (esperado: {3}; obtenido: {4})" -f $tipo, $grupo, $prueba, $esperado, $obtenido) -ForegroundColor $color
}

# Texto del resultado obtenido: el código HTTP o, si no hubo respuesta, el motivo del fallo de transporte.
function Obtenido($respuesta) {
    if ($respuesta.Estado -eq 0) { return "0 (sin respuesta HTTP: $($respuesta.Cuerpo))" }
    return [string] $respuesta.Estado
}

function Esperar([string] $grupo, [string] $prueba, $respuesta, [int[]] $estados) {
    $ok = $estados -contains $respuesta.Estado
    Registrar $grupo $prueba ($estados -join ' o ') (Obtenido $respuesta) $ok
}

# Un token es aceptado si supera la autenticación y la autorización (ni 401 ni 403, ni error de conexión/servidor).
function EsperarAceptado([string] $grupo, [string] $prueba, $respuesta) {
    $ok = ($respuesta.Estado -ge 200) -and ($respuesta.Estado -lt 500) -and ($respuesta.Estado -ne 401) -and ($respuesta.Estado -ne 403)
    Registrar $grupo $prueba 'aceptado (no 401/403)' (Obtenido $respuesta) $ok
}

function Login([string] $email, [string] $clave) {
    return Peticion 'POST' "$AuthUrl/api/v1/auth/login" $null (Json @{ email = $email; password = $clave })
}

function FirmarRs256([string] $cabeceraJson, [string] $payloadJson, $rsa) {
    $entrada = (B64UrlCodificar $Utf8.GetBytes($cabeceraJson)) + '.' + (B64UrlCodificar $Utf8.GetBytes($payloadJson))
    $firma = $rsa.SignData($Utf8.GetBytes($entrada), [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                           [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    return $entrada + '.' + (B64UrlCodificar $firma)
}

function FirmarHs256([string] $cabeceraJson, [string] $payloadJson, [byte[]] $secreto) {
    $entrada = (B64UrlCodificar $Utf8.GetBytes($cabeceraJson)) + '.' + (B64UrlCodificar $Utf8.GetBytes($payloadJson))
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($secreto)
    return $entrada + '.' + (B64UrlCodificar $hmac.ComputeHash($Utf8.GetBytes($entrada)))
}

function ClaveAleatoria() {
    $bytes = [byte[]]::new(18)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return 'Vf5!' + [Convert]::ToBase64String($bytes).Replace('+', 'x').Replace('/', 'y').TrimEnd('=')
}

# Rutas de prueba (GET sin efectos, o POST que la autorización rechaza antes de llegar al controlador).
$RutaAuth = "$AuthUrl/api/v1/auth/validate"
$RutaScoring = "$ScoringUrl/api/v1/politicas-clasificacion/vigente"
$RutaQuery = "$QueryUrl/api/v1/evaluaciones"
$Apis = [ordered]@{ 'auth-api' = $RutaAuth; 'scoring-api' = $RutaScoring; 'query-api' = $RutaQuery }

# ------------------------------------------------------------------------------------------------------------
# 0. Preparación
# ------------------------------------------------------------------------------------------------------------
Write-Host '==> Preparación' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $ArchivoEnv)) { Write-Host "No existe $ArchivoEnv" -ForegroundColor Red; exit 1 }
$cfg = @{}
foreach ($linea in Get-Content -LiteralPath $ArchivoEnv -Encoding UTF8) {
    if ($linea -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
        $v = $Matches[2].Trim()
        if ($v.Length -ge 2 -and (($v.StartsWith("'") -and $v.EndsWith("'")) -or ($v.StartsWith('"') -and $v.EndsWith('"')))) { $v = $v.Substring(1, $v.Length - 2) }
        $cfg[$Matches[1]] = $v
    }
}
foreach ($k in 'INIT_ADMIN_EMAIL', 'INIT_ADMIN_PASSWORD') {
    if (-not $cfg.ContainsKey($k) -or -not $cfg[$k]) { Write-Host "Falta $k en $ArchivoEnv" -ForegroundColor Red; exit 1 }
}
foreach ($u in $AuthUrl, $ScoringUrl, $QueryUrl) {
    $h = Peticion 'GET' "$u/actuator/health"
    if ($h.Estado -ne 200) { Write-Host "La API $u no responde (health = $($h.Estado)). ¿Está levantado el entorno y, en Kubernetes, activo acceder.ps1?" -ForegroundColor Red; exit 1 }
}

$loginAdmin = Login $cfg['INIT_ADMIN_EMAIL'] $cfg['INIT_ADMIN_PASSWORD']
if ($loginAdmin.Estado -ne 200) { Write-Host "No se pudo iniciar sesión como administrador (HTTP $($loginAdmin.Estado))." -ForegroundColor Red; exit 1 }
$tokenAdmin = ($loginAdmin.Cuerpo | ConvertFrom-Json).token

$emailAnalista = 'verificacion.jwt.' + (Get-Date -Format 'yyyyMMddHHmmss') + '@local.test'
$claveAnalista = ClaveAleatoria
$creado = Peticion 'POST' "$AuthUrl/api/v1/usuarios" $tokenAdmin (Json @{ nombre = 'Verificacion JWT (temporal)'; email = $emailAnalista; password = $claveAnalista; idRol = 2 })
if ($creado.Estado -ne 201) { Write-Host "No se pudo crear el analista temporal (HTTP $($creado.Estado)): $($creado.Cuerpo)" -ForegroundColor Red; exit 1 }
$idAnalista = ($creado.Cuerpo | ConvertFrom-Json).id
$loginAnalista = Login $emailAnalista $claveAnalista
if ($loginAnalista.Estado -ne 200) { Write-Host "No se pudo iniciar sesión como analista (HTTP $($loginAnalista.Estado))." -ForegroundColor Red; exit 1 }
$sesionAnalista = $loginAnalista.Cuerpo | ConvertFrom-Json
$tokenAnalista = $sesionAnalista.token
Write-Host "Administrador y analista temporal ($emailAnalista, id $idAnalista) con sesión iniciada."

try {
    # --------------------------------------------------------------------------------------------------------
    # 1. Emisión
    # --------------------------------------------------------------------------------------------------------
    Write-Host ''; Write-Host '==> 1. Emisión del token (auth-api)' -ForegroundColor Cyan
    $partes = $tokenAnalista.Split('.')
    $cabecera = (B64UrlDecodificar $partes[0]) | ConvertFrom-Json
    $payloadTexto = B64UrlDecodificar $partes[1]
    $payload = $payloadTexto | ConvertFrom-Json
    $nombres = @($payload.PSObject.Properties.Name)
    Registrar 'emision' 'algoritmo' 'RS256' $cabecera.alg ($cabecera.alg -eq 'RS256')
    Registrar 'emision' 'emisor (iss)' $EmisorEsperado $payload.iss ($payload.iss -eq $EmisorEsperado)
    $aud = @($payload.aud)
    Registrar 'emision' 'audiencias (aud)' 'scoring-api y evaluation-query-api' ($aud -join ',') (($aud -contains 'scoring-api') -and ($aud -contains 'evaluation-query-api'))
    $subEsUuid = $false; try { [void][guid]::Parse([string] $payload.sub); $subEsUuid = $true } catch {}
    Registrar 'emision' 'sujeto (sub) es UUID' 'UUID' $(if ($subEsUuid) { 'UUID' } else { 'no UUID' }) $subEsUuid
    Registrar 'emision' 'rol (role)' 'ANALISTA_CREDITO' $payload.role ($payload.role -eq 'ANALISTA_CREDITO')
    Registrar 'emision' 'identificador (jti)' 'presente' $(if ($nombres -contains 'jti') { 'presente' } else { 'ausente' }) ($nombres -contains 'jti')
    $vida = [long] $payload.exp - [long] $payload.iat
    Registrar 'emision' 'vida del token (exp - iat)' '<= 900 s' "$vida s" (($vida -gt 0) -and ($vida -le 900))

    # --------------------------------------------------------------------------------------------------------
    # 2. Aceptación del token real
    # --------------------------------------------------------------------------------------------------------
    Write-Host ''; Write-Host '==> 2. El token real de auth-api se acepta en las tres APIs' -ForegroundColor Cyan
    foreach ($api in $Apis.Keys) { EsperarAceptado 'aceptacion' "token del analista en $api" (Peticion 'GET' $Apis[$api] $tokenAnalista) }

    # --------------------------------------------------------------------------------------------------------
    # 3. Tokens inválidos
    # --------------------------------------------------------------------------------------------------------
    Write-Host ''; Write-Host '==> 3. Tokens inválidos: 401 en las tres APIs' -ForegroundColor Cyan
    $rsaAjena = [System.Security.Cryptography.RSACng]::new(2048)
    $payloadAdmin = $payloadTexto.Replace('"ANALISTA_CREDITO"', '"ADMINISTRADOR_RIESGO"')
    $falsos = [ordered]@{
        'firmado con otra clave RSA'           = FirmarRs256 '{"alg":"RS256","typ":"JWT"}' $payloadTexto $rsaAjena
        'sin firma ("alg":"none")'             = (B64UrlCodificar $Utf8.GetBytes('{"alg":"none","typ":"JWT"}')) + '.' + $partes[1] + '.'
        'HS256 con secreto inventado'          = FirmarHs256 '{"alg":"HS256","typ":"JWT"}' $payloadTexto ($Utf8.GetBytes((ClaveAleatoria) + (ClaveAleatoria)))
        'escalada de rol con la firma original' = $partes[0] + '.' + (B64UrlCodificar $Utf8.GetBytes($payloadAdmin)) + '.' + $partes[2]
        'mal formado'                          = 'esto.no-es.un-jwt'
    }
    foreach ($caso in $falsos.Keys) {
        foreach ($api in $Apis.Keys) { Esperar 'invalidos' "$caso -> $api" (Peticion 'GET' $Apis[$api] $falsos[$caso]) @(401) }
    }
    foreach ($api in $Apis.Keys) { Esperar 'invalidos' "sin token -> $api" (Peticion 'GET' $Apis[$api]) @(401) }

    # --------------------------------------------------------------------------------------------------------
    # 4. Roles y permisos
    # --------------------------------------------------------------------------------------------------------
    Write-Host ''; Write-Host '==> 4. Roles: 403 cuando el rol no está autorizado' -ForegroundColor Cyan
    Esperar 'roles' 'auth-api: analista lista usuarios (solo administrador)' (Peticion 'GET' "$AuthUrl/api/v1/usuarios" $tokenAnalista) @(403)
    EsperarAceptado 'roles' 'auth-api: administrador lista usuarios' (Peticion 'GET' "$AuthUrl/api/v1/usuarios" $tokenAdmin)
    Esperar 'roles' 'scoring-api: analista crea variable de riesgo (solo administrador)' (Peticion 'POST' "$ScoringUrl/api/v1/variables-riesgo" $tokenAnalista '{}') @(403)
    Esperar 'roles' 'scoring-api: administrador registra solicitante (solo analista)' (Peticion 'POST' "$ScoringUrl/api/v1/solicitantes" $tokenAdmin '{}') @(403)
    Esperar 'roles' 'query-api: administrador ve reporte de riesgo (solo analista)' (Peticion 'GET' "$QueryUrl/api/v1/reportes/distribucion-riesgo" $tokenAdmin) @(403)
    EsperarAceptado 'roles' 'query-api: analista ve reporte de riesgo' (Peticion 'GET' "$QueryUrl/api/v1/reportes/distribucion-riesgo" $tokenAnalista)
    Esperar 'roles' 'query-api: administrador exporta PDF (solo analista)' (Peticion 'POST' "$QueryUrl/api/v1/evaluaciones/export/pdf" $tokenAdmin '{"solicitanteIds":[1]}') @(403)

    # --------------------------------------------------------------------------------------------------------
    # 5. Sesión: refresh y logout
    # --------------------------------------------------------------------------------------------------------
    Write-Host ''; Write-Host '==> 5. Sesión: rotación del refresh token y logout' -ForegroundColor Cyan
    $refresh1 = $sesionAnalista.refreshToken
    $r = Peticion 'POST' "$AuthUrl/api/v1/auth/refresh" $null (Json @{ refreshToken = $refresh1 })
    Esperar 'sesion' 'refresh con el refresh token vigente' $r @(200)
    if ($r.Estado -eq 200) {
        $sesion2 = $r.Cuerpo | ConvertFrom-Json
        Registrar 'sesion' 'el refresh token rota (es distinto)' 'distinto' $(if ($sesion2.refreshToken -ne $refresh1) { 'distinto' } else { 'igual' }) ($sesion2.refreshToken -ne $refresh1)
        EsperarAceptado 'sesion' 'el nuevo access token sirve en query-api' (Peticion 'GET' $RutaQuery $sesion2.token)
        Esperar 'sesion' 'reutilizar el refresh token anterior' (Peticion 'POST' "$AuthUrl/api/v1/auth/refresh" $null (Json @{ refreshToken = $refresh1 })) @(401)
        Esperar 'sesion' 'tras la reutilización, la sesión queda revocada (refresh nuevo)' (Peticion 'POST' "$AuthUrl/api/v1/auth/refresh" $null (Json @{ refreshToken = $sesion2.refreshToken })) @(401)
    }
    $l = Login $emailAnalista $claveAnalista
    if ($l.Estado -eq 200) {
        $refresh3 = ($l.Cuerpo | ConvertFrom-Json).refreshToken
        Esperar 'sesion' 'logout' (Peticion 'POST' "$AuthUrl/api/v1/auth/logout" $null (Json @{ refreshToken = $refresh3 })) @(204)
        Esperar 'sesion' 'refresh tras el logout' (Peticion 'POST' "$AuthUrl/api/v1/auth/refresh" $null (Json @{ refreshToken = $refresh3 })) @(401)
    } else {
        Registrar 'sesion' 'nuevo login para probar logout' '200' ([string] $l.Estado) $false
    }

    # --------------------------------------------------------------------------------------------------------
    # 6. Frontera de servicio (saga scoring-api -> evaluation-query-api)
    # --------------------------------------------------------------------------------------------------------
    Write-Host ''; Write-Host '==> 6. Endpoints internos de query-api: solo token de servicio de scoring-api' -ForegroundColor Cyan
    $interna = "$QueryUrl/internal/v1/proyeccion/solicitantes/999999999"
    Esperar 'servicio' 'endpoint interno sin token' (Peticion 'PUT' $interna $null '{}') @(401, 403)
    Esperar 'servicio' 'endpoint interno con JWT de administrador' (Peticion 'PUT' $interna $tokenAdmin '{}') @(401, 403)
    Esperar 'servicio' 'endpoint interno con JWT de analista' (Peticion 'PUT' $interna $tokenAnalista '{}') @(401, 403)

    # --------------------------------------------------------------------------------------------------------
    # 7. Usuario desactivado
    # --------------------------------------------------------------------------------------------------------
    Write-Host ''; Write-Host '==> 7. Usuario desactivado' -ForegroundColor Cyan
    $l = Login $emailAnalista $claveAnalista
    $tokenAntes = if ($l.Estado -eq 200) { ($l.Cuerpo | ConvertFrom-Json).token } else { $null }
    Esperar 'desactivado' 'el administrador desactiva al analista' (Peticion 'PATCH' "$AuthUrl/api/v1/usuarios/$idAnalista/estado" $tokenAdmin '{"activo":false}') @(200)
    Esperar 'desactivado' 'login del usuario desactivado' (Login $emailAnalista $claveAnalista) @(401)
    if ($tokenAntes) {
        Esperar 'desactivado' 'auth-api rechaza su access token vigente' (Peticion 'GET' $RutaAuth $tokenAntes) @(401)
        $q = Peticion 'GET' $RutaQuery $tokenAntes
        $restante = [long] (((B64UrlDecodificar $tokenAntes.Split('.')[1]) | ConvertFrom-Json).exp) - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Registrar 'desactivado' 'query-api con el access token del usuario desactivado' 'informativo' "$($q.Estado); vigente ~$restante s más (validación sin estado)" $true 'INFO'
    }

    # --------------------------------------------------------------------------------------------------------
    # 8. Expiración (opcional)
    # --------------------------------------------------------------------------------------------------------
    if ($EsperarExpiracion) {
        Write-Host ''; Write-Host '==> 8. Expiración real del token del administrador' -ForegroundColor Cyan
        $expAdmin = [long] (((B64UrlDecodificar $tokenAdmin.Split('.')[1]) | ConvertFrom-Json).exp)
        $espera = [int] [Math]::Max(0, $expAdmin - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 90)
        Write-Host "Esperando $espera s (vencimiento + 90 s de tolerancia de reloj)..."
        Start-Sleep -Seconds $espera
        foreach ($api in $Apis.Keys) { Esperar 'expiracion' "token vencido -> $api" (Peticion 'GET' $Apis[$api] $tokenAdmin) @(401) }
    } else {
        Registrar 'expiracion' 'token real vencido' 'omitido' 'usar -EsperarExpiracion (~16 min)' $true 'INFO'
    }
} finally {
    # El analista temporal queda desactivado aunque el script se interrumpa.
    $relogin = Login $cfg['INIT_ADMIN_EMAIL'] $cfg['INIT_ADMIN_PASSWORD']
    if ($relogin.Estado -eq 200) {
        [void] (Peticion 'PATCH' "$AuthUrl/api/v1/usuarios/$idAnalista/estado" (($relogin.Cuerpo | ConvertFrom-Json).token) '{"activo":false}')
    }
}

# ------------------------------------------------------------------------------------------------------------
# Resumen
# ------------------------------------------------------------------------------------------------------------
$fallas = @($Resultados | Where-Object { $_.Resultado -eq 'FALLA' })
$oks = @($Resultados | Where-Object { $_.Resultado -eq 'OK' })
Write-Host ''
Write-Host ("Resumen: {0} OK, {1} FALLA, {2} INFO" -f $oks.Count, $fallas.Count, @($Resultados | Where-Object { $_.Resultado -eq 'INFO' }).Count) -ForegroundColor $(if ($fallas.Count -eq 0) { 'Green' } else { 'Red' })
if ($fallas.Count -gt 0) { $fallas | Format-Table Grupo, Prueba, Esperado, Obtenido -AutoSize -Wrap; exit 1 }
exit 0
