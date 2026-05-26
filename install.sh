#!/usr/bin/env bash
# OMEN AI PC — install script. Idempotente. Asume Arch Linux + Hyprland.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="${USER}"

echo ">> Verificando deps..."
MISSING=()
for cmd in ollama python uv sensors cpupower notify-send gio; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Faltan binarios: ${MISSING[*]}"
    echo "Instalar con: sudo pacman -S ollama-cuda cuda uv lm_sensors cpupower libnotify glib2 pacman-contrib v4l-utils"
    echo "AUR: paru -S ryzenadj"
    exit 1
fi

echo ">> Creando paths..."
mkdir -p ~/.local/bin ~/.config/systemd/user ~/.config/system-ai ~/.local/share/system-ai
mkdir -p ~/Documents/{Escuela,Archivos,Libros} ~/Pictures ~/Videos ~/Music ~/Software ~/Projects/inbox

echo ">> Copiando scripts..."
cp -v "$REPO_DIR"/scripts/* ~/.local/bin/
chmod +x ~/.local/bin/system-ai-* ~/.local/bin/ai-*

echo ">> Copiando systemd units..."
cp -v "$REPO_DIR"/systemd/user/* ~/.config/systemd/user/

echo ">> Copiando config..."
[ -f ~/.config/system-ai/organize.json ] || cp -v "$REPO_DIR"/config/organize.json ~/.config/system-ai/

echo ">> Recargando systemd..."
systemctl --user daemon-reload

echo ">> Habilitando timers (autostart al login)..."
systemctl --user enable --now \
    system-ai.timer \
    system-ai-watch.service \
    system-ai-daily.timer \
    system-ai-idle.timer \
    system-ai-battery.timer \
    system-ai-organize.timer

echo ""
echo ">> ✓ Instalación base completa."
echo ""
echo "PENDIENTE manual:"
echo "  1. Sudoers (necesario para auto drop_caches + set_profile):"
echo "     sudo tee /etc/sudoers.d/system-ai > /dev/null <<EOF"
echo "${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/tee /proc/sys/vm/drop_caches"
echo "${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/ryzenadj --stapm-limit=* --fast-limit=* --slow-limit=*"
echo "${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/nvidia-smi -pl *"
echo "${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/cpupower frequency-set -g *"
echo "EOF"
echo "     sudo chmod 0440 /etc/sudoers.d/system-ai"
echo ""
echo "  2. Ollama models (~7GB total):"
echo "     ollama pull qwen2.5-coder:7b-instruct-q4_K_M"
echo "     ollama pull nomic-embed-text"
echo "     ollama pull phi3.5    # opcional"
echo ""
echo "  3. Opcional: gestures (webcam, mediapipe)"
echo "     uv venv --python 3.12 ~/.local/share/system-ai-gestures-venv"
echo "     VIRTUAL_ENV=~/.local/share/system-ai-gestures-venv uv pip install mediapipe opencv-python numpy"
echo "     curl -sL -o ~/.local/share/system-ai/hand_landmarker.task https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task"
echo "     curl -sL -o ~/.local/share/system-ai/face_landmarker.task https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task"
echo "     systemctl --user start system-ai-gestures   # manual, sin autostart"
echo ""
echo "Ver README.md para tuning y troubleshooting."
