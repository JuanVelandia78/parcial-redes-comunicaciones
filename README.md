# Parcial II - Comunicaciones: Despliegue Multi-contenedor

Infraestructura web con 5 servicios orquestados con Docker Compose:
Nginx (proxy inverso), Joomla (CMS), PostgreSQL (base de datos),
Jupyter (análisis de datos) y Grafana (monitoreo).

## Requisitos

- Docker Engine 24+ y Docker Compose v2

## Despliegue

```bash
git clone https://github.com/JuanVelandia78/parcial-redes-comunicaciones.git
cd parcial-redes-comunicaciones
cp .env.example .env
docker compose up -d
```

## Accesos

| Servicio | URL |
|---|---|
| Joomla | http://localhost/ |
| Jupyter | http://localhost/jupyter |
| Grafana | http://localhost/grafana |

> Documento en construcción.
