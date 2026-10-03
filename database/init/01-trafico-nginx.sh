#!/bin/sh
# ==========================================================
#  Inicializacion de PostgreSQL - Parcial II
#  Se ejecuta automaticamente SOLO la primera vez
#  (cuando el volumen db_data esta vacio).
#
#  1. Expone el log CSV de Nginx como tabla (file_fdw)
#  2. Crea un usuario de solo lectura para Grafana
# ==========================================================
set -e

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname "$POSTGRES_DB" \
     -v lector="$GRAFANA_DB_USER" \
     -v clave="$GRAFANA_DB_PASSWORD" \
     -v duenio="$POSTGRES_USER" <<'EOSQL'

-- 1. Extension para leer archivos como si fueran tablas
CREATE EXTENSION IF NOT EXISTS file_fdw;

CREATE SERVER IF NOT EXISTS servidor_logs FOREIGN DATA WRAPPER file_fdw;

-- 2. Tabla externa: cada linea de trafico.csv es una fila.
--    Las columnas siguen el mismo orden del log_format de Nginx.
CREATE FOREIGN TABLE IF NOT EXISTS trafico_nginx (
    fecha       timestamptz,
    ip          inet,
    metodo      text,
    uri         text,
    protocolo   text,
    codigo      integer,
    bytes       bigint,
    tiempo      numeric,
    servicio    text,
    user_agent  text
) SERVER servidor_logs
  OPTIONS (filename '/var/log/nginx/trafico.csv', format 'csv', header 'false');

-- 3. Usuario de solo lectura para Grafana (se crea solo si no existe)
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'lector', :'clave')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'lector') \gexec

GRANT USAGE ON SCHEMA public TO :"lector";

-- Lectura de las tablas que ya existen (incluye trafico_nginx)
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"lector";

-- Lectura de las tablas que Joomla cree DESPUES
ALTER DEFAULT PRIVILEGES FOR ROLE :"duenio" IN SCHEMA public
    GRANT SELECT ON TABLES TO :"lector";
EOSQL
