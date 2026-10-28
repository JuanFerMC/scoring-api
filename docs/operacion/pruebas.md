# Pruebas de scoring-api

Desde `scoring-api`, ejecutar `mvnw.cmd -B test` (Windows) o `./mvnw -B test` (Linux/macOS).
Las pruebas normales usan una base H2 efímera y no leen `.env`, Supabase ni una base de desarrollo.
Los documentos y nombres usados en pruebas unitarias son datos locales a cada ejecución.

Las clases `*IT` son pruebas de persistencia/contrato contra PostgreSQL y no corren con `test`.
Se ejecutan de forma explícita contra una base y esquema dedicados terminados en `_it`; el inicializador
`ProteccionBaseIntegracion` aborta antes de abrir conexiones si no recibe una URL y nombre autorizados.
No apuntes el perfil `it` a la base compartida ni al esquema `public`.
