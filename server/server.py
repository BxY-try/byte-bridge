"""
ByteBridge Server
-----------------
Menghubungkan HP ke PC via WiFi:
- Remote Numpad
- Remote Media & Volume
- Remote Presenter / Navigasi
- Trackpad & Mouse PC
- Pintasan / Hotkey & Teks

Juga menyediakan Web App bawaan (PWA) di http://<IP_PC>:8080
sehingga bisa langsung dipakai dari browser HP tanpa install aplikasi tambahan!
"""

import warnings
warnings.filterwarnings("ignore")

import eventlet
eventlet.monkey_patch()

import io
import json
import os
import socket
import sys
import threading
import time

# Pastikan console Windows mendukung karakter UTF-8
if sys.platform.startswith("win"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

from flask import Flask, jsonify, render_template, send_from_directory
from flask_socketio import SocketIO
import pyautogui
import pyperclip
import qrcode

# ---------- Konfigurasi ----------
TCP_PORT = 8080
UDP_DISCOVERY_PORT = 37020
BROADCAST_INTERVAL = 2
SERVICE_TAG = "numkey-server"  # kompatibel dengan Flutter discovery_service.dart

pyautogui.FAILSAFE = False

# Setup Flask & SocketIO
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
app = Flask(
    __name__,
    template_folder=os.path.join(BASE_DIR, "templates"),
    static_folder=os.path.join(BASE_DIR, "static"),
)
app.config["SECRET_KEY"] = "bytebridge_secret_key"

# Inisialisasi SocketIO (menggunakan eventlet secara otomatis)
socketio = SocketIO(app, cors_allowed_origins="*")


def get_all_local_ips():
    """Ambil semua alamat IPv4 lokal (WiFi, LAN, dll)."""
    ips = set()
    try:
        hostname = socket.gethostname()
        for ip in socket.gethostbyname_ex(hostname)[2]:
            if not ip.startswith("127."):
                ips.add(ip)
    except Exception:
        pass

    # Tambahan fallback pakai dummy UDP connect
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        primary = s.getsockname()[0]
        s.close()
        ips.add(primary)
    except Exception:
        pass

    return sorted(list(ips)) if ips else ["127.0.0.1"]


def get_primary_ip() -> str:
    """Ambil IP utama yang paling mungkin digunakan untuk koneksi HP (utamakan 192.168.x.x WiFi)."""
    all_ips = get_all_local_ips()
    # Prioritaskan IP class C rumahan (192.168.x.x) karena biasanya interface WiFi
    for ip in all_ips:
        if ip.startswith("192.168."):
            return ip
    for ip in all_ips:
        if ip.startswith("10.") or ip.startswith("172."):
            return ip
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return all_ips[0] if all_ips else "127.0.0.1"


def udp_broadcaster():
    """Broadcast identitas server via UDP agar Flutter app bisa auto-discover."""
    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    while True:
        try:
            local_ip = get_primary_ip()
            payload = json.dumps({
                "service": SERVICE_TAG,
                "name": "ByteBridge",
                "ip": local_ip,
                "port": TCP_PORT,
            }).encode("utf-8")
            udp_sock.sendto(payload, ("<broadcast>", UDP_DISCOVERY_PORT))
        except OSError:
            pass
        except Exception as e:
            print(f"[Discovery] Error: {e}")
        time.sleep(BROADCAST_INTERVAL)


# ---------- Flask HTTP Routes ----------

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/manifest.json")
def manifest():
    return send_from_directory(os.path.join(BASE_DIR, "static"), "manifest.json")


@app.route("/status")
def status():
    return jsonify({
        "status": "online",
        "service": "ByteBridge",
        "primary_ip": get_primary_ip(),
        "all_ips": get_all_local_ips(),
        "port": TCP_PORT,
    })


# ---------- Socket.IO Events ----------

connected_clients = 0

@socketio.on("connect")
def on_connect():
    global connected_clients
    connected_clients += 1
    print(f"[Koneksi] Client terhubung! Total klien aktif: {connected_clients}")


@socketio.on("disconnect")
def on_disconnect():
    global connected_clients
    connected_clients = max(0, connected_clients - 1)
    print(f"[Koneksi] Client terputus. Sisa klien aktif: {connected_clients}")


@socketio.on("keypress")
def on_keypress(data):
    """
    Menangani penekanan satu tombol:
    - Numpad: '0'-'9', '.', '+', '-', '*', '/', 'enter', 'backspace', 'tab', 'esc'
    - Media: 'volumeup', 'volumedown', 'volumemute', 'playpause', 'prevtrack', 'nexttrack'
    - Navigasi: 'up', 'down', 'left', 'right', 'pageup', 'pagedown', 'home', 'end', 'space', 'f5'
    """
    key = (data or {}).get("key")
    if not key:
        return
    print(f"[Tombol] Tekan: {key}")
    try:
        pyautogui.press(key)
    except Exception as e:
        print(f"[Tombol] Gagal menekan '{key}': {e}")


@socketio.on("hotkey")
def on_hotkey(data):
    """
    Menangani kombinasi tombol pintas (shortcut):
    Contoh: {"keys": ["ctrl", "c"]}, {"keys": ["win", "d"]}
    """
    keys = (data or {}).get("keys")
    if not keys or not isinstance(keys, list):
        return
    print(f"[Hotkey] Menjalankan: {' + '.join(keys)}")
    try:
        pyautogui.hotkey(*keys)
    except Exception as e:
        print(f"[Hotkey] Gagal hotkey {keys}: {e}")


@socketio.on("mouse_move")
def on_mouse_move(data):
    """
    Menggerakkan kursor mouse relatif dari posisi saat ini.
    Contoh: {"dx": 10.5, "dy": -5.2}
    """
    dx = (data or {}).get("dx", 0)
    dy = (data or {}).get("dy", 0)
    try:
        pyautogui.moveRel(int(dx), int(dy))
    except Exception as e:
        print(f"[Mouse] Gerak gagal: {e}")


@socketio.on("mouse_click")
def on_mouse_click(data):
    """
    Klik mouse: {"button": "left" | "right" | "double"}
    """
    btn = (data or {}).get("button", "left")
    try:
        if btn == "double":
            pyautogui.doubleClick()
        elif btn in ("left", "right", "middle"):
            pyautogui.click(button=btn)
    except Exception as e:
        print(f"[Mouse] Klik gagal ({btn}): {e}")


@socketio.on("mouse_scroll")
def on_mouse_scroll(data):
    """
    Scroll mouse: {"dy": -100}
    """
    dy = (data or {}).get("dy", 0)
    try:
        pyautogui.scroll(int(dy))
    except Exception as e:
        print(f"[Mouse] Scroll gagal: {e}")


@socketio.on("text_input")
def on_text_input(data):
    """
    Mengirim teks langsung ke aplikasi PC yang aktif menggunakan clipboard.
    Mendukung semua karakter Unicode, emoji, dan baris baru.
    """
    text = (data or {}).get("text", "")
    if not text:
        return
    print(f"[Teks] Mengirim teks ke PC ({len(text)} karakter)")
    try:
        old_clip = pyperclip.paste()
        pyperclip.copy(text)
        pyautogui.hotkey("ctrl", "v")
        # Berikan jeda sejenak agar paste selesai sebelum clipboard dikembalikan
        threading.Timer(0.5, lambda: pyperclip.copy(old_clip)).start()
    except Exception as e:
        # Fallback jika clipboard error
        try:
            pyautogui.write(text)
        except Exception:
            print(f"[Teks] Gagal input teks: {e}")


def print_banner(primary_ip, all_ips):
    """Tampilkan banner terminal yang keren dan QR Code untuk kemudahan akses."""
    print("=" * 60)
    print("  🌉  BYTEBRIDGE SERVER — Remote PC Controller via WiFi")
    print("=" * 60)
    print()
    print("  Status: AKTIF & SIAP MENERIMA KONEKSI")
    print(f"  Port:   {TCP_PORT}")
    print()
    print("  Cara Menggunakan di Smartphone Anda:")
    print("  1. Pastikan HP dan PC terhubung ke WiFi / Hotspot yang SAMA.")
    print("  2. Buka browser HP (Chrome / Safari / dll) dan buka alamat:")
    print(f"     👉  http://{primary_ip}:{TCP_PORT}")
    if len(all_ips) > 1:
        print("     Alamat alternatif lain:")
        for ip in all_ips:
            if ip != primary_ip:
                print(f"     - http://{ip}:{TCP_PORT}")
    print()
    print("  3. Atau SCAN QR CODE DI BAWAH DENGAN KAMERA HP ANDA:")
    print()

    # Cetak QR Code di terminal
    try:
        qr = qrcode.QRCode(box_size=1, border=1)
        qr.add_data(f"http://{primary_ip}:{TCP_PORT}")
        qr.make(fit=True)
        # Gunakan buffer agar output konsisten
        f = io.StringIO()
        qr.print_ascii(out=f, invert=True)
        print(f.getvalue())
    except Exception:
        print("  (Kamera HP bisa langsung ketik URL di atas jika QR code tidak muncul)")

    print("-" * 60)
    print("  Fitur Remote: Numpad | Media | Presentasi | Trackpad | Teks")
    print("  Tekan Ctrl + C di terminal ini untuk mematikan server.")
    print("=" * 60)
    print()


if __name__ == "__main__":
    # Jalankan thread UDP Broadcaster untuk discovery aplikasi Flutter
    threading.Thread(target=udp_broadcaster, daemon=True).start()

    primary_ip = get_primary_ip()
    all_ips = get_all_local_ips()
    print_banner(primary_ip, all_ips)

    # Jalankan server Socket.IO + Flask
    socketio.run(app, host="0.0.0.0", port=TCP_PORT)
