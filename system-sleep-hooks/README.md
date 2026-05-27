# System-sleep hooks

Scripts root-owned para `/usr/lib/systemd/system-sleep/` que arreglan deadlocks específicos de este hardware (HP OMEN + NVIDIA RTX 2060 Mobile + AMD iGPU).

## mpvpaper-pause

**Problema:** `mpvpaper` (wallpaper de video usado por izzy-theme) bloquea el ciclo freeze del kernel durante suspend/hibernate. Stack trace en `nvidia_uvm` driver → `Freezing user space processes failed after 20s (1 tasks refusing to freeze)` → pantalla negra al despertar, requiere reset forzado.

**Fix:** SIGSTOP a mpvpaper antes de suspender, SIGCONT al despertar. Driver UVM libera limpio cuando el proceso GPU está pausado.

### Instalación

```bash
sudo install -m 755 system-sleep-hooks/mpvpaper-pause /usr/lib/systemd/system-sleep/mpvpaper-pause
```

### Verificar

```bash
systemctl suspend   # debería suspender + despertar limpio
```
