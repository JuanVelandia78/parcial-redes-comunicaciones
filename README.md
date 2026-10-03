# Parcial II – Comunicaciones: despliegue multi-contenedor

Infraestructura web de una organización académica con **5 servicios orquestados con Docker Compose**, que se despliega con **un único comando** y sin configuración manual.

| Servicio | Rol | Imagen |
|---|---|---|
| **nginx** | Proxy inverso: único punto de entrada (puerto 80), con enrutamiento por prefijo, WebSockets y log de accesos | `nginx:1.31.6-alpine` |
| **joomla** | Portal web institucional (CMS) sobre PostgreSQL | `joomla:6.1.4-php8.4-apache` |
| **database** | PostgreSQL, aislado en la red interna | `postgres:16-alpine` |
| **jupyter** | JupyterLab con el cuaderno `analisis_datos.ipynb` precargado | `parcial-jupyter:1.1` (Dockerfile propio) |
| **grafana** | Dashboards aprovisionados automáticamente | `grafana/grafana:13.2.3` |

**Integrantes:** Juan Velandia, Valeria Talero y Santiago Cabezas — Comunicaciones, Ingeniería Mecatrónica.

📄 El análisis técnico completo (topología, flujo de logs y modelo OSI en las capas 2, 3, 4 y 7) está en **[INFORME.md](INFORME.md)**.

---

## Requisitos

- Docker Engine 24 o superior con el plugin **Docker Compose v2** (`docker compose version`)
- El puerto **80** libre en el host
- Unos 3 GB de disco para las imágenes

## Despliegue

```bash
git clone https://github.com/JuanVelandia78/parcial-redes-comunicaciones.git
cd parcial-redes-comunicaciones
cp .env.example .env
docker compose up -d
```

El primer arranque construye la imagen de Jupyter y descarga las demás. Luego hay que esperar a que los 5 servicios estén `healthy`, lo que tarda alrededor de 1 minuto:

```bash
docker compose ps
```

## Accesos

| Servicio | URL | Credenciales (definidas en `.env`) |
|---|---|---|
| Joomla (sitio) | http://localhost/ | — |
| Joomla (administración) | http://localhost/administrator | `admin` / `Admin_Joomla_2026` |
| Jupyter | http://localhost/jupyter/?token=parcial2026 | token `parcial2026` |
| Grafana | http://localhost/grafana/ | Visible sin login. Para administrar: `admin` / `Admin_Grafana_2026` |

- **Jupyter** abre directamente `analisis_datos.ipynb`. Ejecútalo con *Run → Restart Kernel and Run All Cells*.
- **Grafana** abre directamente el dashboard *"Parcial II - Tráfico Nginx y actividad Joomla"*. Para ver datos, primero navega por el sitio de Joomla.

## Verificación automática

```bash
./verificar.sh
```

Comprueba los 14 puntos de la rúbrica: contenedores healthy, puerto único, enrutamiento, WebSocket (101), precarga de Jupyter y Grafana, PostgreSQL y aislamiento de `backend_net`.

Para regenerar las evidencias de red del informe (no requiere `sudo`):

```bash
./docs/evidencias.sh
```

## Arquitectura en resumen

```
                    ┌──────────────── frontend_net 172.20.0.0/24 (br-frontend) ────────────────┐
 Navegador ──:80──► │ nginx ──/──────────► joomla                                              │
                    │       ──/jupyter/──► jupyter (WebSocket)                                 │
                    │       ──/grafana/──► grafana                                             │
                    └─────────────────────────┬────────────┬────────────┬──────────────────────┘
                                           joomla       jupyter      grafana
                    ┌────────────── backend_net 172.21.0.0/24 (br-backend, internal) ──────────┐
                    │                       database (PostgreSQL :5432)                        │
                    └──────────────────────────────────────────────────────────────────────────┘
```

- Solo **nginx** publica un puerto al host (80).
- **database** solo está en `backend_net`, que es una red `internal: true` sin salida al exterior.
- Nginx escribe cada petición en `trafico.csv` (volumen `nginx_logs`). PostgreSQL lo expone como la tabla `trafico_nginx` mediante **file_fdw**, y Grafana lo consulta con un **usuario de solo lectura**.

## Estructura del repositorio

```
parcial-redes-comunicaciones/
├── docker-compose.yml                  # Orquestación de los 5 servicios, redes y volúmenes
├── .env.example                        # Credenciales por defecto (copiar a .env)
├── README.md                           # Este archivo
├── INFORME.md                          # Documento técnico (topología + modelo OSI)
├── verificar.sh                        # Verificación automática del despliegue
├── nginx/
│   └── default.conf                    # Proxy inverso, WebSocket, log CSV, DNS dinámico
├── database/
│   └── init/01-trafico-nginx.sh        # file_fdw sobre el log + usuario lector para Grafana
├── jupyter/
│   ├── Dockerfile                      # Base oficial + pandas, matplotlib, SQLAlchemy, psycopg2
│   └── notebooks/analisis_datos.ipynb  # Cuaderno precargado
├── grafana/
│   └── provisioning/
│       ├── datasources/datasource.yml  # Datasource PostgreSQL (aprovisionado)
│       └── dashboards/
│           ├── dashboard.yml           # Proveedor de dashboards
│           └── joomla_logs.json        # Dashboard con 7 paneles
└── docs/
    ├── evidencias.sh                   # Recolección de evidencias de red
    ├── evidencias/                     # Salidas reales usadas en el informe
    └── capturas/                       # Capturas de Joomla, Grafana y Jupyter
```

## Operación

| Acción | Comando |
|---|---|
| Ver estado | `docker compose ps` |
| Ver logs de un servicio | `docker compose logs -f nginx` |
| Detener (conserva los datos) | `docker compose down` |
| Reiniciar desde cero (**borra los datos**) | `docker compose down -v && docker compose up -d` |

## Solución de problemas

| Síntoma | Solución |
|---|---|
| `Bind for 0.0.0.0:80 failed: port is already allocated` | Otro programa usa el puerto 80. Identifícalo con `sudo ss -tlnp \| grep ':80 '` |
| Jupyter muestra "Kernel connection error" | Comprueba que `nginx` esté healthy y recarga la página |
| Paneles de Grafana sin datos | Genera tráfico en http://localhost/ o amplía el rango de tiempo |
| Cambios en `.env` sin efecto | Las bases de datos solo leen las variables la primera vez: `docker compose down -v && docker compose up -d` |

> ⚠️ Las credenciales de `.env.example` son **solo para laboratorio**. No las reutilices en otros entornos.
