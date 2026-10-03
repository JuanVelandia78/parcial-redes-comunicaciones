#!/bin/bash
# ==========================================================
#  Verificacion automatica del despliegue - Parcial II
#  Uso:  ./verificar.sh   (desde la raiz del repositorio)
# ==========================================================

ok=0
fallo=0

check() {
    # $1 = descripcion, $2 = comando que debe terminar sin error
    if eval "$2" > /dev/null 2>&1; then
        echo "  [OK]    $1"
        ok=$((ok + 1))
    else
        echo "  [FALLO] $1"
        fallo=$((fallo + 1))
    fi
}

TOKEN=$(docker compose exec -T jupyter printenv JUPYTER_TOKEN 2>/dev/null | tr -d '\r')

echo "== 1. Contenedores =="
check "Los 5 servicios estan en ejecucion" \
      '[ "$(docker compose ps --status running -q | wc -l)" -eq 5 ]'
check "Ningun servicio esta unhealthy o arrancando" \
      '! docker compose ps | grep -qE "unhealthy|health: starting"'
check "Solo nginx publica puertos al host" \
      '[ -z "$(docker ps --filter label=com.docker.compose.project=parcial --format "{{.Names}} {{.Ports}}" | grep -- "->" | grep -v "^nginx ")" ]'

echo "== 2. Enrutamiento por Nginx =="
check "Joomla responde en /" \
      'curl -fsS -o /dev/null http://localhost/'
check "Jupyter responde en /jupyter/" \
      '[ "$(curl -s -o /dev/null -w "%{http_code}" "http://localhost/jupyter/api/status?token=$TOKEN")" = "200" ]'
check "WebSocket de Jupyter (101 Switching Protocols)" \
      'curl -s -i -N --max-time 3 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" "http://localhost/jupyter/api/events/subscribe?token=$TOKEN" | grep -q "101 Switching Protocols"'
check "Grafana responde en /grafana/" \
      'curl -fsS http://localhost/grafana/api/health | grep -q "\"database\": *\"ok\""'

echo "== 3. Precarga de Jupyter y Grafana =="
check "Cuaderno analisis_datos.ipynb presente en Jupyter" \
      'docker compose exec -T jupyter test -f /home/jovyan/work/analisis_datos.ipynb'
check "Dashboard aprovisionado en Grafana" \
      'curl -fsS "http://localhost/grafana/api/search?query=Parcial" | grep -q "parcial-trafico"'
check "Grafana (usuario lector) lee el log de Nginx" \
      'docker compose exec -T database sh -c '\''PGPASSWORD="$GRAFANA_DB_PASSWORD" psql -h localhost -U "$GRAFANA_DB_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*) FROM trafico_nginx"'\'''
check "Grafana (usuario lector) lee las tablas de Joomla" \
      'docker compose exec -T database sh -c '\''PGPASSWORD="$GRAFANA_DB_PASSWORD" psql -h localhost -U "$GRAFANA_DB_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*) FROM jml_content"'\'''

echo "== 4. PostgreSQL y segmentacion =="
check "Joomla creo sus tablas en PostgreSQL" \
      'docker compose exec -T database sh -c '\''psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1 FROM jml_users LIMIT 1"'\'' | grep -q 1'
check "La base de datos NO tiene salida a internet" \
      '! docker compose exec -T database ping -c 1 -W 2 8.8.8.8'
check "El puerto 5432 NO esta publicado en el host" \
      '! ss -tln | grep -q ":5432 "'

echo
echo "Resultado: $ok correctas, $fallo con fallo"
[ "$fallo" -eq 0 ]
