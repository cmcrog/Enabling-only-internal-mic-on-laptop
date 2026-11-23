#!/bin/bash
# Atajo: instala desde esta carpeta usando el script todo-en-uno.
# Uso: sudo ./scripts/instalar.sh [--desinstalar|--estado]
BASE="$(cd "$(dirname "$0")/.." && pwd)"
exec "$BASE/solucion-mic-interno.sh" "$@"
