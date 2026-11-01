# Contexto del proyecto PantallaExtra (para continuar en la PC)

> Este archivo resume una sesión anterior de Claude Code en la nube. Si eres Claude
> leyendo esto en la PC del usuario: sigue las **Tareas pendientes** en orden.
> Habla con el usuario en **español**, paso a paso y con lenguaje sencillo; no es
> programador.

## Quién es el usuario y qué quiere

- Tiene una **PC con Windows** y un **iPad**. **No tiene Mac**.
- Quiere usar el **iPad como segundo monitor de la PC**, por **cable USB o Wi-Fi**,
  y que **funcione el táctil** (tocar el iPad = usar el mouse de la PC).
- Primero pidió algo como la “Duplicación del iPhone” de macOS, pero en el iPad.
  Le explicamos que es imposible: iOS no deja que una app controle otro iPhone,
  y Safari en el iPhone no puede compartir la pantalla. Por eso cambió de idea a
  “iPad como segundo monitor táctil”, que es este proyecto. No vuelvas a esa idea.
- El repositorio es `AMendezPR/PantallaExtra`, rama `main`. El usuario decidió usar
  solo la cuenta `AMendezPR`: no uses ninguna otra.
  PantallaExtra vive en `ipad-monitor/` y en `.github/workflows/ipad-app.yml`.

## Arquitectura

```
 PC con Windows                                    iPad
 ┌──────────────────────────────┐                 ┌──────────────────────────┐
 │ server/pantalla_server.py    │  JPEG (frames)  │ App nativa PantallaExtra │
 │  - captura un monitor (mss)  │ ──────────────► │  (SwiftUI + UIKit)       │
 │  - JPEG con Pillow           │                 │  o Safari: server/web/   │
 │  - mouse/teclado con pynput  │ ◄────────────── │  gestos -> eventos JSON  │
 └──────────────────────────────┘  toques (JSON)  └──────────────────────────┘
```

Archivos:

| Archivo | Qué hace |
|---|---|
| `server/pantalla_server.py` | Servidor en Python. TCP en el puerto 7001 para la app; HTTP y WebSocket en el 8080 para Safari; modo `--usb` que se conecta a `127.0.0.1:7002`. |
| `server/requirements.txt` | `mss`, `Pillow`, `pynput`, `aiohttp`. |
| `server/web/index.html` | Cliente web para Safari: muestra los frames y convierte los gestos en eventos por WebSocket. |
| `ios/project.yml` | Proyecto para XcodeGen (iOS 16+, bundle `com.pantallaextra.app`, Swift 5). Lleva `NSLocalNetworkUsageDescription`. |
| `ios/PantallaExtra/PantallaExtraApp.swift` | App, `Session`, pantalla de conexión (Wi-Fi o USB, IP, puerto) y vista del monitor. |
| `ios/PantallaExtra/StreamClient.swift` | Red con Network.framework. Wi-Fi: `NWConnection` al computador, con reconexión cada 1,5 s. USB: `NWListener` en el puerto 7001. |
| `ios/PantallaExtra/ScreenView.swift` | `UIImageView` que muestra los frames (decodifica solo el más reciente), gestos, y `UIKeyInput` para el teclado. |
| `../.github/workflows/ipad-app.yml` | Compila el `.ipa` sin firmar en `macos-15` y lo sube como artefacto `PantallaExtra-ipa`. |
| `README.md` | Guía para el usuario (Windows, Mac, Sideloadly, USB y gestos). |

### Protocolo TCP (app nativa)
Cada mensaje es `[tipo: 1 byte][largo: 4 bytes big-endian][datos]`:
- `1` HELLO, del servidor al iPad: JSON `{"width","height","name"}` del monitor capturado.
- `2` FRAME, del servidor al iPad: un JPEG. El servidor solo envía si la pantalla
  cambió (compara el CRC32 de los píxeles) y reenvía cada 2 s para mantener viva
  la conexión. Un cliente lento se salta frames.
- `3` INPUT, del iPad al servidor: JSON con `t` =
  `move|down|up|click|dclick|rclick` (con `x`, `y` normalizados de 0 a 1 dentro
  de la imagen), `scroll` (con `dx`, `dy` enteros, en el sentido de pynput),
  `text` (con `s`) o `key` (con `k` = backspace, enter, tab, esc, left, right,
  up, down, delete o space).

El cliente web usa lo mismo por `/ws`: HELLO llega como texto, los frames como
binario y los eventos se envían como texto JSON.

### Modo USB
La app **escucha** en el puerto 7001 del iPad. En la PC, un reenviador usbmux
lleva `127.0.0.1:7002` al puerto 7001 del iPad (`pymobiledevice3 usbmux forward 7002 7001`
o `iproxy 7002 7001`). El servidor con `--usb` se conecta a 7002 y reintenta cada 1,5 s.
En Windows hace falta iTunes de apple.com (que trae el *Apple Mobile Device Service*).

### Gestos
| iPad | PC |
|---|---|
| Toque | Clic. Dos toques seguidos los toma Windows como doble clic. |
| Arrastrar con un dedo | `down` en el punto inicial, luego `move`, luego `up`. |
| Mantener presionado (0,55 s) | Clic derecho. |
| Toque con dos dedos | Clic derecho. |
| Arrastrar con dos dedos | Scroll (18 pt = 1 paso; desplazamiento natural). |
| Pencil o trackpad flotando | Mueve el puntero (`UIHoverGestureRecognizer`). |
| Botón ⌨︎ | Teclado en pantalla, que envía `text` y `key`. |

## Qué está probado y qué no

**Probado en Linux con Xvfb**, en la sesión de la nube:
- El servidor arranca, `--listar` funciona, y el HELLO y el JPEG llegan por TCP.
- Los eventos mueven el mouse al punto correcto: (0,5; 0,25) en una pantalla de
  1280×800 da (640, 200), y la esquina da (1279, 799).
- El cliente web con toques emulados en Chromium funciona: el arrastre terminó
  en el punto esperado (434, 280).
- El modo `--usb` funciona contra un falso iPad que escuchaba en el puerto 7002.

**NO probado:**
- **El código Swift nunca se compiló**: la sesión de la nube no tenía Xcode ni
  Swift. Puede tener errores de compilación.
- Nunca se ejecutó en **Windows** ni en un **iPad** de verdad.
- Nunca se probó el reenviador USB real.

## Tareas pendientes (en orden)

1. **Subir el código a GitHub:** `git push -u origin main` hacia `AMendezPR/PantallaExtra`.
2. **Probar el servidor en Windows:**
   - `py -m pip install -r ipad-monitor/server/requirements.txt`
   - `py ipad-monitor/server/pantalla_server.py --listar`
   - `py ipad-monitor/server/pantalla_server.py`
   - En el iPad, abrir en Safari `http://<ip>:8080` y probar todos los gestos.

   Puntos a vigilar:
   - **Escalado DPI** de Windows (125 % o 150 %): mss activa el modo DPI-aware y
     pynput debería quedar en las mismas coordenadas físicas. Comprueba que el
     toque cae justo donde se tocó, sobre todo en un monitor secundario con otra
     escala.
   - El aviso del Firewall: hay que aceptar “Redes privadas”.
3. **Pantalla extendida en Windows:**
   - Instalar *Virtual Display Driver* (GitHub `VirtualDrivers/Virtual-Display-Driver`).
   - Elegir “Extender estas pantallas” y una resolución tipo iPad (2048×1536 o 2360×1640).
   - Enviar ese monitor con `--monitor N`.
4. **Compilar la app:**
   - En GitHub → Actions, el workflow “Compilar app PantallaExtra (iPad)” se
     lanza solo cuando cambia `ipad-monitor/ios/**`, o a mano con *Run workflow*.
   - Si falla, lee el registro (`gh run view --log-failed`), corrige el Swift y
     vuelve a subirlo. Repite hasta que esté en verde.
   - Descarga el artefacto `PantallaExtra-ipa`.
5. **Instalar en el iPad desde Windows:**
   - Instalar iTunes de apple.com (no la versión de la Microsoft Store) y Sideloadly.
   - Arrastrar el `.ipa` a Sideloadly e iniciar sesión con el Apple ID del usuario.
   - En el iPad: Ajustes → General → VPN y gestión de dispositivos → Confiar.
   - Con un Apple ID gratuito la app caduca a los 7 días y hay que reinstalarla.
6. **Probar la app:** primero por Wi-Fi (IP y puerto 7001). Después por USB: modo
   USB en la app, `pymobiledevice3 usbmux forward 7002 7001` y el servidor con `--usb`.

## Ideas para después (solo si el usuario las pide)
- Video H.264 (VideoToolbox / ffmpeg) para tener menos retraso y gastar menos ancho de banda.
- Dibujar el cursor del mouse en la imagen. mss no lo captura.
- Contraseña o emparejamiento: ahora el servidor acepta a cualquiera en la red.
- Encontrar la PC sola con Bonjour (`_pantallaextra._tcp`), sin escribir la IP.
- Un `.bat` o acceso directo para arrancar el servidor con doble clic.
- Toques multitáctiles nativos de Windows (`InjectTouchInput`) en vez de mouse.
