# Contrato HTTP de evaluaciones – scoring-api

Este documento describe las operaciones públicas de cálculo y consulta de evaluaciones y los campos de
trazabilidad que devuelve la API. La especificación OpenAPI generada desde los controladores es la fuente
de verdad para el contrato HTTP; Swagger se habilita únicamente con el perfil `dev`.

## Autenticación

Las dos operaciones requieren un JWT de acceso emitido por `auth-api` en
`Authorization: Bearer <token>`. La API valida localmente el token RS256. El rol se obtiene del claim
`role`; la identidad del usuario autenticado se obtiene del claim `sub`, que debe contener un UUID.

## Operaciones

| Método y ruta | Descripción | Acceso |
|---|---|---|
| `POST /api/v1/evaluaciones` | Calcula y registra una evaluación | Solo `ANALISTA_CREDITO` |
| `GET /api/v1/evaluaciones/{idEvaluacion}` | Consulta una evaluación persistida | `ANALISTA_CREDITO` y `ADMINISTRADOR_RIESGO` |

### Calcular una evaluación

`POST /api/v1/evaluaciones` recibe exactamente uno de estos identificadores:

```json
{ "idSolicitante": 101 }
```

o

```json
{ "numeroDocumento": "1234567890" }
```

La respuesta exitosa es `201 Created` y contiene la evaluación registrada. La API obtiene el usuario
evaluador del JWT validado; el cliente no puede elegir ni sobrescribir esa identidad mediante el cuerpo
de la solicitud.

### Consultar una evaluación

`GET /api/v1/evaluaciones/{idEvaluacion}` devuelve la evaluación persistida, incluidos el puntaje,
la categoría y la versión de la política aplicada, los detalles históricos, el estado de la saga y el
usuario evaluador cuando está disponible.

## Campos de trazabilidad de la respuesta

| Campo | Tipo | Significado |
|---|---|---|
| `idEvaluacion` | integer | Identificador de la evaluación |
| `idSolicitante` | integer | Identificador del solicitante |
| `fechaEvaluacion` | datetime | Fecha y hora de registro |
| `scoreTotal` | integer | Puntaje total persistido |
| `categoria` | string o null | Categoría de riesgo persistida; null para evaluaciones históricas anteriores a HU12 |
| `idPolitica` | integer o null | Identificador de la política aplicada |
| `versionPolitica` | integer o null | Versión de la política aplicada |
| `estado` | string o null | `PENDIENTE` o `COMPLETADA`; null para evaluaciones anteriores a la saga |
| `usuarioEvaluador` | UUID o null | Claim `sub` del JWT autenticado que ejecutó el cálculo |
| `detalles` | array | Detalle histórico de las reglas consideradas |

### Regla de asignación de `usuarioEvaluador` (US 5.1.1)

- El valor se obtiene del claim `sub` de la identidad autenticada y validada por Spring Security.
- El cliente no envía este campo en `CalcularScoreRequest`; no se confía en un UUID suministrado en el
  body, query string o cabeceras arbitrarias.
- Las nuevas evaluaciones deben registrar el UUID del usuario que ejecutó la operación.
- Las evaluaciones anteriores a la incorporación de US 5.1.1 conservan `usuarioEvaluador: null`;
  no se atribuye retroactivamente un usuario que no quedó registrado.
- El campo es de solo lectura en la respuesta. La identidad original del evaluador no debe cambiarse
  durante actualizaciones posteriores de la evaluación.

Ejemplo ilustrativo de respuesta (se omiten los detalles para abreviar):

```json
{
  "idEvaluacion": 501,
  "idSolicitante": 101,
  "fechaEvaluacion": "2026-11-21T10:30:00",
  "scoreTotal": 25,
  "categoria": "MEDIO",
  "idPolitica": 3,
  "versionPolitica": 2,
  "estado": "COMPLETADA",
  "usuarioEvaluador": "d6a2e70e-45d1-4b6e-a3e5-89b7c0e2c113",
  "detalles": []
}
```

El UUID del ejemplo es ilustrativo; en una respuesta real corresponde al `sub` del token autenticado.

## Respuestas de error

| Estado | Código | Situación |
|---|---|---|
| 400 | `VALIDATION_ERROR` | Identificadores ausentes, ambos informados o con formato/valor inválido |
| 401 | `NO_AUTENTICADO` | Token ausente, inválido o expirado |
| 403 | `ACCESO_DENEGADO` | El rol autenticado no está autorizado |
| 404 | `SOLICITANTE_NO_ENCONTRADO` / `EVALUACION_NO_ENCONTRADA` | Recurso inexistente |
| 409 | Según la operación | Política no disponible, puntaje sin clasificación u otra condición de negocio documentada en OpenAPI |
| 406 | (sin cuerpo) | El encabezado `Accept` no admite JSON; el `traceId` viaja en `X-Trace-Id` |
| 415 | `UNSUPPORTED_MEDIA_TYPE` | `Content-Type` distinto de JSON en una operación con cuerpo; `details` y el encabezado `Accept` indican los tipos admitidos |
| 500 | `INTERNAL_ERROR` | Error interno no controlado |

Los errores usan el sobre común `ApiError` (`errorCode`, `message`, `details`, `traceId`) y la
trazabilidad HTTP mediante `X-Trace-Id`.

## Relación con Query

Scoring es responsable de calcular y persistir la evaluación y su identidad de origen. Query es responsable
de las consultas históricas y de las exportaciones PDF/Excel (US 5.2.1 y US 5.2.2); esos contratos están
documentados en `evaluation-query-api/docs/api/exportacion-historial.md`. No se debe asumir que un campo
de la respuesta directa de Scoring también forma parte de las respuestas de Query: cada contrato se
documenta y versiona por separado.
