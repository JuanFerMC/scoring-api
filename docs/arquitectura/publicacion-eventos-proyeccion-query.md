# Publicación transaccional de eventos para Query

## Alcance

Scoring registra ahora dos tipos de evento en `public.evento_proyeccion_query` (V12): el alta de un solicitante y
la finalización de una evaluación. Este bloque solo crea eventos; no los envía por HTTP ni actualiza todavía la
proyección de Query.

## Límites modulares

El módulo `applicants` depende de su puerto de salida
`RegistrarAltaSolicitanteEnProyeccionPort`. Su adaptador PostgreSQL conoce el formato de persistencia del outbox;
el servicio de aplicación no conoce SQL, tablas ni la API Query. El módulo `evaluations` registra el evento de
finalización desde el adaptador que ya confirma la saga HU14.

## Consistencia y recuperación

- El alta de solicitante y su evento usan la misma transacción Spring. Un fallo al insertar el evento revierte
  también el alta; no queda una escritura sin notificación durable.
- El evento `EVALUACION_COMPLETADA` se inserta dentro de la transacción que marca `trabajo_recomendacion` como
  procesado y `evaluacion` como completada. Si falla cualquier escritura, se revierten las tres.
- Las inserciones son idempotentes por `(tipo_evento, id_agregado)`. Los IDs de agregado y el estado son el
  contenido mínimo del evento; no se copian datos personales ni factores de evaluación al outbox.
- La evaluación solo produce el evento al completar la saga de recomendaciones, preservando HU14. Scoring lee
  los valores ya persistidos de la evaluación y sus factores y los envía en la petición existente a Query; Query
  genera desde ese snapshot local. El evento posterior comunica la transición final de estado.

## Operación en este punto

Hasta que se implemente el despachador en un bloque posterior, los eventos permanecen `PENDIENTE`. La aplicación
que despliegue este código necesita V12 y los permisos descritos en
`docs/operacion/despliegue-v12-proyeccion-query.md`. Aplicar la migración y el permiso no publica ningún dato en
Query. No borrar ni truncar la tabla para limpiar pendientes: esos eventos son la evidencia durable de cambios
que aún no se han sincronizado.
