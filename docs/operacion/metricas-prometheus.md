# Métricas Prometheus en scoring-api

## Alcance

`GET /actuator/prometheus` publica las métricas de Micrometer (peticiones HTTP, JVM, pool de conexiones,
proceso) para Prometheus. Sigue el mismo diseño que evaluation-query-api
(`evaluation-query-api/docs/operacion/seguridad-metricas-prometheus.md`):

- El endpoint se protege con HTTP Basic y una **cuenta técnica exclusiva del scraper**, independiente de los JWT
  de usuario. Un JWT de usuario no sirve para leer métricas y la cuenta técnica no da acceso a la API.
- Solo admite `GET`; cualquier otro método se deniega.
- `/actuator/health` sigue público y sin detalles; el resto de Actuator sigue denegado.
- **Apagado por defecto en dos niveles**: el endpoint no se expone (`management.endpoints.web.exposure.include=health`
  en `application.properties`) y la cadena de seguridad de métricas no existe. Mientras no se habiliten ambos, la
  cadena JWT principal deniega `/actuator/prometheus` (`anyRequest().denyAll()`).
- Si se habilita sin usuario o contraseña, la aplicación no arranca.

## Configuración

| Variable | Valor |
|---|---|
| `MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE` | `health,prometheus` (expone el endpoint) |
| `SCORING_METRICS_ENABLED` | `true` (activa la cadena Basic de métricas) |
| `SCORING_METRICS_USERNAME` | Usuario técnico del scraper |
| `SCORING_METRICS_PASSWORD` | Contraseña fuerte y exclusiva del scraper (secreto) |

Las credenciales viven solo en el entorno de ejecución: nunca en el repositorio, en imágenes ni en logs.

- **Entorno local con Docker Compose**: ya vienen configuradas en `orquestacion/docker-compose.yml` a partir de
  `METRICS_SCRAPER_PASSWORD` del `.env`, junto con Prometheus y Grafana (ver `orquestacion/README.md`).
- **Render**: agregar las cuatro variables al servicio (usuario y contraseña como secretos) solo si un Prometheus
  externo va a leer las métricas; HTTP Basic debe viajar siempre por HTTPS.

## Verificación manual

```bash
curl -i http://localhost:8080/actuator/prometheus                       # 401
curl -i -u "$SCORING_METRICS_USERNAME:$SCORING_METRICS_PASSWORD" \
     http://localhost:8080/actuator/prometheus                          # 200, texto Prometheus
```

Pruebas automáticas: `SeguridadIntegracionTest` (acceso anónimo, credenciales incorrectas, JWT de usuario,
métodos distintos de GET y que la cuenta técnica no da acceso a la API).
