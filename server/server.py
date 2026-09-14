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
eventlet.monkey_patch(thread=False)

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

import atexit
import queue
from flask import Flask, jsonify, render_template, send_from_directory
from flask_socketio import SocketIO, emit
import pyautogui
import pyperclip
import qrcode
import psutil
import ipaddress

# Import MediaManager
try:
    from media_manager import MediaManager
except ImportError:
    from server.media_manager import MediaManager

# Import AIService
try:
    from ai_service import AIService
except ImportError:
    from server.ai_service import AIService

ai_service = AIService()

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

# Inisialisasi MediaManager (GSMTC + pycaw)
media_manager = MediaManager()

def media_event_dispatcher():
    """
    Consumer greenlet yang membaca antrean MediaManager dan memancarkan media_state ke Socket.IO.
    Menerapkan Conflation (latest-write-wins): jika beberapa event menumpuk (misal scrubbing seek bar),
    semua event lama dikuras dan hanya state paling mutakhir yang dipancarkan ke client.
    """
    while getattr(media_manager, "_running", True):
        latest_state = None
        try:
            while not media_manager.state_queue.empty():
                latest_state = media_manager.state_queue.get_nowait()
        except queue.Empty:
            pass
        except Exception as e:
            print(f"[MediaDispatcher] Error saat drain queue: {e}")

        if latest_state is not None:
            try:
                socketio.emit("media_state", latest_state)
            except Exception as e:
                print(f"[MediaDispatcher] Error saat emit media_state: {e}")

        socketio.sleep(0.03)

def cleanup_media():
    if media_manager:
        media_manager.close()

atexit.register(cleanup_media)

atexit.register(cleanup_media)



def get_network_details():
    """Deteksi detail interface jaringan menggunakan psutil."""
    interfaces = []
    wifi_ip = None
    all_broadcasts = set()

    for iface, addrs in psutil.net_if_addrs().items():
        for a in addrs:
            if a.family == socket.AF_INET and not a.address.startswith("127.") and not a.address.startswith("169.254."):
                try:
                    net = ipaddress.IPv4Network(f"{a.address}/{a.netmask}", strict=False)
                    bcast = str(net.broadcast_address)
                    is_wifi = any(w in iface.lower() for w in ["wi-fi", "wlan", "wireless", "wifi"])
                    info = {
                        "name": iface,
                        "ip": a.address,
                        "broadcast": bcast,
                        "is_wifi": is_wifi
                    }
                    interfaces.append(info)
                    if bcast != a.address:
                        all_broadcasts.add((a.address, bcast))
                    if is_wifi and not wifi_ip:
                        wifi_ip = a.address
                except Exception:
                    pass

    # Fallback jika wifi_ip belum ketemu
    if not wifi_ip:
        for i in interfaces:
            if i["ip"].startswith("192.168."):
                wifi_ip = i["ip"]
                break
    if not wifi_ip and interfaces:
        wifi_ip = interfaces[0]["ip"]

    primary_ip = wifi_ip or "127.0.0.1"
    all_ips = [i["ip"] for i in interfaces] if interfaces else ["127.0.0.1"]
    return primary_ip, all_ips, interfaces, list(all_broadcasts)


def get_all_local_ips():
    _, all_ips, _, _ = get_network_details()
    return all_ips


def get_primary_ip() -> str:
    primary_ip, _, _, _ = get_network_details()
    return primary_ip


def udp_broadcaster():
    """Broadcast identitas server via UDP agar Flutter app bisa auto-discover.
    Memancarkan lewat broadcast subnet langsung dan binding interface fisik (Wi-Fi)
    agar tidak tertahan atau salah rute oleh VPN (ProTUN/WSL)."""
    while True:
        try:
            primary_ip, all_ips, interfaces, broadcast_pairs = get_network_details()
            payload = json.dumps({
                "service": SERVICE_TAG,
                "name": "ByteBridge",
                "ip": primary_ip,
                "port": TCP_PORT,
            }).encode("utf-8")

            # 1. Kirim via socket global broadcast
            try:
                global_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
                global_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                global_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                global_sock.sendto(payload, ("<broadcast>", UDP_DISCOVERY_PORT))
                global_sock.sendto(payload, ("255.255.255.255", UDP_DISCOVERY_PORT))
                global_sock.close()
            except Exception:
                pass

            # 2. Kirim via binding tiap interface fisik ke subnet broadcast masing-masing (bypass VPN)
            for iface_ip, bcast_addr in broadcast_pairs:
                try:
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                    s.bind((iface_ip, 0))
                    s.sendto(payload, (bcast_addr, UDP_DISCOVERY_PORT))
                    s.sendto(payload, ("255.255.255.255", UDP_DISCOVERY_PORT))
                    s.close()
                except Exception:
                    pass
        except Exception:
            pass
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
    # Kirim initial media_state secara lengkap (termasuk thumbnail jika ada)
    try:
        cur_state = media_manager.get_current_state()
        emit("media_state", cur_state)
    except Exception as e:
        print(f"[Koneksi] Gagal kirim initial media_state: {e}")


@socketio.on("media_command")
def on_media_command(data):
    """
    Menangani perintah kontrol media dua arah:
    Payload: {"action": "play_pause"|"play"|"pause"|"next"|"previous"|"seek"|"shuffle"|"repeat"|"set_rate"|"switch_session"|"set_volume"|"toggle_mute", "value": ...}
    """
    action = (data or {}).get("action")
    value = (data or {}).get("value")
    if not action:
        return
    print(f"[MediaCommand] Action: {action}, Value: {value}")
    try:
        media_manager.handle_command(action, value)
    except Exception as e:
        print(f"[MediaCommand] Gagal handle command '{action}': {e}")


@socketio.on("disconnect")
def on_disconnect():
    global connected_clients
    connected_clients = max(0, connected_clients - 1)
    print(f"[Koneksi] Client terputus. Sisa klien aktif: {connected_clients}")


@socketio.on("keypress")
def on_keypress(data):
    """
    Menangani penekanan satu tombol:
    - Numpad: '0'-'9', '.', '+', '-', '*', '/', '%', 'enter', 'backspace', 'del', 'tab', 'esc'
    - Media: 'volumeup', 'volumedown', 'volumemute', 'playpause', 'prevtrack', 'nexttrack'
    - Navigasi: 'up', 'down', 'left', 'right', 'pageup', 'pagedown', 'home', 'end', 'space', 'f5'
    """
    key = (data or {}).get("key")
    if not key:
        return
    print(f"[Tombol] Tekan: {key}")
    try:
        if key == '%':
            try:
                pyautogui.press('%')
            except Exception:
                pyautogui.hotkey('shift', '5')
        elif key in ('del', 'delete'):
            pyautogui.press('delete')
        else:
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


@socketio.on("ai_query")
def on_ai_query(data):
    """
    Menangani permintaan analisis OCR & LLM dari HP.
    Mencetak teks OCR dan jawaban AI secara BESAR dan JELAS di terminal server,
    serta menyalin jawaban ke clipboard Windows secara hening (konsep Ctrl+C, tanpa injeksi Ctrl+V).
    """
    data = data or {}
    ocr_text = data.get("text") or data.get("ocr_text")
    image_data = data.get("image")
    prompt = data.get("prompt")

    print("\n" + "=" * 74)
    print("📸 [BYTEBRIDGE AI ASSISTANT] - Menerima permintaan dari HP...")
    print("=" * 74)

    res = ai_service.process(ocr_text=ocr_text, image_data=image_data, prompt=prompt)

    if res.get("success"):
        detected_text = res.get("ocr_text", "").strip()
        llm_answer = res.get("llm_answer", "").strip()
        model_name = res.get("model_used", "Gemini")

        # 1. Cetak ke Terminal secara BESAR, RAPI, dan JELAS
        print("\n" + "╔" + "═" * 72 + "╗")
        print("║  📸 TEKS TERDETEKSI DARI LAYAR (HASIL OCR)")
        print("╠" + "═" * 72 + "╣")
        for line in detected_text.splitlines():
            print(f"  {line}")
        print("\n" + "╠" + "═" * 72 + "╣")
        print(f"║  🤖 JAWABAN & ANALISIS AI ({model_name})")
        print("╠" + "═" * 72 + "╣\n")
        print(llm_answer)
        print("\n" + "╚" + "═" * 72 + "╝")

        # 2. Sinkronkan ke Clipboard Windows (Silent Copy, konsep Ctrl+C)
        try:
            pyperclip.copy(llm_answer)
            print("[✓] Jawaban AI otomatis disalin ke Clipboard PC! (Siap Ctrl+V manual jika dibutuhkan)")
        except Exception as e:
            print(f"[!] Gagal menyalin ke clipboard PC: {e}")
        print("=" * 74 + "\n")

        # 3. Kirim status sukses balik ke HP
        emit("ai_response", {
            "success": True,
            "ocr_text": detected_text,
            "llm_answer": llm_answer,
            "model": model_name
        })
    else:
        err_msg = res.get("error", "Terjadi kesalahan")
        print(f"\n[AI Error] ❌ {err_msg}\n" + "=" * 74 + "\n")
        emit("ai_response", {
            "success": False,
            "error": err_msg
        })


@socketio.on("save_ai_config")
def on_save_ai_config(data):
    """Simpan konfigurasi API Key dari HP."""
    if not data or not isinstance(data, dict):
        return
    success = ai_service.save_config(data)
    emit("save_ai_config_response", {
        "success": success,
        "message": "Konfigurasi AI berhasil disimpan" if success else "Gagal menyimpan konfigurasi AI"
    })


def print_banner(primary_ip, all_ips):
    """Tampilkan banner terminal yang jelas membedakan cara pakai Aplikasi Android vs Web Remote."""
    print("=" * 64)
    print("  === BYTEBRIDGE SERVER - PC Remote Controller via WiFi ===")
    print("=" * 64)
    print()
    print("  [+] STATUS     : SERVER AKTIF & SIAP MENERIMA KONEKSI")
    print(f"  [+] IP WiFi PC : {primary_ip} (Port: {TCP_PORT})")
    if len(all_ips) > 1:
        other_ips = [ip for ip in all_ips if ip != primary_ip]
        print(f"  [+] IP Lainnya : {', '.join(other_ips)}")
    print()
    print("  [A] CARA PAKAI DI APLIKASI ANDROID (APK):")
    print("  --------------------------------------------------------------")
    print("  1. Buka aplikasi ByteBridge yang sudah Anda pasang di HP.")
    print("  2. Pastikan HP dan PC terhubung ke WiFi / Hotspot yang SAMA.")
    print("  3. Aplikasi akan otomatis mendeteksi server ini.")
    print(f"     -> JIKA TERTULIS 'Server tidak ditemukan':")
    print(f"        Tap ikon PENSIL (Edit) di pojok kanan atas aplikasi,")
    print(f"        lalu ketik IP: {primary_ip} dan tap 'Hubungkan'.")
    print()
    print("  [B] ALTERNATIF TANPA INSTALL APLIKASI (WEB REMOTE):")
    print("  --------------------------------------------------------------")
    print(f"  Buka browser HP ke: http://{primary_ip}:{TCP_PORT}")
    print("  Atau SCAN QR CODE DI BAWAH dengan kamera HP Anda:")
    print()

    # Cetak QR Code di terminal
    try:
        qr = qrcode.QRCode(box_size=1, border=1)
        qr.add_data(f"http://{primary_ip}:{TCP_PORT}")
        qr.make(fit=True)
        f = io.StringIO()
        qr.print_ascii(out=f, invert=True)
        print(f.getvalue())
    except Exception:
        pass

    print("-" * 64)
    print("  Fitur Remote : Numpad | Media | Presentasi | Trackpad | Teks")
    print("  Tekan Ctrl + C di jendela ini untuk mematikan server.")
    print("=" * 64)
    print()


if __name__ == "__main__":
    # Jalankan thread UDP Broadcaster untuk discovery aplikasi Flutter
    threading.Thread(target=udp_broadcaster, daemon=True).start()

    # Jalankan background greenlet dispatcher untuk sinkronisasi state media
    socketio.start_background_task(media_event_dispatcher)

    primary_ip = get_primary_ip()
    all_ips = get_all_local_ips()
    print_banner(primary_ip, all_ips)

    # Jalankan server Socket.IO + Flask
    socketio.run(app, host="0.0.0.0", port=TCP_PORT)

