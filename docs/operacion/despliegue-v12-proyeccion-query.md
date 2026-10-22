# Preparación de V12: outbox para la proyección de Query

Estado: **migración preparada; no aplicada a ninguna base de datos**. El bloque de persistencia crea la
estructura durable en `public`; el bloque de publicación registra eventos desde Scoring. El despachador HTTP y
la actualización de Query todavía no están implementados. No se modifica el esquema `consulta`.

## Qué agrega

`V12__outbox_proyeccion_query.sql` crea `evento_proyeccion_query`, una tabla local de eventos pendientes de
sincronización. El modelo no tiene claves foráneas al esquema `consulta` ni necesita un broker. Los tipos
previstos son `SOLICITANTE_PROYECTAR` y `EVALUACION_COMPLETADA`; cada tipo puede tener un único evento por
agregado. Esta restricción permite que el siguiente bloque publique eventos idempotentemente.

La tabla conserva el tipo y el ID del agregado, versión y contenido JSON del evento, estado, intentos, fecha del
siguiente intento, concesión temporal de procesamiento y último error acotado. El índice parcial ordena el
trabajo pendiente por fecha de reintento y creación. Las restricciones validan tipos, estados, JSON objeto,
concesiones, errores permanentes e instante de entrega.

| Estado | Significado |
|---|---|
| `PENDIENTE` | Puede ser reclamado cuando vence `proximo_intento` y no hay concesión vigente |
| `ENTREGADO` | Query confirmó la actualización; es terminal |
| `ERROR_PERMANENTE` | Se agotaron los intentos o el evento requiere intervención; debe revisarse antes de reactivarlo |

El futuro despachador deberá reclamar filas dentro de una transacción corta con `FOR UPDATE SKIP LOCKED`, asignar
una concesión y aumentar el contador de intentos. La llamada HTTP ocurre fuera de esa transacción. Después debe
marcar entrega o programar reintento con espera creciente; al agotar el límite, dejar el evento en
`ERROR_PERMANENTE`. Query deberá aceptar reintentos de forma idempotente. La implementación de ese ciclo queda
fuera de este bloque.

## Permisos

`docs/operacion/roles-scoring-api-v12.sql` concede `SELECT`, `INSERT` y `UPDATE`, más `USAGE` en la secuencia,
al rol de ejecución. No se conceden `DELETE`, `TRUNCATE` ni acceso al esquema de Query. Es un script separado
para que el procedimiento ya aplicado de V10/V11 y los esquemas de ensayo anteriores sigan siendo válidos.

## Aplicación futura

No aplicar V12 como parte de este bloque. Cuando se autorice el despliegue:

1. Detener Scoring y respaldar `motor_scoring`; verificar que el respaldo puede leerse/restaurarse, siguiendo
   las salvaguardas de `despliegue-v10-v11.md`.
2. Revisar `flyway info`: V12 debe ser la única migración nueva pendiente en `public`.
3. Aplicar con un arranque controlado de `scoring-api`, la bandera `SCORING_FLYWAY_MIGRAR_AL_ARRANCAR=true`
   y las credenciales del propietario. No dejar la bandera en configuración permanente.
4. Verificar V12 como exitosa y las columnas, restricciones e índice de la tabla. Confirmar que los datos
   existentes no cambiaron; aplicar `roles-scoring-api-v12.sql` al rol de ejecución y reiniciar con ese rol.
5. Los productores registrarán eventos pendientes al desplegar el código de Scoring. Hasta que estén listos el
   despachador y el endpoint idempotente de Query, estos eventos se acumularán sin salir de Scoring. No aplicar
   esta migración/desplegar el productor antes de definir cuándo se implementará y habilitará el despachador.

Flyway aplica cada versión en su propia transacción PostgreSQL. Si V12 falla, se revierte entera; corregir la
causa en una migración nueva si V12 ya fue aplicada, nunca editar una migración aplicada.
