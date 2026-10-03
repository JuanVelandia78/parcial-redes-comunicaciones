#!/bin/bash
# ==========================================================
#  Entrypoint de Joomla con siembra de contenido
#  1. Lanza seed.php en segundo plano: espera a que Joomla
#     termine su instalacion automatica y crea el articulo.
#  2. Ejecuta el entrypoint oficial de la imagen (instalacion
#     + Apache), sin modificar su comportamiento.
# ==========================================================
php /seed/seed.php &
exec /entrypoint.sh "$@"
