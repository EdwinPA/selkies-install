#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Configuración
# ============================================================

SELKIES_PORT="8080"
SELKIES_SESSION="xfce"
SERVICE_NAME="selkies"

GITHUB_REPO="selkies-project/selkies"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}"

# ============================================================
# Funciones
# ============================================================

log() {
    echo
    echo "[selkies-install] $*"
}

die() {
    echo
    echo "[selkies-install] ERROR: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT

# ============================================================
# Verificar root
# ============================================================

if [[ $EUID -ne 0 ]]; then
    die "Este script debe ejecutarse como root o mediante sudo."
fi

# ============================================================
# Detectar distribución
# ============================================================

[[ -f /etc/os-release ]] ||
    die "No existe /etc/os-release."

. /etc/os-release

case "$ID" in

    ubuntu)
        DISTRO="ubuntu${VERSION_ID}"
        ;;

    debian)
        DISTRO="${VERSION_CODENAME}"
        ;;

    *)
        die "Distribución no soportada: ${ID}"
        ;;

esac

ARCH="$(dpkg --print-architecture)"

log "Sistema detectado:"
echo "  Distribución: $DISTRO"
echo "  Arquitectura: $ARCH"

# ============================================================
# Instalar dependencias básicas
# ============================================================

log "Verificando dependencias..."

PACKAGES=()

if ! command -v curl &>/dev/null; then
    PACKAGES+=("curl")
fi

if ! command -v sudo &>/dev/null; then
    PACKAGES+=("sudo")
fi

if [[ ${#PACKAGES[@]} -gt 0 ]]; then

    log "Instalando dependencias: ${PACKAGES[*]}"

    apt-get update

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "${PACKAGES[@]}"

else

    log "Dependencias básicas disponibles."

fi

# ============================================================
# Solicitar usuario
# ============================================================

echo
echo "============================================================"
echo " Usuario de Selkies"
echo "============================================================"
echo

while true; do

    read -rp "Usuario que ejecutará Selkies: " SELKIES_USER

    if [[ -n "$SELKIES_USER" ]]; then
        break
    fi

    echo "Debes indicar un usuario."

done

# ============================================================
# Crear usuario si no existe
# ============================================================

if id "$SELKIES_USER" &>/dev/null; then

    log "El usuario '$SELKIES_USER' ya existe."

else

    log "El usuario '$SELKIES_USER' no existe."
    log "Creando usuario..."

    useradd \
        --create-home \
        --shell /bin/bash \
        "$SELKIES_USER"

    log "Usuario '$SELKIES_USER' creado."

fi

# ============================================================
# Obtener HOME del usuario
# ============================================================

USER_HOME="$(
    getent passwd "$SELKIES_USER" |
        cut -d: -f6
)"

[[ -n "$USER_HOME" ]] ||
    die "No fue posible determinar el HOME de '$SELKIES_USER'."

log "HOME del usuario: $USER_HOME"

# ============================================================
# Agregar usuario a sudo
# ============================================================

if id -nG "$SELKIES_USER" | grep -qw sudo; then

    log "El usuario ya pertenece al grupo sudo."

else

    log "Agregando '$SELKIES_USER' al grupo sudo..."

    usermod -aG sudo "$SELKIES_USER"

fi

# ============================================================
# Consultar releases de Selkies
# ============================================================

echo
echo "============================================================"
echo " Versión de Selkies"
echo "============================================================"
echo

log "Consultando releases disponibles en GitHub..."

RELEASES_JSON="$(
    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${GITHUB_API}/releases?per_page=100"
)" || die "No fue posible consultar las releases de GitHub."

# ============================================================
# Extraer versiones
# ============================================================

mapfile -t SELKIES_RELEASES < <(
    printf '%s' "$RELEASES_JSON" |
        grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' |
        sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
)

if [[ ${#SELKIES_RELEASES[@]} -eq 0 ]]; then
    die "No se encontraron releases de Selkies."
fi

# ============================================================
# Mostrar menú de versiones
# ============================================================

echo
echo "Versiones disponibles:"
echo

for i in "${!SELKIES_RELEASES[@]}"; do

    NUMBER=$((i + 1))
    VERSION="${SELKIES_RELEASES[$i]}"

    if [[ $i -eq 0 ]]; then
        printf "  %2d) %-20s [latest]\n" "$NUMBER" "$VERSION"
    else
        printf "  %2d) %s\n" "$NUMBER" "$VERSION"
    fi

done

MANUAL_OPTION=$((${#SELKIES_RELEASES[@]} + 1))

echo
printf "  %2d) Ingresar versión manualmente\n" "$MANUAL_OPTION"
echo

# ============================================================
# Seleccionar versión
# ============================================================

while true; do

    read -rp "Selecciona una versión [1]: " SELECTION

    # Enter = última release
    if [[ -z "$SELECTION" ]]; then
        SELECTION=1
    fi

    # Verificar número
    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]]; then

        echo "Debes ingresar un número válido."
        continue

    fi

    # Versión manual
    if [[ "$SELECTION" -eq "$MANUAL_OPTION" ]]; then

        echo

        read -rp "Ingresa la versión de Selkies: " SELKIES_VERSION

        if [[ -z "$SELKIES_VERSION" ]]; then
            echo "La versión no puede estar vacía."
            continue
        fi

        break

    fi

    # Versión del listado
    if [[ "$SELECTION" -ge 1 &&
          "$SELECTION" -le "${#SELKIES_RELEASES[@]}" ]]; then

        SELKIES_VERSION="${SELKIES_RELEASES[$((SELECTION - 1))]}"
        break

    fi

    echo "Selección inválida."

done

log "Versión seleccionada: $SELKIES_VERSION"

# ============================================================
# Verificar release
# ============================================================

log "Verificando release '$SELKIES_VERSION'..."

HTTP_STATUS="$(
    curl \
        --silent \
        --output /dev/null \
        --write-out "%{http_code}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${GITHUB_API}/releases/tags/${SELKIES_VERSION}"
)"

if [[ "$HTTP_STATUS" != "200" ]]; then

    die "La release '$SELKIES_VERSION' no existe en GitHub (HTTP $HTTP_STATUS)."

fi

# ============================================================
# Construir nombre del paquete
# ============================================================

PKG="selkies-${SELKIES_VERSION}-${DISTRO}-${ARCH}.deb"

URL="https://github.com/${GITHUB_REPO}/releases/download/${SELKIES_VERSION}/${PKG}"

echo
echo "============================================================"
echo " Instalación"
echo "============================================================"
echo
echo "Usuario:       $SELKIES_USER"
echo "HOME:          $USER_HOME"
echo "Versión:       $SELKIES_VERSION"
echo "Distribución:  $DISTRO"
echo "Arquitectura:  $ARCH"
echo "Paquete:       $PKG"
echo

# ============================================================
# Crear directorio temporal
# ============================================================

TMP_DIR="$(mktemp -d)"

cd "$TMP_DIR"

# ============================================================
# Descargar Selkies
# ============================================================

log "Descargando Selkies..."

curl \
    --fail \
    --show-error \
    --location \
    --remote-name \
    "$URL" ||
    die "No fue posible descargar '$PKG'."

[[ -f "$PKG" ]] ||
    die "El paquete '$PKG' no fue descargado."

log "Descarga completada."

# ============================================================
# Instalar Selkies
# ============================================================

log "Instalando Selkies..."

apt-get install -y "./${PKG}"

# ============================================================
# Verificar selkies-session
# ============================================================

SELKIES_BIN="$(command -v selkies-session || true)"

if [[ -z "$SELKIES_BIN" ]]; then
    die "selkies-session no está disponible después de la instalación."
fi

log "selkies-session encontrado en:"
echo "  $SELKIES_BIN"

# ============================================================
# Verificar XFCE
# ============================================================

if command -v startxfce4 &>/dev/null; then

    log "XFCE ya está instalado."

else

    log "XFCE no está instalado."
    log "Instalando XFCE..."

    apt-get update

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y xfce4

fi

# ============================================================
# Detectar NVIDIA
# ============================================================

NVIDIA_AVAILABLE=false

if command -v nvidia-smi &>/dev/null; then

    if nvidia-smi &>/dev/null; then

        NVIDIA_AVAILABLE=true

        log "GPU NVIDIA detectada."

        nvidia-smi \
            --query-gpu=name \
            --format=csv,noheader |
            sed 's/^/  /'

    else

        log "nvidia-smi existe, pero no puede comunicarse con la GPU."

    fi

else

    log "No se detectó NVIDIA mediante nvidia-smi."

fi

# ============================================================
# Crear servicio systemd
# ============================================================

log "Creando servicio systemd..."

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Selkies Remote Desktop
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=${SELKIES_USER}
Group=${SELKIES_USER}

WorkingDirectory=${USER_HOME}

Environment=HOME=${USER_HOME}
Environment=USER=${SELKIES_USER}
Environment=LOGNAME=${SELKIES_USER}

ExecStart=${SELKIES_BIN} \\
    --session=${SELKIES_SESSION} \\
    --public \\
    --port=${SELKIES_PORT} \\
    --enable-basic-auth=false \\
    --encoder=h264enc

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ============================================================
# Activar servicio
# ============================================================

log "Recargando systemd..."

systemctl daemon-reload

log "Habilitando servicio..."

systemctl enable "${SERVICE_NAME}.service"

log "Iniciando servicio..."

systemctl restart "${SERVICE_NAME}.service"

# Esperar brevemente para comprobar si falló inmediatamente.
sleep 2

# ============================================================
# Resultado
# ============================================================

echo
echo "============================================================"
echo " Selkies instalado"
echo "============================================================"
echo
echo "Usuario:       $SELKIES_USER"
echo "HOME:          $USER_HOME"
echo "Versión:       $SELKIES_VERSION"
echo "Distribución:  $DISTRO"
echo "Arquitectura:  $ARCH"
echo "Puerto:        $SELKIES_PORT"
echo "Servicio:      ${SERVICE_NAME}.service"
echo "NVIDIA:        $NVIDIA_AVAILABLE"
echo

# ============================================================
# Estado del servicio
# ============================================================

if systemctl is-active --quiet "${SERVICE_NAME}.service"; then

    echo "Estado:        ACTIVO"

else

    echo "Estado:        ERROR"
    echo
    echo "El servicio no está ejecutándose."
    echo
    echo "Últimos logs:"
    echo

    journalctl \
        -u "${SERVICE_NAME}.service" \
        -n 30 \
        --no-pager

    exit 1

fi

echo
echo "============================================================"
echo " Comandos útiles"
echo "============================================================"
echo
echo "Ver estado:"
echo "  systemctl status ${SERVICE_NAME}"
echo
echo "Ver logs:"
echo "  journalctl -u ${SERVICE_NAME} -f"
echo
echo "Reiniciar:"
echo "  systemctl restart ${SERVICE_NAME}"
echo
echo "Detener:"
echo "  systemctl stop ${SERVICE_NAME}"
echo
echo "Iniciar:"
echo "  systemctl start ${SERVICE_NAME}"
echo
echo "Deshabilitar:"
echo "  systemctl disable --now ${SERVICE_NAME}"
echo
echo "Acceso:"
echo "  http://IP_DEL_SERVIDOR:${SELKIES_PORT}"
echo
