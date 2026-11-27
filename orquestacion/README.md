# Entorno local integrado con Docker Compose

Levanta en contenedores PostgreSQL 16 y las tres APIs del sistema, conectadas entre sí:

| Servicio | Imagen / origen | Puerto en el equipo |
|---|---|---|
| `postgres` | `postgres:16-alpine`, base `db_scoring` | `127.0.0.1:5433` |
| `scoring-api` | `scoring-api/docker/Dockerfile` | `127.0.0.1:8080` |
| `auth-api` | `Security-Module/Dockerfile` | `127.0.0.1:8081` |
| `evaluation-query-api` | `evaluation-query-api/Dockerfile` | `127.0.0.1:8082` |
| `prometheus` | `prom/prometheus:v3.5.0` | `127.0.0.1:9090` |
| `grafana` | `grafana/grafana:12.1.0`, dashboard aprovisionado | `127.0.0.1:3001` |

Servicios de un solo uso (terminan con código 0): `claves`, `consulta-preparar` y `consulta-permisos`.

Es un entorno **solo para desarrollo y pruebas locales**. No reemplaza ni modifica los despliegues en Render.

## Requisitos

- Docker Desktop (o Docker Engine) con Compose v2.
- Los tres repositorios clonados en el mismo equipo. Por defecto se esperan como carpetas hermanas:

  ```
  <carpeta>/scoring-api/
  <carpeta>/Security-Module/
  <carpeta>/evaluation-query-api/
  ```

  Si están en otro lugar, indica sus rutas en `SECURITY_MODULE_DIR` y `EVALUATION_QUERY_API_DIR` del `.env`
  (absolutas o relativas a esta carpeta; en Windows usa `/`, por ejemplo `C:/Users/yo/Desktop/Security-Module`).

## Arranque

Desde `scoring-api/orquestacion` (PowerShell o bash):

```powershell
Copy-Item .env.example .env      # bash: cp .env.example .env
# Edita .env: contraseñas obligatorias, INIT_ADMIN_EMAIL / INIT_ADMIN_PASSWORD y, si hace falta, las rutas.
docker compose up -d --build
docker compose ps -a
```

El primer arranque compila las tres APIs dentro de Docker (varios minutos). `.env` no se versiona.

Orden de arranque y qué hace cada paso:

1. `postgres`: en un volumen nuevo, `postgres/initdb/01-rol-crediticio.sh` crea el rol `crediticio_app`
   (sin superusuario), propietario del esquema `public`.
2. `claves`: genera, solo si no existen, el par RSA de auth-api y el par de servicio de scoring-api en volúmenes
   Docker. auth-api monta solo su par; scoring-api, su par de servicio y la pública de auth; Query, solo las públicas.
3. `scoring-api`: aplica sus migraciones V1–V13 en `public`.
4. `auth-api`: aplica V100–V111 en `public` (mismo historial Flyway, como en el despliegue actual) y crea el
   primer administrador con `INIT_ADMIN_*`.
5. `consulta-preparar`: ejecuta el script oficial `evaluation-query-api/docs/operacion/01-preparar-antes-de-migrar.sql`
   (roles `consulta_app` y `consulta_migrador`, `SELECT` sobre las tablas de scoring y esquema `consulta`) y
   asigna las contraseñas del `.env`.
6. `evaluation-query-api`: migra el esquema `consulta` con `consulta_migrador` y atiende con `consulta_app`.
7. `consulta-permisos`: ejecuta el script oficial `02-permisos-despues-de-migrar.sql`.

Solo en este entorno las APIs migran al arrancar (`*_FLYWAY_MIGRAR_AL_ARRANCAR=true`). En los despliegues
reales sigue el procedimiento controlado de cada repositorio.

## Verificación

1. Estado de los contenedores (`docker compose ps -a`): `postgres`, `scoring-api`, `auth-api` y
   `evaluation-query-api` en `healthy`; `claves`, `consulta-preparar` y `consulta-permisos` en `Exited (0)`.

2. Health checks desde el equipo (deben responder `{"status":"UP"}`):

   ```powershell
   curl.exe -s http://localhost:8080/actuator/health
   curl.exe -s http://localhost:8081/actuator/health
   curl.exe -s http://localhost:8082/actuator/health
   ```

3. Comunicación entre contenedores por la red de Compose (nombres de servicio como host):

   ```powershell
   docker compose exec scoring-api wget -qO- http://evaluation-query-api:8082/actuator/health
   docker compose exec evaluation-query-api wget -qO- http://auth-api:8081/actuator/health
   ```

4. Migraciones en PostgreSQL:

   ```powershell
   docker compose exec postgres psql -U postgres -d db_scoring -c "SELECT version, description, success FROM flyway_schema_history ORDER BY installed_rank"
   docker compose exec postgres psql -U postgres -d db_scoring -c "SELECT version, description, success FROM consulta.flyway_schema_history ORDER BY installed_rank"
   ```

5. Token de auth-api aceptado por las otras dos APIs (PowerShell):

   ```powershell
   $cuerpo = @{ email = '<INIT_ADMIN_EMAIL>'; password = '<INIT_ADMIN_PASSWORD>' } | ConvertTo-Json
   $token = (Invoke-RestMethod -Method Post -Uri http://localhost:8081/api/v1/auth/login -ContentType 'application/json' -Body $cuerpo).token
   # Sin token: 401. Con token del administrador: no debe ser 401 ni 403.
   curl.exe -s -o NUL -w "scoring sin token: %{http_code}`n" http://localhost:8080/api/v1/politicas-clasificacion/vigente
   curl.exe -s -o NUL -w "scoring con token: %{http_code}`n" -H "Authorization: Bearer $token" http://localhost:8080/api/v1/politicas-clasificacion/vigente
   curl.exe -s -o NUL -w "query sin token: %{http_code}`n" http://localhost:8082/api/v1/evaluaciones
   curl.exe -s -o NUL -w "query con token: %{http_code}`n" -H "Authorization: Bearer $token" http://localhost:8082/api/v1/evaluaciones
   ```

   En una base recién creada, `politicas-clasificacion/vigente` puede responder 404 o 409 porque aún no hay
   política publicada: lo que se comprueba aquí es que el token es aceptado (ni 401 ni 403).

6. Registros de los pasos de preparación: `docker compose logs claves consulta-preparar consulta-permisos`.

## Observabilidad (Prometheus y Grafana)

Las tres APIs publican `/actuator/prometheus` protegido con HTTP Basic y una cuenta técnica exclusiva del scraper
(`prometheus-scraper`, contraseña `METRICS_SCRAPER_PASSWORD` del `.env`), independiente de los JWT de usuario.
Prometheus lee las tres cada 15 s y Grafana arranca ya conectado a Prometheus con el dashboard
**Crediticio - APIs** (carpeta *Crediticio*, también como página de inicio): disponibilidad, peticiones por
segundo, latencia media, errores 5xx, rechazos 4xx, memoria heap, conexiones a PostgreSQL, CPU y endpoints con
más tráfico. Diseño de seguridad de las métricas en cada repositorio:
`docs/operacion/metricas-prometheus.md` (scoring-api), `docs/METRICAS_PROMETHEUS.md` (Security-Module) y
`docs/operacion/seguridad-metricas-prometheus.md` (evaluation-query-api).

Verificación (PowerShell, desde esta carpeta):

1. Configuración de Prometheus válida:

   ```powershell
   docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
   ```

2. Targets: los cuatro (`prometheus`, `scoring-api`, `auth-api`, `evaluation-query-api`) deben estar en `up`.
   En el navegador: http://localhost:9090/targets. Desde la consola:

   ```powershell
   (Invoke-RestMethod http://localhost:9090/api/v1/targets).data.activeTargets | Select-Object @{n='job';e={$_.labels.job}}, health, lastError | Format-Table -AutoSize
   ```

3. Las métricas exigen la cuenta técnica (401 sin credenciales; un JWT de usuario tampoco sirve):

   ```powershell
   curl.exe -s -o NUL -w "scoring /actuator/prometheus sin credenciales: %{http_code}`n" http://localhost:8080/actuator/prometheus
   curl.exe -s -o NUL -w "auth    /actuator/prometheus sin credenciales: %{http_code}`n" http://localhost:8081/actuator/prometheus
   curl.exe -s -o NUL -w "query   /actuator/prometheus sin credenciales: %{http_code}`n" http://localhost:8082/actuator/prometheus
   ```

4. Métricas reales de las APIs en Prometheus (genera tráfico antes, por ejemplo los pasos 2 y 5 de Verificación):

   ```powershell
   $q = 'sum by (job) (http_server_requests_seconds_count{uri!~"/actuator.*"})'
   (Invoke-RestMethod "http://localhost:9090/api/v1/query?query=$([uri]::EscapeDataString($q))").data.result | ForEach-Object { "{0}: {1} peticiones" -f $_.metric.job, $_.value[1] }
   ```

5. Grafana conectado a Prometheus: abre http://localhost:3001, entra con `GRAFANA_ADMIN_USER` /
   `GRAFANA_ADMIN_PASSWORD` y revisa el dashboard *Crediticio - APIs*. Desde la consola:

   ```powershell
   curl.exe -s http://localhost:3001/api/health; ""
   ```

## Verificación de seguridad JWT de punta a punta

`verificacion/verificar-jwt.ps1` comprueba la seguridad con tokens contra el sistema en marcha (Compose, o
Kubernetes con `acceder.ps1` activo), con peticiones HTTP reales a las tres APIs:

| Grupo | Qué comprueba |
|---|---|
| Emisión | El token de auth-api es RS256 con `iss`, `aud` (scoring-api y evaluation-query-api), `sub` UUID, `role`, `jti` y vida ≤ 15 min |
| Aceptación | El token real se acepta en auth-api, scoring-api y evaluation-query-api |
| Tokens inválidos | 401 en las tres APIs: otra clave RSA, `"alg":"none"`, HS256, escalada de rol con la firma original, mal formado, sin token |
| Roles | 403 cuando el rol no está autorizado (analista y administrador, en las tres APIs) |
| Sesión | Rotación del refresh token, rechazo del refresh reutilizado (revoca la sesión) y logout |
| Servicio | Los endpoints `/internal` de evaluation-query-api rechazan un JWT de usuario |
| Desactivación | auth-api rechaza el token de un usuario desactivado; para scoring-api y Query se informa su vigencia restante |
| Expiración | Opcional con `-EsperarExpiracion` (~16 min): un token real vencido se rechaza |

Los tokens falsos se firman con claves generadas en el momento; nunca se usa la clave privada real. El script no
imprime tokens ni contraseñas, lee las credenciales del administrador de `.env` y crea un analista temporal (correo
único por ejecución) que deja desactivado al terminar. Termina con código 0 si todo es OK.

```powershell
cd "<ruta>\scoring-api\orquestacion\verificacion"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\verificar-jwt.ps1
.\verificar-jwt.ps1 -EsperarExpiracion     # añade la prueba de expiración real
```

Los casos que necesitan la clave privada real (token válido con otro emisor, otra audiencia o ya vencido sin
esperar) se cubren en las pruebas automáticas de cada API (`JwtConfigTest`, `JwtTokenProviderTest`).

## Kubernetes local (Docker Desktop)

El mismo entorno (PostgreSQL, las tres APIs, los pasos de base de datos de Query, Prometheus y Grafana) también
se despliega en el Kubernetes de Docker Desktop, en el namespace `crediticio`. Compose sigue disponible: son dos
formas de levantar lo mismo, con las mismas imágenes, el mismo `.env` y los mismos archivos de configuración.

| Docker Compose | Kubernetes (`kubernetes/`) |
|---|---|
| `postgres` + volumen | `StatefulSet` + `PersistentVolumeClaim` (2 Gi) + `Service` |
| `scoring-api`, `auth-api`, `evaluation-query-api` | `Deployment` + `Service`, con sondas *startup*, *readiness* y *liveness* sobre `/actuator/health` |
| `depends_on` | `initContainers` que esperan a PostgreSQL, a scoring-api migrado y al esquema `consulta` |
| `consulta-preparar`, `consulta-permisos` | `Job` con los mismos scripts y los SQL oficiales de Query |
| Rol `crediticio_app` (initdb) | Además, `Job` `rol-crediticio` en cada despliegue: crea el rol si falta y sincroniza su contraseña |
| `.env` | `Secret` `crediticio-credenciales`, creado por `desplegar.ps1` desde el mismo `.env` |
| Volúmenes de claves RSA | `Secret` `claves-auth` (solo auth-api), `claves-servicio-scoring` (solo scoring-api), `claves-publicas` |
| Puertos en `127.0.0.1` | `Service` internos + `kubectl port-forward` (`acceder.ps1`) |

Las sondas de arranque y disponibilidad usan `/actuator/health`, la única ruta de Actuator pública en las tres
APIs (`/actuator/health/liveness` y `/readiness` responderían 401). La de vida usa `tcpSocket`: `/actuator/health`
incluye la base de datos, y una base lenta no debe reiniciar la API, solo sacarla del tráfico hasta que se recupere.

### Requisitos

- Docker Desktop con Kubernetes activado en modo **kubeadm** (Settings → Kubernetes → Enable Kubernetes), en
  verde. En modo *kind* el clúster no ve las imágenes construidas en el equipo.
- Memoria para Docker Desktop. Con WSL 2 se fija en `%USERPROFILE%\.wslconfig` (`memory=`), nunca por encima de
  la RAM real del equipo: déjale al menos 2 GB a Windows. Con unos 8 GB o menos de RAM total, usa
  `-SinObservabilidad` (abajo).

  | RAM del equipo | `.wslconfig` | Despliegue |
  |---|---|---|
  | ~6 GB | `memory=4GB` | `.\desplegar.ps1 -SinObservabilidad` (PostgreSQL + 3 APIs) |
  | 16 GB o más | `memory=8GB` | `.\desplegar.ps1` (completo, con Prometheus y Grafana) |

  Tras cambiar `.wslconfig`: `wsl --shutdown` y volver a abrir Docker Desktop.
- `orquestacion/.env` completo, el mismo de Docker Compose.

### Desplegar

```powershell
cd "<ruta>\scoring-api\orquestacion"
docker compose stop                       # libera memoria y puertos; no borra datos
cd kubernetes
.\desplegar.ps1                           # construye las imágenes, crea los Secret y espera a cada pieza
.\desplegar.ps1 -OmitirConstruccion       # si las imágenes ya están construidas
.\desplegar.ps1 -OmitirConstruccion -SinObservabilidad   # sin Prometheus ni Grafana (equipos con poca memoria)
```

`-SinObservabilidad` aplica todo salvo los objetos etiquetados `app.kubernetes.io/component=observabilidad` (y los
retira si ya estaban). La observabilidad sigue disponible en Docker Compose. En Kubernetes, cada API tiene un
límite de 768 MiB y opciones de JVM para poca memoria (`JAVA_TOOL_OPTIONS`); Compose no cambia.

Ningún secreto se versiona ni pasa por la línea de comandos. Las claves RSA se generan en una carpeta temporal que
se borra al terminar, y se conservan en el clúster entre despliegues. Si cambias una contraseña en `.env`, vuelve
a ejecutar `desplegar.ps1` y reinicia los pods: `kubectl -n crediticio rollout restart deployment`.

### Acceder y verificar

```powershell
.\acceder.ps1            # port-forward a 127.0.0.1: 8080, 8081, 8082, 9090, 3001 y 5433 (como Compose)
kubectl -n crediticio get pods,svc,jobs,pvc
```

Con `acceder.ps1` activo, los pasos de **Verificación** y **Observabilidad** de esta guía funcionan igual. Las
consultas a PostgreSQL cambian de `docker compose exec postgres` a:

```powershell
kubectl -n crediticio exec statefulset/postgres -- psql -U postgres -d db_scoring -c "SELECT version, success FROM flyway_schema_history ORDER BY installed_rank"
```

Comunicación entre pods por los `Service` de Kubernetes:

```powershell
kubectl -n crediticio exec deployment/scoring-api -- wget -qO- http://evaluation-query-api:8082/actuator/health
kubectl -n crediticio exec deployment/evaluation-query-api -- wget -qO- http://auth-api:8081/actuator/health
```

### Problemas frecuentes en Kubernetes

- **`Invalid value ... for configuration property 'server.port'`**: Kubernetes inyecta variables `*_PORT` por cada
  `Service` (`SCORING_API_PORT=tcp://...`). Los manifiestos las desactivan con `enableServiceLinks: false`.
- **`password authentication failed for user "crediticio_app"`**: el rol no existe o tiene otra contraseña (por
  ejemplo, si la primera inicialización de PostgreSQL se interrumpió). Vuelve a ejecutar `desplegar.ps1`: el Job
  `rol-crediticio` lo crea o sincroniza sin borrar datos.
- **`ErrImageNeverPull`**: el clúster no ve las imágenes locales. Usa el modo kubeadm de Docker Desktop y vuelve a
  ejecutar `desplegar.ps1`.
- **Un pod en `Init:0/1` mucho tiempo**: está esperando su dependencia. Revisa
  `kubectl -n crediticio logs <pod> -c <initContainer>` y el estado de la dependencia.
- **`Pending` por memoria**: sube la memoria de Docker Desktop.
- **`etcdserver: request timed out`**: el plano de control de Kubernetes no responde por falta de memoria. Revisa
  `.wslconfig` (no más memoria que la RAM real) y usa `-SinObservabilidad`.
- **`Unhealthy ... timed out after 1s` y reinicios de un pod**: el equipo está muy cargado y la sonda no responde a
  tiempo. Los manifiestos ya amplían los tiempos de espera (10 s en PostgreSQL, 5 s en el resto); si sigue pasando,
  asigna más CPU y memoria a Docker Desktop (Settings → Resources).
- **Detener los port-forward**: `.\acceder.ps1 -Detener`.
- **Borrar todo el entorno de Kubernetes** (incluida su base de datos): `.\eliminar.ps1`.

## Detener y limpiar

```powershell
docker compose down        # detiene; conserva datos y claves
docker compose down -v     # además borra la base, las claves locales y los datos de Prometheus y Grafana
```

## Problemas frecuentes

- **`required variable ... is missing a value`**: falta una contraseña obligatoria en `.env`.
- **`/bin/sh^M` o `\r: not found` en `claves` o `consulta-*`**: los `.sh` quedaron con fin de línea CRLF.
  El repositorio fuerza LF (`.gitattributes`); para corregir un clon existente:
  `git add --renormalize . ; git checkout -- orquestacion`.
- **`build path ... does not exist`**: revisa `SECURITY_MODULE_DIR` y `EVALUATION_QUERY_API_DIR`.
- **Puerto ocupado**: cambia `POSTGRES_HOST_PORT`, `SCORING_HOST_PORT`, `AUTH_HOST_PORT`, `QUERY_HOST_PORT`,
  `PROMETHEUS_HOST_PORT` o `GRAFANA_HOST_PORT`.
- **Un target de Prometheus en `down` con `401`**: la API no tiene la misma `METRICS_SCRAPER_PASSWORD` que
  Prometheus; tras cambiarla en `.env`, `docker compose up -d` recrea los contenedores afectados.
- **Una contraseña con `$` no funciona**: escríbela entre comillas simples en `.env` (`CLAVE='a$b'`).
- **Cambié una contraseña en `.env`**: las de `consulta_*` se aplican en el siguiente `up`; la de
  `crediticio_app` y la del administrador solo se usan al crear el volumen (`docker compose down -v`).
