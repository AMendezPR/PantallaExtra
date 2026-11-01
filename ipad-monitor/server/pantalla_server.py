#!/usr/bin/env python3
"""
PantallaExtra - servidor para usar un iPad como segundo monitor tactil.

Corre en el computador (Windows, macOS o Linux). Captura un monitor, lo envia
al iPad como JPEG y recibe los toques del iPad para mover/clicar el mouse.

Conexiones:
  * Wi-Fi  -> la app del iPad se conecta a  <ip-del-computador>:7001  (TCP)
  * USB    -> con --usb el servidor se conecta a 127.0.0.1:7002, que un
              reenviador USB (iproxy / pymobiledevice3) lleva al puerto 7001
              del iPad, donde la app escucha en modo "USB".
  * Navegador -> http://<ip-del-computador>:8080  (cliente web en Safari,
              sin instalar nada)

Protocolo TCP (ambos sentidos):  [tipo:1 byte][largo:4 bytes big-endian][datos]
  1 HELLO  servidor->cliente  JSON {"width", "height", "name"}
  2 FRAME  servidor->cliente  imagen JPEG
  3 INPUT  cliente->servidor  JSON con un evento (ver InputHandler)
"""
from __future__ import annotations

import argparse
import asyncio
import io
import json
import logging
import os
import re
import socket
import struct
import sys
import threading
import time
import zlib

import mss
from PIL import Image, ImageDraw

MSG_HELLO, MSG_FRAME, MSG_INPUT = 1, 2, 3
HEADER = struct.Struct(">BI")
MAX_INPUT_MSG = 64 * 1024
_MSS = getattr(mss, "MSS", None) or mss.mss  # mss>=10 renombro la clase

log = logging.getLogger("pantalla")

# Flecha del cursor (mss no lo captura, asi que lo dibujamos en cada frame)
CURSOR_SHAPE = ((0, 0), (0, 17), (4, 13), (7, 20), (10, 19), (7, 12), (12, 12))
CURSOR_SCALE = 1.5
# Nombre del monitor virtual que se envia al iPad
VIRTUAL_MONITOR = re.compile(r"vdd|virtual display|mtt", re.I)


def cursor_reader():
    """Devuelve una funcion que da el cursor relativo a un monitor, o None si esta fuera."""
    try:
        from pynput import mouse
        controller = mouse.Controller()
    except Exception as exc:  # p.ej. Linux sin X
        log.warning("No se puede leer el cursor (%s). No se dibujara.", exc)
        return lambda mon: None

    def read(mon: dict):
        x, y = controller.position
        x, y = x - mon["left"], y - mon["top"]
        return (x, y) if 0 <= x < mon["width"] and 0 <= y < mon["height"] else None
    return read


def draw_cursor(img: Image.Image, x: int, y: int) -> None:
    points = [(x + px * CURSOR_SCALE, y + py * CURSOR_SCALE) for px, py in CURSOR_SHAPE]
    ImageDraw.Draw(img).polygon(points, fill="white", outline="black", width=2)


def is_virtual(mon: dict) -> bool:
    return bool(VIRTUAL_MONITOR.search(str(mon.get("name", ""))))


def monitor_label(index: int, mon: dict) -> str:
    return f"Monitor {index} iPad" if is_virtual(mon) else f"Monitor {index}"


# --------------------------------------------------------------------------
# Captura de pantalla (hilo aparte, mss no es asincrono)
# --------------------------------------------------------------------------
class Capturer(threading.Thread):
    def __init__(self, monitor_index: int, fps: float, quality: int,
                 max_width: int, publish):
        super().__init__(daemon=True)
        self.monitor_index = monitor_index
        self.interval = 1.0 / max(1.0, fps)
        self.quality = quality
        self.max_width = max_width
        self.publish = publish            # callable(bytes), thread-safe
        self.active = threading.Event()   # solo captura si hay clientes
        self.force = threading.Event()    # reenviar aunque no cambie
        self.stopped = threading.Event()

    def run(self) -> None:
        with _MSS() as sct:
            read_cursor = cursor_reader()
            last_crc = last_cursor = None
            last_sent = 0.0
            while not self.stopped.is_set():
                if not self.active.wait(timeout=0.5):
                    continue
                t0 = time.perf_counter()
                mon = sct.monitors[self.monitor_index]
                shot = sct.grab(mon)
                crc = zlib.crc32(shot.raw)
                now = time.monotonic()
                cursor = read_cursor(mon)
                changed = crc != last_crc or cursor != last_cursor
                if changed or self.force.is_set() or now - last_sent > 2.0:
                    self.force.clear()
                    img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
                    if cursor:
                        draw_cursor(img, *cursor)
                    if self.max_width and img.width > self.max_width:
                        h = round(img.height * self.max_width / img.width)
                        img = img.resize((self.max_width, h), Image.BILINEAR)
                    buf = io.BytesIO()
                    img.save(buf, "JPEG", quality=self.quality)
                    self.publish(buf.getvalue())
                    last_crc, last_cursor, last_sent = crc, cursor, now
                # Si la pantalla no cambia, revisamos con menos frecuencia.
                wait = self.interval if changed else max(self.interval, 1 / 20)
                time.sleep(max(0.0, wait - (time.perf_counter() - t0)))


# --------------------------------------------------------------------------
# Distribucion del ultimo frame a todos los clientes
# --------------------------------------------------------------------------
class FrameHub:
    def __init__(self, loop: asyncio.AbstractEventLoop, capturer_factory,
                 monitors: list[dict], current: int, name: str, on_select):
        self.loop = loop
        self.monitors = monitors
        self.current = current
        self.name = name
        self.on_select = on_select        # callable(dict) al cambiar de monitor
        self.hello_seq = 0
        self.frame: bytes | None = None
        self.seq = 0
        self.cond = asyncio.Condition()
        self.clients = 0
        self.capturer: Capturer = capturer_factory(self._publish_threadsafe)
        self.capturer.start()

    def _publish_threadsafe(self, data: bytes) -> None:
        self.loop.call_soon_threadsafe(lambda: asyncio.ensure_future(self._publish(data)))

    async def _publish(self, data: bytes) -> None:
        async with self.cond:
            self.frame = data
            self.seq += 1
            self.cond.notify_all()

    def hello(self) -> dict:
        mon = self.monitors[self.current]
        return {"width": mon["width"], "height": mon["height"], "name": self.name,
                "current": self.current,
                "monitors": [{"index": i, "label": monitor_label(i, m)}
                             for i, m in enumerate(self.monitors) if i > 0]}

    async def select(self, index: int) -> None:
        """Cambia el monitor enviado y avisa a todos los clientes."""
        if index == self.current or not 1 <= index < len(self.monitors):
            return
        async with self.cond:
            self.current = index
            self.on_select(self.monitors[index])
            self.capturer.monitor_index = index
            self.capturer.force.set()
            self.frame = None
            self.hello_seq += 1
            self.cond.notify_all()
        log.info("Enviando monitor %d", index)

    def add_client(self) -> None:
        self.clients += 1
        self.capturer.force.set()
        self.capturer.active.set()

    def remove_client(self) -> None:
        self.clients -= 1
        if self.clients <= 0:
            self.clients = 0
            self.capturer.active.clear()

    async def stream(self, send, send_hello) -> None:
        """Envia el HELLO si cambio y siempre el frame mas reciente; un cliente lento se salta frames."""
        seen = seen_hello = -1
        while True:
            async with self.cond:
                await self.cond.wait_for(
                    lambda: self.hello_seq != seen_hello or (self.seq != seen and self.frame))
                hello = data = None
                if self.hello_seq != seen_hello:
                    seen_hello, hello = self.hello_seq, self.hello()
                else:
                    seen, data = self.seq, self.frame
            if hello is not None:
                await send_hello(hello)
            else:
                await send(data)


# --------------------------------------------------------------------------
# Toques del iPad -> mouse / teclado del computador
# --------------------------------------------------------------------------
class InputHandler:
    KEYS = {
        "backspace": "backspace", "enter": "enter", "tab": "tab", "esc": "esc",
        "left": "left", "right": "right", "up": "up", "down": "down",
        "delete": "delete", "space": "space",
    }

    def __init__(self, monitor: dict, enabled: bool):
        self.mon = monitor
        self.mouse = self.kb = None
        if not enabled:
            log.info("Control tactil desactivado (--solo-ver).")
            return
        try:
            from pynput import keyboard, mouse
            self._Button = mouse.Button
            self._Key = keyboard.Key
            self.mouse = mouse.Controller()
            self.kb = keyboard.Controller()
        except Exception as exc:  # p.ej. Linux sin X, permisos en macOS
            log.warning("No se pudo activar el control tactil (%s). Solo video.", exc)

    def _pos(self, ev: dict) -> tuple[int, int]:
        x = min(max(float(ev.get("x", 0)), 0.0), 1.0)
        y = min(max(float(ev.get("y", 0)), 0.0), 1.0)
        m = self.mon
        return (round(m["left"] + x * (m["width"] - 1)),
                round(m["top"] + y * (m["height"] - 1)))

    def handle(self, ev: dict) -> None:
        if self.mouse is None:
            return
        t = ev.get("t")
        B = self._Button
        try:
            if t in ("move", "down", "up", "click", "rclick", "dclick"):
                self.mouse.position = self._pos(ev)
            if t == "down":
                self.mouse.press(B.left)
            elif t == "up":
                self.mouse.release(B.left)
            elif t == "click":
                self.mouse.click(B.left)
            elif t == "dclick":
                self.mouse.click(B.left, 2)
            elif t == "rclick":
                self.mouse.click(B.right)
            elif t == "scroll":
                self.mouse.scroll(int(ev.get("dx", 0)), int(ev.get("dy", 0)))
            elif t == "text":
                self.kb.type(str(ev.get("s", ""))[:1000])
            elif t == "key":
                name = self.KEYS.get(str(ev.get("k")))
                if name:
                    key = getattr(self._Key, name)
                    self.kb.press(key)
                    self.kb.release(key)
        except Exception as exc:
            log.warning("Evento %r fallo: %s", t, exc)


async def handle_event(ev: dict, hub: FrameHub, inp: InputHandler) -> None:
    if ev.get("t") == "monitor":
        await hub.select(int(ev.get("i", 0)))
    else:
        inp.handle(ev)


# --------------------------------------------------------------------------
# Sesion sobre TCP (app nativa: Wi-Fi o USB)
# --------------------------------------------------------------------------
async def tcp_session(reader, writer, hub: FrameHub, inp: InputHandler, label: str):
    sock = writer.get_extra_info("socket")
    if sock is not None:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    async def send(kind: int, payload: bytes) -> None:
        writer.write(HEADER.pack(kind, len(payload)) + payload)
        await writer.drain()

    async def receive() -> None:
        while True:
            kind, length = HEADER.unpack(await reader.readexactly(HEADER.size))
            if length > MAX_INPUT_MSG:
                raise ValueError("mensaje demasiado grande")
            data = await reader.readexactly(length)
            if kind == MSG_INPUT:
                await handle_event(json.loads(data), hub, inp)

    log.info("iPad conectado (%s)", label)
    hub.add_client()
    tasks = []
    try:
        tasks = [asyncio.ensure_future(receive()),
                 asyncio.ensure_future(hub.stream(
                     lambda d: send(MSG_FRAME, d),
                     lambda h: send(MSG_HELLO, json.dumps(h).encode())))]
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in done:
            if t.exception() and not isinstance(t.exception(), (asyncio.IncompleteReadError, ConnectionError)):
                log.warning("Sesion %s: %s", label, t.exception())
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        for t in tasks:
            t.cancel()
        hub.remove_client()
        writer.close()
        log.info("iPad desconectado (%s)", label)


async def usb_loop(port: int, hub, inp) -> None:
    """Modo USB: el iPad escucha; nos conectamos a traves del reenviador local."""
    log.info("Modo USB: buscando el iPad en 127.0.0.1:%d (reenviador USB)...", port)
    while True:
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            await tcp_session(reader, writer, hub, inp, "USB")
        except (ConnectionError, OSError):
            pass
        await asyncio.sleep(1.5)


# --------------------------------------------------------------------------
# Cliente web (Safari) sobre WebSocket
# --------------------------------------------------------------------------
def make_web_app(hub: FrameHub, inp: InputHandler):
    from aiohttp import WSMsgType, web

    web_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")

    async def index(_request):
        return web.FileResponse(os.path.join(web_dir, "index.html"))

    async def ws_handler(request):
        ws = web.WebSocketResponse(max_msg_size=MAX_INPUT_MSG)
        await ws.prepare(request)
        log.info("Navegador conectado (%s)", request.remote)
        hub.add_client()
        sender = asyncio.ensure_future(hub.stream(
            ws.send_bytes, lambda h: ws.send_str(json.dumps(h))))
        try:
            async for msg in ws:
                if msg.type == WSMsgType.TEXT:
                    await handle_event(json.loads(msg.data), hub, inp)
        except Exception as exc:
            log.warning("WebSocket: %s", exc)
        finally:
            sender.cancel()
            hub.remove_client()
            log.info("Navegador desconectado (%s)", request.remote)
        return ws

    app = web.Application()
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)
    return app


# --------------------------------------------------------------------------
def local_ips() -> list[str]:
    ips = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    return sorted(ip for ip in ips if not ip.startswith("127."))


def list_monitors() -> None:
    with _MSS() as sct:
        for i, m in enumerate(sct.monitors):
            tag = "todos los monitores juntos" if i == 0 else monitor_label(i, m)
            print(f"  {i}: {m['width']}x{m['height']} en ({m['left']},{m['top']}) {tag}")


async def main_async(args) -> None:
    with _MSS() as sct:
        monitors = [dict(m) for m in sct.monitors]
    if args.monitor is None:
        args.monitor = next((i for i, m in enumerate(monitors) if i and is_virtual(m)), 1)
    if not 0 <= args.monitor < len(monitors):
        sys.exit(f"Monitor {args.monitor} no existe. Usa --listar.")
    monitor = monitors[args.monitor]

    loop = asyncio.get_running_loop()
    inp = InputHandler(monitor, enabled=not args.solo_ver)
    hub = FrameHub(loop, lambda publish: Capturer(
        args.monitor, args.fps, args.calidad, args.ancho_max, publish),
        monitors, args.monitor, socket.gethostname(), lambda mon: setattr(inp, "mon", mon))

    servers = []
    tcp = await asyncio.start_server(
        lambda r, w: tcp_session(r, w, hub, inp, w.get_extra_info("peername")[0]),
        host=args.host, port=args.puerto)
    servers.append(tcp)

    web_runner = None
    if not args.sin_web:
        from aiohttp import web
        web_runner = web.AppRunner(make_web_app(hub, inp), access_log=None)
        await web_runner.setup()
        await web.TCPSite(web_runner, args.host, args.puerto_web).start()

    print()
    print(f"PantallaExtra listo. Monitor {args.monitor}: {monitor['width']}x{monitor['height']}")
    for ip in local_ips() or ["<ip-de-este-equipo>"]:
        print(f"  App iPad (Wi-Fi):  {ip}  puerto {args.puerto}")
        if web_runner:
            print(f"  Safari en el iPad: http://{ip}:{args.puerto_web}")
    print("  Ctrl+C para salir.\n")

    tasks = [asyncio.ensure_future(tcp.serve_forever())]
    if args.usb:
        tasks.append(asyncio.ensure_future(usb_loop(args.puerto_usb, hub, inp)))
    try:
        await asyncio.gather(*tasks)
    finally:
        hub.capturer.stopped.set()
        if web_runner:
            await web_runner.cleanup()


def main() -> None:
    p = argparse.ArgumentParser(description="Usa tu iPad como segundo monitor tactil.")
    p.add_argument("--listar", action="store_true", help="muestra los monitores y sale")
    p.add_argument("--monitor", type=int, default=None,
                   help="monitor inicial (def. el virtual si existe, si no el 1; usa --listar)")
    p.add_argument("--fps", type=float, default=30, help="cuadros por segundo (def. 30)")
    p.add_argument("--calidad", type=int, default=70, help="calidad JPEG 1-95 (def. 70)")
    p.add_argument("--ancho-max", type=int, default=2048,
                   help="ancho maximo enviado en pixeles, 0 = sin limite (def. 2048)")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--puerto", type=int, default=7001, help="puerto TCP para la app (def. 7001)")
    p.add_argument("--puerto-web", type=int, default=8080, help="puerto del cliente web (def. 8080)")
    p.add_argument("--sin-web", action="store_true", help="no iniciar el cliente web")
    p.add_argument("--usb", action="store_true", help="conectar tambien por USB")
    p.add_argument("--puerto-usb", type=int, default=7002,
                   help="puerto local del reenviador USB (def. 7002)")
    p.add_argument("--solo-ver", action="store_true", help="no controlar mouse/teclado")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    if args.listar:
        list_monitors()
        return
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
