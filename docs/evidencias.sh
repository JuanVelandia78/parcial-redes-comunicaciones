#!/bin/bash
# ==========================================================
#  Recoleccion de evidencias de red para el INFORME.md
#  Uso: ./docs/evidencias.sh   (desde la raiz del repositorio)
#  No requiere sudo: las herramientas de red (tcpdump, dig,
#  iptables, ss) se ejecutan en el contenedor nicolaka/netshoot.
# ==========================================================
set -u
OUT=docs/evidencias
mkdir -p "$OUT"
NS="docker run --rm nicolaka/netshoot"
NS_HOST="docker run --rm --net host --cap-add NET_ADMIN --cap-add NET_RAW nicolaka/netshoot"
ns_de() { docker run --rm --net "container:$1" --cap-add NET_ADMIN --cap-add NET_RAW nicolaka/netshoot "${@:2}"; }

ip_de() { docker inspect -f "{{(index .NetworkSettings.Networks \"parcial_$2\").IPAddress}}" "$1"; }

titulo() { echo; echo "\$ $*"; }

# ---------------------------------------------------------- 01
{
  echo "# 01 - Contenedores, imagenes y puertos publicados"
  titulo docker compose ps
  docker compose ps --format "table {{.Name}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
} > "$OUT/01_contenedores.txt" 2>&1

# ---------------------------------------------------------- 02
{
  echo "# 02 - Redes Docker: subred, gateway, IP y MAC de cada contenedor"
  for red in frontend_net backend_net; do
    titulo docker network inspect parcial_$red
    docker network inspect "parcial_$red" --format 'Red: {{.Name}}  Driver: {{.Driver}}  Internal: {{.Internal}}
Subred: {{range .IPAM.Config}}{{.Subnet}}  Gateway: {{.Gateway}}{{end}}
Bridge: {{index .Options "com.docker.network.bridge.name"}}
Contenedores:{{range .Containers}}
  {{printf "%-9s" .Name}} {{.IPv4Address}}  MAC {{.MacAddress}}{{end}}'
  done
} > "$OUT/02_redes_docker.txt" 2>&1

# ---------------------------------------------------------- 03
{
  echo "# 03 - Interfaces y tabla de rutas dentro de cada contenedor"
  for c in nginx joomla database jupyter grafana; do
    echo; echo "================ $c ================"
    ns_de "$c" sh -c 'echo "\$ ip -br addr"; ip -br addr; echo; echo "\$ ip route"; ip route; echo; for i in /sys/class/net/eth*; do echo "$(basename $i): ifindex=$(cat $i/ifindex) peer(iflink en el host)=$(cat $i/iflink)"; done'
  done
} > "$OUT/03_interfaces_y_rutas.txt" 2>&1

# ---------------------------------------------------------- 04
{
  echo "# 04 - Capa 2 en el host: puentes br-*, interfaces veth y su pareja en cada contenedor"
  titulo ip -br link show type bridge
  ip -br link show type bridge
  titulo ip -br addr show br-frontend; ip -br addr show br-frontend
  titulo ip -br addr show br-backend;  ip -br addr show br-backend
  titulo bridge link show
  bridge link show
  titulo brctl show
  brctl show 2>/dev/null || echo "(brctl no instalado)"
  echo; echo "# Pareja veth de cada interfaz de contenedor (iflink del contenedor = ifindex en el host)"
  for c in nginx joomla database jupyter grafana; do
    for idx in $(ns_de "$c" sh -c 'for i in /sys/class/net/eth*; do echo "$(basename $i):$(cat $i/iflink)"; done'); do
      ifc=${idx%%:*}; n=${idx##*:}
      host=$(ip -o link | awk -F': ' -v n="$n" '$1==n {print $2}' | cut -d@ -f1)
      br=$(ip -o link show "$host" 2>/dev/null | grep -o 'master [^ ]*' | cut -d' ' -f2)
      printf "  %-9s %-5s <-> %-16s (ifindex %s) conectado a %s\n" "$c" "$ifc" "$host" "$n" "$br"
    done
  done
} > "$OUT/04_capa2_bridges_veth.txt" 2>&1

# ---------------------------------------------------------- 05
JOOMLA_IP=$(ip_de joomla frontend_net)
NGINX_IP=$(ip_de nginx frontend_net)
{
  echo "# 05 - Resolucion ARP entre nginx ($NGINX_IP) y joomla ($JOOMLA_IP) en br-frontend"
  echo "# Se vacia la cache ARP de nginx, se captura en el puente y se genera una peticion."
  titulo ip neigh flush all  "(en el namespace de nginx)"
  ns_de nginx ip neigh flush all
  $NS_HOST timeout 12 tcpdump -i br-frontend -nn -e -l arp > /tmp/arp.txt 2>&1 &
  sleep 3; curl -s -o /dev/null http://localhost/; sleep 9; wait
  titulo "tcpdump -i br-frontend -nn -e arp"
  cat /tmp/arp.txt
  titulo ip neigh "(tabla ARP de nginx despues de la peticion)"
  ns_de nginx ip neigh
} > "$OUT/05_capa2_arp.txt" 2>&1

# ---------------------------------------------------------- 06
{
  echo "# 06 - Peticion HTTP de nginx a joomla capturada en br-frontend"
  echo "# Muestra el saludo TCP (SYN, SYN-ACK, ACK), las cabeceras que inyecta Nginx y el cierre (FIN)."
  $NS_HOST timeout 12 tcpdump -i br-frontend -nn -A -s 0 -l "tcp port 80 and host $JOOMLA_IP" > /tmp/http.txt 2>&1 &
  sleep 3; curl -s -o /dev/null -H "User-Agent: evidencia-informe" "http://localhost/index.php?option=com_content&view=article&id=1"; sleep 9; wait
  titulo "tcpdump -i br-frontend -nn -A 'tcp port 80 and host $JOOMLA_IP'"
  # Solo cabeceras: se recorta el cuerpo HTML de la respuesta
  awk '/^[0-9][0-9]:[0-9][0-9]:/ {print; next} /GET |Host:|X-Real-IP|X-Forwarded|Connection:|User-Agent:|HTTP\/1\.1 [0-9]|Server:|Content-Type:/ {print "        " $0}' /tmp/http.txt
} > "$OUT/06_capa4_capa7_http_nginx_joomla.txt" 2>&1

# ---------------------------------------------------------- 07
DB_IP=$(ip_de database backend_net)
{
  echo "# 07 - Protocolo de PostgreSQL (TCP 5432) capturado en br-backend"
  echo "# Jupyter abre una conexion nueva: StartupMessage (user/database), SCRAM-SHA-256, consulta y respuesta."
  $NS_HOST timeout 14 tcpdump -i br-backend -nn -A -s 0 -l "tcp port 5432 and host $(ip_de jupyter backend_net)" > /tmp/pg.txt 2>&1 &
  sleep 3
  docker exec jupyter python -c "
import os, psycopg2
c = psycopg2.connect(host='database', dbname=os.environ['DB_NAME'], user=os.environ['DB_USER'], password=os.environ['DB_PASSWORD'], application_name='evidencia-informe')
cur = c.cursor(); cur.execute('SELECT count(*) FROM jml_content'); print('articulos =', cur.fetchone()[0]); c.close()"
  sleep 10; wait
  titulo "tcpdump -i br-backend -nn -A 'tcp port 5432'"
  grep -aE '^[0-9][0-9]:[0-9][0-9]:|user|SCRAM|SELECT|count|articulos|SSL|application_name' /tmp/pg.txt | cut -c1-160
} > "$OUT/07_capa7_protocolo_postgresql.txt" 2>&1

# ---------------------------------------------------------- 08
{
  echo "# 08 - HTTP Upgrade a WebSocket del kernel de Jupyter (a traves de Nginx)"
  TOKEN=$(docker compose exec -T jupyter printenv JUPYTER_TOKEN | tr -d '\r')
  titulo curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" ... /jupyter/api/events/subscribe
  curl -s -i -N --max-time 3 -H "Connection: Upgrade" -H "Upgrade: websocket" \
       -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
       "http://localhost/jupyter/api/events/subscribe?token=$TOKEN" | tr -d '\r' | head -8
} > "$OUT/08_capa7_websocket_jupyter.txt" 2>&1

# ---------------------------------------------------------- 09
{
  echo "# 09 - Conexiones TCP hacia PostgreSQL: pool persistente (Grafana) vs conexion por peticion (Joomla/PHP)"
  echo "# Se envian 6 consultas al datasource de Grafana y luego se revisan las conexiones abiertas."
  for i in $(seq 1 6); do
    curl -s -o /dev/null -X POST -H "Content-Type: application/json" http://localhost/grafana/api/ds/query       -d '{"from":"now-1h","to":"now","queries":[{"refId":"A","datasource":{"uid":"pg-joomla"},"rawSql":"SELECT count(*) FROM trafico_nginx","format":"table"}]}'
  done
  sleep 2
  titulo "SELECT ... FROM pg_stat_activity"
  docker compose exec -T database sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pid, usename, client_addr, application_name, state, backend_start::time(0) AS inicio FROM pg_stat_activity WHERE client_addr IS NOT NULL ORDER BY backend_start;"'
  titulo "ss -tn  (namespace de grafana)"
  ns_de grafana ss -tn
  for i in $(seq 1 15); do curl -s -o /dev/null http://localhost/; done
  titulo "ss -tan state time-wait '( dport = :5432 )'  (namespace de joomla, tras 15 peticiones)"
  ns_de joomla ss -tan state time-wait "( dport = :5432 )"
  titulo "ss -tan  (namespace de nginx: conexiones hacia los servicios)"
  ns_de nginx ss -tan
} > "$OUT/09_capa4_conexiones_pool.txt" 2>&1

# ---------------------------------------------------------- 10
{
  echo "# 10 - DNS embebido de Docker (127.0.0.11)"
  titulo cat /etc/resolv.conf "(joomla)"
  docker exec joomla cat /etc/resolv.conf
  titulo "iptables -t nat -S  (namespace de joomla: redireccion de 127.0.0.11:53)"
  ns_de joomla iptables -t nat -S 2>&1 || ns_de joomla nft list ruleset
  titulo "dig desde un cliente en frontend_net"
  docker run --rm --network parcial_frontend_net nicolaka/netshoot sh -c 'for n in nginx joomla jupyter grafana database; do printf "%-9s -> " $n; r=$(dig +short $n); echo "${r:-(sin respuesta: no esta en esta red)}"; done; echo; dig joomla | grep -E "SERVER|ANSWER SECTION" -A1'
  titulo "dig desde un cliente en backend_net"
  docker run --rm --network parcial_backend_net nicolaka/netshoot sh -c 'for n in nginx joomla database jupyter grafana; do printf "%-9s -> " $n; r=$(dig +short $n); echo "${r:-(sin respuesta: no esta en esta red)}"; done'
} > "$OUT/10_capa3_dns_embebido.txt" 2>&1

# ---------------------------------------------------------- 11
{
  echo "# 11 - NAT y reenvio en el kernel del host"
  titulo cat /proc/sys/net/ipv4/ip_forward
  cat /proc/sys/net/ipv4/ip_forward
  titulo "iptables -t nat -S  (host)"
  $NS_HOST iptables -t nat -S 2>&1 | grep -E "MASQUERADE|DNAT|DOCKER" || echo "(sin reglas iptables)"
  titulo "iptables -S DOCKER-ISOLATION / internal (host)"
  $NS_HOST iptables -S 2>&1 | grep -E "br-frontend|br-backend" | head -30
  titulo ss -tln "(puertos en escucha en el host)"
  ss -tln
} > "$OUT/11_capa3_nat_host.txt" 2>&1

# ---------------------------------------------------------- 12
{
  echo "# 12 - Aislamiento de backend_net"
  titulo docker exec database ip route
  docker exec database ip route
  titulo docker exec database ping -c 2 -W 2 8.8.8.8
  docker exec database ping -c 2 -W 2 8.8.8.8; echo "(codigo de salida: $?)"
  titulo docker exec joomla curl -sI https://www.google.com
  docker exec joomla curl -sI --max-time 5 https://www.google.com | head -1
  titulo "ss -tln | grep 5432  (host)"
  ss -tln | grep 5432 || echo "(ninguno: 5432 no esta publicado en el host)"
} > "$OUT/12_aislamiento_backend.txt" 2>&1

# ---------------------------------------------------------- 13
{
  echo "# 13 - Resultado de verificar.sh"
  ./verificar.sh
} > "$OUT/13_verificacion.txt" 2>&1

echo "Evidencias generadas en $OUT:"
ls -1 "$OUT"
