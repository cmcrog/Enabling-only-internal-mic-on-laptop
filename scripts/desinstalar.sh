#!/bin/bash
# Atajo: deshace el arreglo llamando al script de rollback de la carpeta.
# Uso: sudo ./scripts/desinstalar.sh
BASE="$(cd "$(dirname "$0")/.." && pwd)"
exec "$BASE/deshacer-cambios.sh" "$@"
