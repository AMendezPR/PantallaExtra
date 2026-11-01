# PantallaExtra 🖥️➜📱

Usa tu **iPad como segundo monitor táctil** de tu computador (Windows, Mac o Linux), por **Wi-Fi** o **cable USB**.
Lo que tocas en el iPad se convierte en clics, arrastres y desplazamiento en el computador.

Tiene dos partes:

| Parte | Dónde corre | Carpeta |
|---|---|---|
| **Servidor** | En el computador. Captura la pantalla y recibe los toques. | `server/` |
| **App nativa** | En el iPad (iPadOS 16 o más nuevo). | `ios/` |
| *Cliente web (extra)* | En Safari del iPad. **No hay que instalar nada.** | `server/web/` |

---

## 1. Preparar el computador (servidor)

Necesitas **Python 3.9 o más nuevo** ([python.org](https://www.python.org/downloads/)).

```bash
cd ipad-monitor/server
python -m venv .venv
# Windows:      .venv\Scripts\activate
# Mac / Linux:  source .venv/bin/activate
pip install -r requirements.txt

python pantalla_server.py --listar      # ver los monitores disponibles
python pantalla_server.py --monitor 2   # enviar el monitor 2 al iPad
```

Al arrancar muestra algo así:

```
PantallaExtra listo. Monitor 2: 1920x1080
  App iPad (Wi-Fi):  192.168.1.20  puerto 7001
  Safari en el iPad: http://192.168.1.20:8080
```

**Permisos:**
- **Mac:** Ajustes del Sistema → Privacidad y seguridad → da permiso a la Terminal en **Grabación de pantalla** (para ver la pantalla) y en **Accesibilidad** (para que funcionen los toques). Después reinicia la Terminal.
- **Windows:** la primera vez acepta el aviso del Firewall (marca “Redes privadas”).

### ¿Espejo o segundo monitor de verdad?

El servidor envía **un monitor real del computador**. Si solo tienes una pantalla, el iPad la muestra igual que el computador (espejo).
Para que el iPad sea **una pantalla extra** (extender el escritorio), crea un monitor virtual y envía ese:

- **Windows 10/11:** instala un controlador de pantalla virtual, por ejemplo *Virtual Display Driver* (proyecto de código abierto en GitHub, `VirtualDrivers/Virtual-Display-Driver`). Aparecerá un monitor nuevo en Configuración → Pantalla. Ponle la resolución del iPad (por ejemplo 2360×1640 o 2048×1536) y elige “Extender estas pantallas”. Después usa `--listar` y `--monitor N` para enviar ese monitor.
- **Mac:** las Mac ya traen **Sidecar** (Centro de control → Duplicar pantalla → tu iPad), que hace esto de forma nativa. Si prefieres usar PantallaExtra, crea una pantalla virtual con una app como *BetterDisplay* y envíala con `--monitor N`.
- **Linux (X11):** agrega una salida virtual con `xrandr` y envíala con `--monitor N`.

Opciones útiles: `--fps 30`, `--calidad 70` (de 1 a 95), `--ancho-max 2048`, `--solo-ver` (sin control táctil) y `--sin-web`.

---

## 2. Instalar la app en el iPad

La app no está en la App Store, así que la instalas tú. Elige una opción:

### Opción A: tienes una Mac con Xcode
```bash
brew install xcodegen
cd ipad-monitor/ios
xcodegen generate
open PantallaExtra.xcodeproj
```
En Xcode: selecciona el target → *Signing & Capabilities* → elige tu Apple ID (sirve una cuenta gratuita) y cambia el *Bundle Identifier* por uno único. Conecta el iPad y presiona ▶︎.
La primera vez, en el iPad: Ajustes → General → VPN y gestión de dispositivos → confía en tu perfil de desarrollador. Si tu iPad lo pide, activa también el **Modo de desarrollador** (Ajustes → Privacidad y seguridad).

### Opción B: no tienes Mac (Windows)
1. En GitHub, abre la pestaña **Actions** → “Compilar app PantallaExtra (iPad)” → la última ejecución → descarga el artefacto **PantallaExtra-ipa** (es un .zip que contiene `PantallaExtra.ipa`). Esa ejecución compila la app en un Mac de GitHub cada vez que cambia `ios/`; también puedes lanzarla con “Run workflow”.
2. Instala **Sideloadly** (y iTunes o Apple Devices, para que Windows reconozca el iPad).
3. Conecta el iPad por USB, arrastra el `.ipa` a Sideloadly, escribe tu Apple ID y presiona *Start*.
4. En el iPad: Ajustes → General → VPN y gestión de dispositivos → confía en tu perfil.

> Con un Apple ID gratuito, la app **caduca a los 7 días**: hay que volver a instalarla (con Sideloadly basta con repetir el paso 3). Con una cuenta de desarrollador de pago dura un año.

### Opción C: sin instalar nada
Abre en Safari la dirección `http://<ip>:8080` que muestra el servidor. Para usarla a pantalla completa: Compartir → **Agregar a pantalla de inicio**. Tiene los mismos gestos que la app, pero solo funciona por Wi-Fi.

---

## 3. Conectar

### Por Wi-Fi
1. El computador y el iPad deben estar en **la misma red**.
2. En el computador: `python pantalla_server.py --monitor N`
3. En la app: elige **Wi-Fi**, escribe la IP que mostró el servidor y el puerto `7001`, y toca **Usar como monitor**.
   La primera vez, iPadOS pide permiso para la **red local**: acéptalo.

### Por cable USB
Por USB, la app **escucha** y el computador se conecta a ella con un reenviador USB:

1. Conecta el iPad por cable y toca *Confiar en este computador*.
   (En Windows necesitas iTunes o la app *Apple Devices* para el controlador).
2. En la app: elige **Cable USB**, deja el puerto `7001` y toca **Usar como monitor**.
3. En el computador, en una terminal, inicia el reenviador:
   ```bash
   pip install pymobiledevice3
   pymobiledevice3 usbmux forward 7002 7001
   ```
   (o con libimobiledevice: `iproxy 7002 7001`)
4. En otra terminal: `python pantalla_server.py --monitor N --usb`

Por cable la imagen es más estable y no depende del Wi-Fi.

---

## Gestos

| En el iPad | En el computador |
|---|---|
| Toque | Clic |
| Dos toques rápidos | Doble clic |
| Arrastrar con un dedo | Mantener el clic y arrastrar (seleccionar, mover ventanas) |
| Mantener presionado | Clic derecho |
| Toque con dos dedos | Clic derecho |
| Arrastrar con dos dedos | Desplazar (scroll) |
| Apple Pencil / trackpad sin tocar | Mover el puntero |
| Botón ⌨︎ | Teclado: escribe en el computador (también sirve un teclado físico, con sus flechas y Esc) |
| Botón ✕ | Desconectar |

## Limitaciones

- La imagen viaja como JPEG: hay algo de retraso (de 50 a 150 ms en una buena red Wi-Fi). Sirve para documentos, navegador, paletas de herramientas o una agenda; no para juegos. Si va lento, baja `--fps` o `--calidad`.
- No transmite audio y la imagen no muestra el puntero del mouse.
- Los toques se envían como mouse (un dedo a la vez), no como multitáctil nativo de Windows.
- El servidor no tiene contraseña: úsalo solo en redes de confianza (tu casa u oficina).
