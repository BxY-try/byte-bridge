# 🌉 ByteBridge — Wireless PC Controller via WiFi

**ByteBridge** adalah aplikasi pengontrol PC nirkabel multifungsi melalui jaringan WiFi lokal. Ubah smartphone Anda (Android / iOS / Tablet) menjadi kontroler PC serbaguna tanpa kabel:

- 🔢 **Remote Numpad**: Numpad lengkap untuk laptop tanpa numpad fisik.
- 🎵 **Media Controller**: Kontrol pemutar musik/video dan volume speaker PC dari jarak jauh.
- 🎯 **Presenter & Navigasi**: Tombol D-Pad arah, Page Up/Down, F5 slideshow untuk presentasi PowerPoint/Canva.
- 🖱️ **Trackpad / Mouse**: Kontrol kursor mouse, klik kiri, dan klik kanan langsung dari layar sentuh HP.
- ⚡ **Pintasan & Teks (Shortcuts)**: Copy, Paste, Undo, Redo, Win+D (Desktop), Alt+Tab, Screenshot, dan kolom kirim teks langsung.

---

## 🚀 Cara Pakai Paling Cepat (0 Instalasi di HP!)

Anda **tidak wajib menginstall aplikasi APK apa pun di HP**. Server ByteBridge sudah dilengkapi **Web App (PWA)** bawaan yang responsif dan berdesain modern!

### 1. Jalankan Server di PC (Windows)
Cukup **double-click file `run.bat`** di folder utama proyek ini:
```cmd
run.bat
```
*(Script ini otomatis mengecek Python, membuat virtual environment, menginstall pustaka yang dibutuhkan, dan menyalakan server).*

### 2. Hubungkan HP ke PC
1. Pastikan **HP dan PC terhubung ke WiFi atau Hotspot yang SAMA**.
2. Di terminal PC, akan tampil **QR Code** dan alamat IP, contohnya:
   ```text
   👉 http://192.168.1.10:8080
   ```
3. **Arahkan kamera HP ke QR Code** atau buka URL tersebut di browser HP (Chrome / Safari).
4. *(Opsional)* Di browser HP, tap menu titik tiga lalu pilih **"Tambahkan ke Layar Utama" (Add to Home Screen)** agar ByteBridge terpasang seperti aplikasi native tanpa address bar browser!
5. **Selesai!** Tekan tombol di HP, dan input langsung dieksekusi di PC secara real-time.

---

## 🎮 Fitur Kontroler

| Mode | Deskripsi & Fungsi |
| :--- | :--- |
| **🔢 Numpad** | Angka `0`-`9`, operator `+`, `-`, `*`, `/`, `Enter`, `Backspace`, `Tab`, `ESC`, dan titik `.`. Sangat cocok untuk input data Excel, kalkulator, atau game. |
| **🎵 Media** | Tombol Volume PC (`Naik`, `Turun`, `Mute`) serta kontrol musik (`Play/Pause`, `Next Track`, `Prev Track`) untuk Spotify, YouTube, VLC, dll. |
| **🎯 Navigasi** | Tombol arah panah (`▲`, `▼`, `◀`, `▶`), `OK (Enter)`, `Page Up`, `Page Down`, serta shortcut presentasi `F5`, `Shift+F5`, `ESC`, `Space`. |
| **🖱️ Trackpad** | Area sentuh sensitif untuk menggerakkan kursor mouse PC. Ketuk layar untuk Klik Kiri, dan tersedia tombol fisik Klik Kiri & Kanan. |
| **⚡ Pintasan** | Tombol cepat: `Ctrl+C`, `Ctrl+V`, `Ctrl+Z`, `Ctrl+Y`, `Ctrl+S`, `Ctrl+A`, `Win+D` (Show Desktop), `Alt+Tab`, `Win+Shift+S` (Screenshot). |
| **📝 Kirim Teks** | Ketik kalimat panjang atau tempelkan link di HP, klik **Kirim Teks ke PC**, maka teks otomatis terketik di jendela PC yang aktif. |

---

## 📱 Opsi 2: Menggunakan Aplikasi Flutter Native (Android)

Jika Anda ingin mengompilasi aplikasi Android native (`.apk`):

### Cara A: Otomatis via GitHub Actions (Rekomendasi tanpa install Android Studio di PC)
Proyek ini sudah dilengkapi file CI workflow di `.github/workflows/build-apk.yml`.
1. Push repositori ini ke akun GitHub Anda.
2. Buka tab **Actions** di GitHub repository Anda.
3. Download file `ByteBridge-Release-APK` yang otomatis selesai di-build oleh GitHub Cloud ke HP Anda.

### Cara B: Build Lokal dengan Flutter SDK
1. Masuk ke folder `flutter_app`:
   ```bash
   cd flutter_app
   flutter pub get
   ```
2. Hubungkan HP via USB Debugging, lalu jalankan:
   ```bash
   flutter run
   ```
3. Atau kompilasi file APK:
   ```bash
   flutter build apk --release
   ```

Aplikasi Flutter ini memiliki fitur **UDP Auto-Discovery**: begitu dibuka di HP, aplikasi akan mendengarkan sinyal broadcast dari PC di port UDP `37020` dan terhubung otomatis tanpa Anda perlu mengetik IP.

---

## 📁 Struktur Direktori Proyek

```text
byte-bridge/
├── run.bat                          # Launcher 1-klik untuk PC Windows
├── README.md                        # Panduan lengkap proyek
├── .gitignore                       # Filter git untuk Python dan Flutter
├── .github/
│   └── workflows/
│       └── build-apk.yml            # Otomasi build APK di GitHub Actions
├── server/                          # Program Backend PC (Python)
│   ├── server.py                    # Server Flask-SocketIO + PyAutoGUI + UDP Broadcast
│   ├── requirements.txt             # Dependensi Python
│   ├── run.bat                      # Shortcut launcher dari folder server
│   ├── templates/
│   │   └── index.html               # Antarmuka Web App / PWA kontroler
│   └── static/
│       ├── icon.svg                 # Ikon ByteBridge
│       └── manifest.json            # Konfigurasi PWA (Add to Home Screen)
└── flutter_app/                     # Aplikasi Mobile Native (Flutter)
    ├── pubspec.yaml                 # Dependensi Flutter
    ├── lib/
    │   ├── main.dart                # Tampilan UI Flutter (Numpad, Media, Nav, Pintasan)
    │   ├── discovery_service.dart   # Listener UDP broadcast auto-discovery
    │   └── socket_service.dart      # Klien Socket.IO real-time
    └── android/                     # Konfigurasi project Android & gradle
```

---

## 💡 Tips & Troubleshooting

1. **Tombol ditekan tapi tidak ada respon di PC?**
   - Pastikan aplikasi yang ingin Anda ketik (misal: Notepad, Excel, Word, atau Browser) sedang dalam keadaan **fokus / aktif** di PC. `pyautogui` mengirimkan penekanan tombol ke jendela yang sedang aktif.
2. **Kamera HP tidak bisa membuka alamat IP?**
   - Pastikan HP dan PC terhubung ke WiFi atau SSID yang sama (atau HP terhubung ke Mobile Hotspot PC).
   - Pastikan Firewall Windows mengizinkan Python (`Allow Access` pada prompt Firewall saat pertama kali dijalankan).
3. **WiFi Kantor / Kampus Memblokir Koneksi Antar Perangkat?**
   - Beberapa jaringan publik mengaktifkan fitur *Client Isolation* (perangkat tidak boleh saling komunikasi).
   - Solusi mudah: Nyalakan **Hotspot** dari HP, lalu hubungkan PC ke Hotspot HP tersebut (atau sebaliknya nyalakan Mobile Hotspot dari Windows).
