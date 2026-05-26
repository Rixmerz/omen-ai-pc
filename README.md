# OMEN AI PC

Capa de IA local para convertir una laptop Arch Linux + Hyprland en un sistema con auto-gestión inteligente: análisis de recursos, organización proactiva de descargas, búsqueda semántica de logs, control por gestos de mano y cabeza, predicción de batería, y más.

**Hardware probado:** HP OMEN 15 (Ryzen 7 4800H + RTX 2060 Mobile 6GB + 16GB RAM, iGPU AMD Renoir).
**Stack base:** Arch Linux, Hyprland (Wayland), systemd user units, ollama + qwen2.5-coder/phi3.5/nomic-embed, mediapipe Tasks API.

> Todo corre **100% local**: LLM inference en GPU NVIDIA via ollama-cuda, embeddings via nomic-embed-text, hand/face tracking via mediapipe + OpenCV. Sin telemetría externa.

---

## Tabla de contenidos

1. [Arquitectura](#arquitectura)
2. [Requisitos](#requisitos)
3. [Instalación paso a paso](#instalación-paso-a-paso)
4. [Componentes](#componentes)
5. [Uso diario](#uso-diario)
6. [Tuning y troubleshooting](#tuning-y-troubleshooting)
7. [Privacidad y seguridad](#privacidad-y-seguridad)

---

## Arquitectura

```
                       ┌──────────────────────────┐
                       │ ollama-cuda (systemd)    │
                       │ qwen2.5-coder:7b (4.7GB) │
                       │ nomic-embed-text (274MB) │
                       │ phi3.5:latest (2.2GB)    │
                       │ API 127.0.0.1:11434      │
                       └──────────┬───────────────┘
                                  │ HTTP /api/chat /api/embeddings
                                  │
   ┌──────────────────────────────┼──────────────────────────────────┐
   │                              │                                  │
   ▼                              ▼                                  ▼
┌─────────────┐         ┌──────────────────┐              ┌──────────────────┐
│ Observer    │         │ Organize/Search/ │              │ Battery/Gestures │
│ (5min timer)│         │ Boot/Crash/...   │              │ (collectors)     │
│ snapshot →  │         │ (CLIs on-demand) │              │                  │
│ JSON verdict│         │                  │              │ sqlite store     │
│ → notif +   │         │ Embeddings index │              │ mediapipe hand+  │
│ pending     │         │ Journal RAG      │              │ face landmarkers │
└──────┬──────┘         └──────────────────┘              └──────────────────┘
       │ if AUTO tool (drop_caches, set_profile)
       ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Whitelist tool executor (system-ai-approve CLI o auto)                  │
│ kill_pid / kill_pattern / drop_caches / cpu_limit_w / set_profile / none│
│ Guards: PID critical names, regex pattern, watts range, sudoers strict  │
└──────────────────────┬──────────────────────────────────────────────────┘
                       ▼
        ryzenadj / nvidia-smi / cpupower / kill / hyprctl
```

---

## Requisitos

### Hardware mínimo

- GPU NVIDIA con ≥4GB VRAM (para qwen 7B Q4); fallback CPU funciona pero lento
- 8GB+ RAM (16GB recomendado)
- 10GB libres en disco para modelos + venv

### Software base

| Paquete | Repo | Rol |
|---------|------|-----|
| `ollama-cuda` | extra | runtime LLM con NVIDIA |
| `cuda` | extra | toolkit CUDA (requerido por ollama-cuda) |
| `python` (≥3.10) | extra | scripts |
| `uv` | extra | crear venv Py3.12 para mediapipe |
| `lm_sensors` | extra | `sensors -j` para temps |
| `cpupower` | extra | governor CPU |
| `ryzenadj` | AUR | CPU power limit en Ryzen mobile |
| `nvidia-utils` | extra | `nvidia-smi` |
| `libnotify` | extra | `notify-send` |
| `gio` (glib2) | core | trash recuperable |
| `pacman-contrib` | extra | `checkupdates` (para ai-update-check) |
| `v4l-utils` | extra | webcam check (para gestures) |
| `piper` (opcional) | extra | TTS (no usado en versión actual) |

---

## Instalación paso a paso

### 0. Clonar repo y preparar paths

```bash
git clone <este_repo> ~/omen-ai-pc
cd ~/omen-ai-pc
mkdir -p ~/.local/bin ~/.config/systemd/user ~/.config/system-ai ~/.local/share/system-ai
```

### 1. Ollama + modelos LLM

```bash
sudo pacman -S ollama-cuda cuda
```

Crear user systemd (Arch lo hace via sysusers, si no existe):

```bash
sudo systemd-sysusers && sudo systemd-tmpfiles --create
id ollama  # debe existir
```

**Override systemd para apuntar modelos a tu home + dar acceso al user `ollama`:**

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<EOF
[Service]
Environment="OLLAMA_MODELS=/home/${USER}/.ollama/models"
ProtectHome=tmpfs
BindPaths=/home/${USER}/.ollama
EOF

sudo setfacl -R -m u:ollama:rwX /home/${USER}/.ollama
sudo setfacl -d -m u:ollama:rwX /home/${USER}/.ollama
sudo systemctl daemon-reload
sudo systemctl enable --now ollama
```

**Pull modelos:**

```bash
ollama pull qwen2.5-coder:7b-instruct-q4_K_M   # ~4.7GB — coder principal
ollama pull nomic-embed-text                   # ~274MB — embeddings
ollama pull phi3.5                              # ~2.2GB — opcional, fallback rápido
```

Verificar GPU offload:

```bash
ollama ps   # debe mostrar PROCESSOR=100% GPU para qwen
```

### 2. Sudoers (necesario para auto drop_caches + set_profile)

```bash
sudo tee /etc/sudoers.d/system-ai > /dev/null <<'EOF'
%USER% ALL=(root) NOPASSWD: /usr/bin/tee /proc/sys/vm/drop_caches
%USER% ALL=(root) NOPASSWD: /usr/bin/ryzenadj --stapm-limit=* --fast-limit=* --slow-limit=*
%USER% ALL=(root) NOPASSWD: /usr/bin/nvidia-smi -pl *
%USER% ALL=(root) NOPASSWD: /usr/bin/cpupower frequency-set -g *
EOF
sudo sed -i "s/%USER%/${USER}/g" /etc/sudoers.d/system-ai
sudo chmod 0440 /etc/sudoers.d/system-ai
sudo visudo -c -f /etc/sudoers.d/system-ai
```

### 3. Instalar scripts + systemd units

```bash
cp scripts/* ~/.local/bin/
chmod +x ~/.local/bin/system-ai-* ~/.local/bin/ai-*
cp systemd/user/* ~/.config/systemd/user/
cp config/organize.json ~/.config/system-ai/
```

Crear directorios destino para el organizer:

```bash
mkdir -p ~/Documents/{Escuela,Archivos,Libros} ~/Pictures ~/Videos ~/Music ~/Software ~/Projects/inbox
```

### 4. Habilitar timers (autostart)

```bash
systemctl --user daemon-reload
systemctl --user enable --now \
    system-ai.timer \
    system-ai-watch.service \
    system-ai-daily.timer \
    system-ai-idle.timer \
    system-ai-battery.timer \
    system-ai-organize.timer

systemctl --user list-timers   # verificar
```

> **NOTA:** `system-ai-gestures.service` NO se habilita por defecto (privacidad — usa webcam). Iniciar manualmente con `systemctl --user start system-ai-gestures`.

### 5. (Opcional) Gestures — setup venv mediapipe

```bash
uv venv --python 3.12 ~/.local/share/system-ai-gestures-venv
VIRTUAL_ENV=~/.local/share/system-ai-gestures-venv uv pip install mediapipe opencv-python numpy
```

**Descargar modelos hand + face:**

```bash
curl -sL --create-dirs -o ~/.local/share/system-ai/hand_landmarker.task \
  https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task

curl -sL -o ~/.local/share/system-ai/face_landmarker.task \
  https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task
```

Iniciar (manual):

```bash
systemctl --user start system-ai-gestures
```

Debug visual (parar service primero):

```bash
systemctl --user stop system-ai-gestures
~/.local/bin/system-ai-gestures --debug
```

---

## Componentes

### Observer + tools whitelist

Núcleo del sistema. Cada 5 minutos (timer) o cuando hay burst de errores (watch daemon), recolecta snapshot (memoria, temps, top procs, GPU, batería, journal errors, workload hint via hyprctl) y se lo manda al LLM con prompt estricto que devuelve JSON:

```json
{"anomaly": false}
```
o
```json
{
  "anomaly": true,
  "metric": "ram_pct",
  "value": 92.4,
  "cause": "rogue-leak rss 6.8GB",
  "summary": "RAM 91% — proceso rogue-leak consume 6.8GB",
  "exec": {"tool": "kill_pid", "args": {"pid": 12345}}
}
```

**Tools whitelist** (validados antes de ejecutar):

| Tool | Auto/Manual | Acción |
|------|-------------|--------|
| `none` | auto-notif | solo notifica |
| `kill_pid {pid}` | manual (y/N) | SIGTERM. Refuse PIDs ≤1 o nombres críticos (hyprland/systemd/dbus/etc) |
| `kill_pattern {pattern}` | manual (y/N) | `pgrep -f` + SIGTERM. Regex `^[\w\-./]+$`, sin pipes |
| `drop_caches {}` | auto | `sync` + `tee /proc/sys/vm/drop_caches` |
| `cpu_limit_w {watts}` | manual (y/N) | `ryzenadj` 15-30W |
| `set_profile {name}` | auto | Llama `system-ai-profile` |

**Defensa en capas:**

1. Prompt con few-shot + WHITELIST procesos hardcoded
2. ollama `format=json` obliga estructura
3. `validate_verdict()` post-LLM degrada a `none` si target inválido, pattern malformado, watts out-of-range
4. `system-ai-approve` repite checks antes de ejecutar (defense in depth)

Logs:
- `~/.local/state/system-ai.log` — verdicts JSONL
- `~/.local/state/system-ai-actions.log` — acciones tomadas

### CLIs interactivas

| CLI | Para qué |
|-----|----------|
| `ai-ask "<pregunta>"` | Query libre al LLM con snapshot sistema como contexto. Stream output |
| `ai-explain` | Pipe-friendly. Resume input (logs/errores). Flags `--boot` o `--service <name>` |
| `ai-boot-analyze` | Resume el último arranque: `systemd-analyze`, blame, critical-chain, failed units, journal `-b -p err` |
| `ai-crash-autopsy [idx]` | Lista coredumpctl + analiza el N-ésimo crash (idx 0 = más reciente) |
| `ai-search [index\|"query"]` | Búsqueda semántica via nomic-embed-text + sqlite. `--explain` + LLM resume hits |
| `ai-update-check` | Pre `pacman -Syu`: combina `checkupdates` + arch news → LLM scanea breaking |
| `ai-battery [-v] [--explain]` | Predicción ETA + drain breakdown por workload/profile |
| `system-ai-profile <perf\|balanced\|quiet\|status>` | Perfil coherente: ryzenadj + nvidia-smi -pl + cpufreq governor |
| `system-ai-approve` | Lee `~/.local/state/system-ai-pending.json`, muestra sugerencia LLM, pide y/N |
| `system-ai-daily-report` | Genera reporte markdown 24h en `~/Documents/system-ai/YYYY-MM-DD.md` |

### Servicios systemd (user)

| Unidad | Tipo | Cuándo |
|--------|------|--------|
| `system-ai.timer` | timer | Observer cada 5min |
| `system-ai-watch.service` | daemon | Sigue `journalctl -f -p err`, dispara observer en burst |
| `system-ai-daily.timer` | timer | Reporte diario 08:00 |
| `system-ai-idle.timer` | timer | Tareas pesadas cuando AC + CPU<70°C + load<1.5 (cada 30min) |
| `system-ai-battery.timer` | timer | Sample batería cada 1min |
| `system-ai-organize.timer` | timer | Clasifica Downloads cada 15min |
| `system-ai-gestures.service` | daemon | Webcam mediapipe — **manual start** |

### Organizer (Downloads → clasificación inteligente)

Cada 15 minutos clasifica `~/Downloads/` con LLM. Threshold 0.9 (alta confianza). Categorías con subdirs inteligentes:

| Categoría | Root | Subdir auto |
|-----------|------|-------------|
| school | `~/Documents/Escuela` | código de curso (ej `TI3013D`, `ETVI03`) |
| documents | `~/Documents` | tema (Contratos, Recetas...) |
| images | `~/Pictures` | screenshots si filename matchea |
| video | `~/Videos` | — |
| music | `~/Music` | artista/género si claro |
| installers | `~/Software` | `deb`, `appimages`, `iso`, `windows` |
| ebooks | `~/Documents/Libros` | tema |
| code | `~/Projects/inbox` | nombre del proyecto del zip |
| archives | `~/Documents/Archivos` | — |
| trash | `gio trash` | recuperable |
| **bajo confidence** | `~/Downloads/unknowns/<ext>/` | por extensión |

Editar categorías: `~/.config/system-ai/organize.json`.

### Gestures (control por cámara)

`system-ai-gestures` corre dos detectores en paralelo:

1. **Mano** (mediapipe HandLandmarker) — cuenta dedos extendidos via distancia tip→centro_palma normalizada por ancho de palma. Per-finger thresholds: thumb 0.95, pinky 1.45, otros 1.90.
2. **Cara** (mediapipe FaceLandmarker) — tracking de nose tip x. Giro brusco detectado por cambio rápido de posición (no por ángulo).

**Flujo:**

- N dedos estables (~0.3s) → notifica `preview ws N`
- Giro brusco cabeza durante preview → confirma y salta a ws N
- Giro brusco cabeza **sin preview** → ws prev/next (`hyprctl dispatch workspace e±1`)
- Sin giro en 3s → cancela preview

**Tunes (env vars):**

| Var | Default | Qué |
|-----|---------|-----|
| `HEAD_MIN_DX` | 0.07 | desplazamiento mínimo nariz |
| `HEAD_MAX_DT` | 0.50 | ventana temporal |
| `HEAD_MIN_VEL` | 0.25 | velocidad mínima |
| `STABLE_FRAMES` | 8 | frames consecutivos count estable |
| `STABLE_MIN_S` | 0.3 | tiempo mínimo gesto |
| `GEST_COOLDOWN` | 1.0 | entre acciones |
| `FINGER_THR` / `THUMB_THR` / `PINKY_THR` | varios | thresholds por dedo |
| `PREVIEW_TIMEOUT_S` | 3.0 | espera del giro tras armar preview |

**Privacidad:** frames procesados solo en memoria, no se guardan. NO autostart. Manual via `systemctl --user start system-ai-gestures`.

---

## Uso diario

```bash
# Pregunta libre al LLM con contexto del sistema
ai-ask "por qué está lento?"

# Resume errores de un service
ai-explain --service ollama

# Pre actualización
ai-update-check

# Predicción batería con análisis
ai-battery -v --explain

# Búsqueda semántica de logs
ai-search "wifi se cae"
ai-search --explain "ollama oom"

# Cambiar perfil energético
system-ai-profile quiet     # ahorro
system-ai-profile balanced  # default
system-ai-profile perf      # rendimiento

# Revisar última sugerencia del observer
system-ai-approve

# Ver log de verdicts en tiempo real
tail -f ~/.local/state/system-ai.log

# Forzar corrida del organizer
~/.local/bin/system-ai-organize --dry-run   # preview
~/.local/bin/system-ai-organize --apply     # ejecutar

# Iniciar control por gestos
systemctl --user start system-ai-gestures
```

---

## Tuning y troubleshooting

### Observer reporta falsos positivos

- Bajar threshold de un umbral específico en el prompt del observer (editar `system-ai-observer` constante `SYSTEM_PROMPT`).
- Aumentar lista WHITELIST procs en `system-ai-observer` y `system-ai-approve`.

### Organizer clasifica mal

- Editar `~/.config/system-ai/organize.json` → ajustar `hint` de la categoría.
- Subir `confidence_threshold` a 0.95 (más conservador, más al unknowns).
- Probar `--dry-run` para ver propuestas sin mover.

### Gestures no detecta o muy sensible

- Correr `~/.local/bin/system-ai-gestures --debug` para ventana visual con overlay de ángulos/distancias.
- Ajustar env vars antes de start: `HEAD_MIN_VEL=0.35 systemctl --user start system-ai-gestures` no funciona; usar override:
  ```bash
  systemctl --user edit system-ai-gestures
  # añadir:
  # [Service]
  # Environment="HEAD_MIN_VEL=0.35"
  ```

### Ollama no usa GPU

```bash
ollama ps   # debe decir PROCESSOR=100% GPU
nvidia-smi --query-gpu=memory.used --format=csv,noheader
```

Si dice CPU: probable que se quedó proceso runner zombie ocupando VRAM. `sudo kill -9 <pid_de_runner>`.

### Diagnóstico general

```bash
ai-explain --service ollama
ai-explain --service system-ai
ai-boot-analyze
journalctl --user -u system-ai-gestures -f
```

---

## Privacidad y seguridad

- **LLM 100% local** vía ollama, sin egress de prompts ni snapshots.
- **Gestures usa webcam SOLO con start manual.** No autostart. Frames en memoria.
- **Sudoers strict:** solo 4 reglas específicas, sin wildcards peligrosos.
- **Tools auto-exec** limitados a `drop_caches` (no destructivo) + `set_profile` (cambia power state, reversible).
- **Kill operations** requieren confirmación humana via `system-ai-approve`.
- **WHITELIST** hardcoded de procesos críticos para evitar kill accidental.
- **Organize trash** usa `gio trash` (recuperable, no rm).

---

## Estructura del repo

```
omen-ai-pc/
├── README.md                    ← este archivo
├── scripts/                     ← 16 binarios CLI
│   ├── system-ai-observer       ← núcleo observer
│   ├── system-ai-watch-journal  ← watcher journal
│   ├── system-ai-approve        ← y/N CLI tools
│   ├── system-ai-profile        ← perf/balanced/quiet
│   ├── system-ai-daily-report   ← MD daily summary
│   ├── system-ai-idle-tasks     ← maintenance idle
│   ├── system-ai-battery-collect ← batería sampler
│   ├── system-ai-organize       ← Downloads classifier
│   ├── system-ai-gestures       ← webcam mediapipe
│   ├── ai-ask                   ← query libre
│   ├── ai-explain               ← pipe logs
│   ├── ai-boot-analyze          ← boot diagnostics
│   ├── ai-crash-autopsy         ← coredumpctl
│   ├── ai-search                ← embeddings RAG
│   ├── ai-update-check          ← pre pacman -Syu
│   └── ai-battery               ← ETA + análisis
├── systemd/user/                ← unit files
├── config/
│   └── organize.json            ← categorías + roots organizer
└── docs/
    └── (notas adicionales)
```

---

## Roadmap / ideas futuras

- jig MCP exposer (tools del system-ai como MCP server)
- Hyprland socket2 live workload detection (no poll)
- Project-aware RAG (index `~/Projects/`)
- Voice (whisper.cpp + piper) — descartado en favor de gestures
- Predictive battery con curva drain por workload (parcialmente implementado en ai-battery)

---

## Créditos

- Hardware: HP OMEN 15-en0xxx
- LLM: [Qwen2.5-Coder](https://qwenlm.github.io/) (Alibaba), [Phi-3.5](https://huggingface.co/microsoft/Phi-3.5-mini-instruct) (Microsoft), [nomic-embed-text](https://www.nomic.ai/blog/posts/nomic-embed-text-v1) (Nomic)
- Runtime: [ollama](https://ollama.com/)
- Vision: [MediaPipe Tasks](https://developers.google.com/mediapipe) (Google)
- Sistema: Arch Linux + Hyprland + systemd

Co-diseñado entre el usuario (Iter) y Claude (Anthropic) durante una sesión iterativa de implementación.
