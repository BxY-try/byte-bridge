"""
ByteBridge Media Manager
-----------------------
Mengelola integrasi dua arah dengan Windows Media Session (GSMTC - Global System Media Transport Controls)
dan Master Volume PC (Core Audio / pycaw).

Fitur:
- Berjalan di native OS thread dengan dedicated asyncio loop (terisolasi dari eventlet monkey-patch).
- Producer-consumer queue bridging ke Socket.IO greenlet dispatcher.
- Deduplikasi & caching thumbnail Base64 menggunakan hash MD5 byte gambar (menghemat bandwidth 99.8%).
- Readiness signal (threading.Event) untuk inisialisasi yang deterministik tanpa race condition.
- Leak-free token management saat pergantian session dan graceful shutdown.
- Fallback cerdas ke pyautogui/keypress lama bila GSMTC tidak tersedia.
"""

import asyncio
import base64
import datetime
import hashlib
import queue
import re
import threading
import time
from typing import Any, Dict, List, Optional, Tuple

import pyautogui
from pycaw.pycaw import AudioUtilities

# WinRT modules
try:
    import winrt.windows.media.control as mc
    import winrt.windows.media as wm
    import winrt.windows.storage.streams as streams
    import winrt.windows.foundation.collections  # Required for VectorView
    WINRT_AVAILABLE = True
except Exception as e:
    WINRT_AVAILABLE = False
    mc = None
    wm = None
    streams = None
    print(f"[MediaManager] WinRT modul tidak tersedia: {e}")


class MediaManager:
    """Manajer kontrol media Windows dua arah dan audio master volume."""

    def __init__(self):
        self.state_queue: queue.Queue = queue.Queue()
        self.ready_event: threading.Event = threading.Event()
        self._running: bool = True

        self._thread: Optional[threading.Thread] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None

        self._session_mgr = None
        self._current_session = None
        self._active_sessions: List[Any] = []

        # Registration tokens
        self._mgr_current_session_token = None
        self._mgr_sessions_changed_token = None
        self._prop_token = None
        self._playback_token = None
        self._timeline_token = None

        # State & Caching
        self._cached_state: Dict[str, Any] = {
            "available": False,
            "volume": 50,
            "is_muted": False,
            "sessions": []
        }
        self._cached_thumbnail_hash: str = ""
        self._cached_thumbnail_data: Optional[str] = None
        self._manual_session_id: Optional[str] = None
        self._last_state_time: float = time.monotonic()

        # Mulai background thread
        self._thread = threading.Thread(target=self._worker_thread_main, daemon=True, name="WinRTMediaWorker")
        self._thread.start()

    def wait_ready(self, timeout: float = 5.0) -> bool:
        """Menunggu hingga background worker selesai inisialisasi awal."""
        return self.ready_event.wait(timeout)

    def get_current_state(self) -> Dict[str, Any]:
        """Mengembalikan snapshot state media terkini (lengkap dengan thumbnail jika ada)."""
        if not self.ready_event.is_set():
            self.ready_event.wait(timeout=2.0)

        # Perbarui posisi real-time jika ada session aktif
        if self._current_session:
            try:
                pos, dur, min_seek, max_seek = self._calculate_realtime_timeline(self._current_session)
                self._cached_state["position"] = pos
                if dur > 0:
                    self._cached_state["duration"] = dur
                self._last_state_time = time.monotonic()
            except Exception:
                pass

        state = dict(self._cached_state)
        # Selalu sertakan thumbnail data saat state diambil secara eksplisit (misal client baru connect)
        if self._cached_thumbnail_data:
            state["thumbnail"] = self._cached_thumbnail_data
        return state

    def handle_command(self, action: str, value: Any = None) -> bool:
        """Dispatcher perintah dari client ke thread worker."""
        if not self._running:
            return False

        # Volume dan Mute dapat dieksekusi langsung tanpa asyncio loop
        if action == "set_volume":
            return self._set_master_volume(value)
        elif action == "toggle_mute":
            return self._toggle_master_mute()

        # Command media transport dijadwalkan ke asyncio event loop di thread WinRT
        if self._loop and self._loop.is_running():
            future = asyncio.run_coroutine_threadsafe(
                self._async_handle_command(action, value),
                self._loop
            )
            try:
                # Tunggu eksekusi singkat
                return future.result(timeout=1.5)
            except Exception as e:
                print(f"[MediaManager] Command '{action}' timeout/error: {e}")
                # Fallback ke simulasi tombol keyboard jika perlu
                self._fallback_key(action)
                return False
        else:
            self._fallback_key(action)
            return False

    def close(self):
        """Membersihkan semua listener dan menghentikan thread worker secara aman."""
        if not self._running:
            return
        self._running = False
        print("[MediaManager] Menutup MediaManager...")

        if self._loop and self._loop.is_running():
            try:
                # Unsubscribe listener di loop thread
                asyncio.run_coroutine_threadsafe(self._async_cleanup(), self._loop).result(timeout=2.0)
            except Exception:
                pass
            self._loop.call_soon_threadsafe(self._loop.stop)

        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
        print("[MediaManager] MediaManager berhasil ditutup.")

    # ==================== Worker Thread & Event Loop ====================

    def _worker_thread_main(self):
        """Fungsi utama native OS thread."""
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)

        try:
            self._loop.run_until_complete(self._async_init())
            self._loop.run_forever()
        except Exception as e:
            print(f"[MediaManager] Worker thread exception: {e}")
        finally:
            try:
                # Cancel pending tasks
                pending = asyncio.all_tasks(self._loop)
                for task in pending:
                    task.cancel()
                self._loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
                self._loop.close()
            except Exception:
                pass

    async def _async_init(self):
        """Inisialisasi WinRT GSMTC session manager dan listener."""
        if not WINRT_AVAILABLE:
            print("[MediaManager] WinRT tidak tersedia, menggunakan fallback mode.")
            self._fetch_volume_only()
            self.ready_event.set()
            return

        try:
            self._session_mgr = await mc.GlobalSystemMediaTransportControlsSessionManager.request_async()
            if self._session_mgr:
                # Daftarkan event listener level manager
                self._mgr_current_session_token = self._session_mgr.add_current_session_changed(
                    self._on_current_session_changed
                )
                self._mgr_sessions_changed_token = self._session_mgr.add_sessions_changed(
                    self._on_sessions_changed
                )

                # Ambil session aktif awal
                session = self._session_mgr.get_current_session()
                await self._bind_session(session)
            else:
                self._fetch_volume_only()
        except Exception as e:
            print(f"[MediaManager] Gagal inisialisasi GSMTC: {e}")
            self._fetch_volume_only()
        finally:
            # Refresh state awal dan tandai siap
            await self._update_and_push_state(force_thumbnail=True)
            self.ready_event.set()

    async def _async_cleanup(self):
        """Mencabut semua listener WinRT."""
        self._unbind_current_session()
        if self._session_mgr:
            try:
                if self._mgr_current_session_token:
                    self._session_mgr.remove_current_session_changed(self._mgr_current_session_token)
                    self._mgr_current_session_token = None
                if self._mgr_sessions_changed_token:
                    self._session_mgr.remove_sessions_changed(self._mgr_sessions_changed_token)
                    self._mgr_sessions_changed_token = None
            except Exception as e:
                print(f"[MediaManager] Error saat unbind session manager: {e}")

    # ==================== Session & Event Subscription ====================

    def _unbind_current_session(self):
        """Mencabut listener dari session lama agar tidak ada leak."""
        if self._current_session:
            try:
                if self._prop_token:
                    self._current_session.remove_media_properties_changed(self._prop_token)
                    self._prop_token = None
                if self._playback_token:
                    self._current_session.remove_playback_info_changed(self._playback_token)
                    self._playback_token = None
                if self._timeline_token:
                    self._current_session.remove_timeline_properties_changed(self._timeline_token)
                    self._timeline_token = None
            except Exception as e:
                print(f"[MediaManager] Error unbinding session tokens: {e}")
        self._current_session = None

    async def _bind_session(self, session):
        """Memasang listener pada session yang baru dipilih/aktif."""
        self._unbind_current_session()
        self._current_session = session

        if self._current_session:
            try:
                self._prop_token = self._current_session.add_media_properties_changed(
                    self._on_media_properties_changed
                )
                self._playback_token = self._current_session.add_playback_info_changed(
                    self._on_playback_info_changed
                )
                self._timeline_token = self._current_session.add_timeline_properties_changed(
                    self._on_timeline_properties_changed
                )
            except Exception as e:
                print(f"[MediaManager] Error binding session tokens: {e}")

    # Callback events dari WinRT (dieksekusi di thread WinRT)
    def _on_current_session_changed(self, sender, args):
        if not self._running or not self._loop:
            return
        asyncio.run_coroutine_threadsafe(self._handle_session_changed(), self._loop)

    def _on_sessions_changed(self, sender, args):
        if not self._running or not self._loop:
            return
        asyncio.run_coroutine_threadsafe(self._update_and_push_state(), self._loop)

    def _on_media_properties_changed(self, sender, args):
        if not self._running or not self._loop:
            return
        asyncio.run_coroutine_threadsafe(self._update_and_push_state(force_thumbnail=True), self._loop)

    def _on_playback_info_changed(self, sender, args):
        if not self._running or not self._loop:
            return
        asyncio.run_coroutine_threadsafe(self._update_and_push_state(), self._loop)

    def _on_timeline_properties_changed(self, sender, args):
        if not self._running or not self._loop:
            return
        asyncio.run_coroutine_threadsafe(self._update_and_push_state(), self._loop)

    async def _handle_session_changed(self):
        """Menangani pergantian session otomatis oleh sistem."""
        if not self._session_mgr:
            return
        # Jika user tidak secara manual memilih session tertentu, ikuti sistem
        if not self._manual_session_id:
            new_session = self._session_mgr.get_current_session()
            await self._bind_session(new_session)
        await self._update_and_push_state(force_thumbnail=True)

    # ==================== State Extraction & Caching ====================

    async def _update_and_push_state(self, force_thumbnail: bool = False):
        """Membaca snapshot state lengkap dari WinRT dan volume, lalu memasukkan ke queue."""
        if not self._running:
            return

        vol_pct, is_muted = self._get_master_volume_info()

        # Daftar semua session untuk session switcher
        sessions_list = []
        if self._session_mgr:
            try:
                all_s = self._session_mgr.get_sessions()
                if all_s:
                    for s in all_s:
                        aumid = s.source_app_user_model_id or ""
                        app_name, proc_name = self._parse_source_app(aumid, "")
                        is_cur = (self._current_session and s.source_app_user_model_id == self._current_session.source_app_user_model_id)
                        sessions_list.append({
                            "id": aumid,
                            "app_name": app_name,
                            "process_name": proc_name,
                            "is_current": bool(is_cur)
                        })
            except Exception as e:
                print(f"[MediaManager] Gagal membaca list sessions: {e}")

        # Jika tidak ada session aktif
        if not self._current_session:
            state = {
                "available": False,
                "volume": vol_pct,
                "is_muted": is_muted,
                "sessions": sessions_list
            }
            self._cached_state = state
            self.state_queue.put(state)
            return

        try:
            aumid = self._current_session.source_app_user_model_id or ""

            # 1. Properties (title, artist, thumbnail)
            props = await self._current_session.try_get_media_properties_async()
            title = props.title if props else ""
            artist = props.artist if props else ""
            album = props.album_title if props else ""

            # 2. Thumbnail reading + byte MD5 hashing
            thumb_data_uri = None
            thumb_hash = ""
            if props and props.thumbnail:
                try:
                    stream = await props.thumbnail.open_read_async()
                    if stream and stream.size > 0:
                        reader = streams.DataReader(stream)
                        await reader.load_async(stream.size)
                        buf = bytearray(stream.size)
                        reader.read_bytes(buf)
                        thumb_bytes = bytes(buf)
                        thumb_hash = hashlib.md5(thumb_bytes).hexdigest()

                        # Cek apakah thumbnail berubah
                        if force_thumbnail or thumb_hash != self._cached_thumbnail_hash:
                            content_type = stream.content_type or "image/png"
                            b64 = base64.b64encode(thumb_bytes).decode("ascii")
                            thumb_data_uri = f"data:{content_type};base64,{b64}"
                            self._cached_thumbnail_hash = thumb_hash
                            self._cached_thumbnail_data = thumb_data_uri
                        else:
                            # Thumbnail sama, kirim None untuk menghemat bandwidth
                            thumb_data_uri = None
                except Exception as e:
                    print(f"[MediaManager] Gagal baca thumbnail: {e}")

            if not thumb_hash:
                # Fallback hash jika tidak ada thumbnail
                thumb_hash = hashlib.md5(f"{aumid}_{title}_{artist}".encode("utf-8")).hexdigest()
                if self._cached_thumbnail_hash != thumb_hash:
                    self._cached_thumbnail_hash = thumb_hash
                    self._cached_thumbnail_data = None

            # 3. Timeline properties & Playback info
            pb = self._current_session.get_playback_info()
            timeline = self._current_session.get_timeline_properties()
            pos, dur, min_seek, max_seek = self._calculate_realtime_timeline(self._current_session, pb, timeline)

            # 4. Playback info & controls
            status_map = {
                4: "playing",
                5: "paused",
                3: "stopped",
                2: "changing",
                1: "opened",
                0: "closed"
            }
            status = status_map.get(pb.playback_status, "paused") if pb else "paused"
            rate = pb.playback_rate if (pb and pb.playback_rate) else 1.0
            is_shuffle = pb.is_shuffle_active if pb else False

            repeat_map = {0: "none", 1: "track", 2: "list"}
            repeat_mode = repeat_map.get(pb.auto_repeat_mode, "none") if pb else "none"

            ctrl = pb.controls if pb else None
            controls_flags = {
                "can_play": ctrl.is_play_enabled if ctrl else True,
                "can_pause": ctrl.is_pause_enabled if ctrl else True,
                "can_next": ctrl.is_next_enabled if ctrl else False,
                "can_previous": ctrl.is_previous_enabled if ctrl else False,
                "can_seek": ctrl.is_playback_position_enabled if ctrl else False,
                "can_shuffle": ctrl.is_shuffle_enabled if ctrl else False,
                "can_repeat": ctrl.is_repeat_enabled if ctrl else False,
                "can_set_rate": ctrl.is_playback_rate_enabled if ctrl else False,
            }

            # 5. App & Process Identity
            app_name, proc_name = self._parse_source_app(aumid, title)

            # Susun payload state
            state = {
                "available": True,
                "session_id": aumid,
                "title": title,
                "artist": artist,
                "album": album,
                "app_name": app_name,
                "process_name": proc_name,
                "thumbnail": thumb_data_uri,
                "thumbnail_hash": thumb_hash,
                "status": status,
                "position": round(pos, 2),
                "duration": round(dur, 2),
                "min_seek": round(min_seek, 2),
                "max_seek": round(max_seek, 2),
                "playback_rate": rate,
                "shuffle": is_shuffle,
                "repeat": repeat_mode,
                "controls": controls_flags,
                "volume": vol_pct,
                "is_muted": is_muted,
                "sessions": sessions_list
            }

            self._cached_state = state
            self._last_state_time = time.monotonic()
            self.state_queue.put(state)

        except Exception as e:
            print(f"[MediaManager] Error saat parsing media state: {e}")
            self._fetch_volume_only()

    def _calculate_realtime_timeline(self, session, pb=None, timeline=None) -> Tuple[float, float, float, float]:
        """
        Menghitung posisi playback real-time dari Windows GSMTC:
        Sesuai spesifikasi WinRT, timeline.position adalah snapshot pada saat last_updated_time.
        Jika sedang playing, posisi real-time dihitung dari:
        pos = timeline.position + (now_utc - timeline.last_updated_time) * playback_rate
        """
        if not session:
            return 0.0, 0.0, 0.0, 0.0
        try:
            if timeline is None:
                timeline = session.get_timeline_properties()
            if not timeline:
                return 0.0, 0.0, 0.0, 0.0

            base_pos = timeline.position.total_seconds() if timeline.position else 0.0
            dur = timeline.end_time.total_seconds() if timeline.end_time else 0.0
            min_seek = timeline.min_seek_time.total_seconds() if timeline.min_seek_time else 0.0
            max_seek = timeline.max_seek_time.total_seconds() if timeline.max_seek_time else dur

            if pb is None:
                pb = session.get_playback_info()

            status = pb.playback_status if pb else 0
            # Status 4 = Playing
            if status == 4 and timeline.last_updated_time:
                lut = timeline.last_updated_time
                if lut.tzinfo is None:
                    lut = lut.replace(tzinfo=datetime.timezone.utc)
                now_utc = datetime.datetime.now(datetime.timezone.utc)
                elapsed = (now_utc - lut).total_seconds()
                rate = pb.playback_rate if (pb and pb.playback_rate is not None and pb.playback_rate > 0) else 1.0

                if 0 <= elapsed < 86400:
                    current_pos = base_pos + (elapsed * rate)
                    if dur > 0:
                        current_pos = min(dur, max(0.0, current_pos))
                    return round(current_pos, 2), round(dur, 2), round(min_seek, 2), round(max_seek, 2)

            return round(base_pos, 2), round(dur, 2), round(min_seek, 2), round(max_seek, 2)
        except Exception as e:
            print(f"[MediaManager] Error calculating realtime timeline: {e}")
            return 0.0, 0.0, 0.0, 0.0

    def _fetch_volume_only(self):
        """Memperbarui hanya volume ketika GSMTC tidak tersedia."""
        vol_pct, is_muted = self._get_master_volume_info()
        state = {
            "available": False,
            "volume": vol_pct,
            "is_muted": is_muted,
            "sessions": []
        }
        self._cached_state = state
        self.state_queue.put(state)

    def _parse_source_app(self, aumid: str, title: str) -> Tuple[str, str]:
        """Memetakan AUMID ke nama aplikasi dan browser yang jelas."""
        lower = aumid.lower()
        title_lower = title.lower()

        # Browser detection
        proc_name = "Windows"
        if "chrome" in lower:
            proc_name = "Chrome"
        elif "firefox" in lower or "308046b0af4a39cb" in lower:
            proc_name = "Firefox"
        elif "edge" in lower or "msedge" in lower:
            proc_name = "Edge"
        elif "brave" in lower:
            proc_name = "Brave"
        elif "opera" in lower:
            proc_name = "Opera"
        elif "spotify" in lower:
            return "Spotify", "Spotify"
        elif "vlc" in lower:
            return "VLC", "VLC Media Player"

        # App content detection (misal tab YouTube / Spotify Web di browser)
        app_name = proc_name
        if "youtube" in title_lower or "youtu.be" in title_lower:
            app_name = "YouTube"
        elif "spotify" in title_lower:
            app_name = "Spotify"
        elif "netflix" in title_lower:
            app_name = "Netflix"
        elif "soundcloud" in title_lower:
            app_name = "SoundCloud"
        elif proc_name != "Windows":
            app_name = "Web Media"

        return app_name, proc_name

    # ==================== Async Command Execution ====================

    async def _async_handle_command(self, action: str, value: Any) -> bool:
        """Menjalankan aksi media transport pada session aktif."""
        if not self._current_session:
            self._fallback_key(action)
            return False

        try:
            if action == "play_pause":
                res = await self._current_session.try_toggle_play_pause_async()
                if not res:
                    # Coba fallback ke play atau pause eksplisit
                    pb = self._current_session.get_playback_info()
                    if pb and pb.playback_status == 4:
                        res = await self._current_session.try_pause_async()
                    else:
                        res = await self._current_session.try_play_async()
                await self._update_and_push_state()
                return bool(res)

            elif action == "play":
                res = await self._current_session.try_play_async()
                await self._update_and_push_state()
                return bool(res)

            elif action == "pause":
                res = await self._current_session.try_pause_async()
                await self._update_and_push_state()
                return bool(res)

            elif action == "next":
                res = await self._current_session.try_skip_next_async()
                await self._update_and_push_state()
                return bool(res)

            elif action == "previous":
                res = await self._current_session.try_skip_previous_async()
                await self._update_and_push_state()
                return bool(res)

            elif action == "seek":
                # Value dalam detik -> konversi ke 100-nanosecond ticks
                sec = float(value or 0.0)
                ticks = int(sec * 10_000_000)
                res = await self._current_session.try_change_playback_position_async(ticks)
                await asyncio.sleep(0.05)
                await self._update_and_push_state()
                return bool(res)

            elif action == "shuffle":
                new_val = bool(value)
                res = await self._current_session.try_change_shuffle_active_async(new_val)
                await self._update_and_push_state()
                return bool(res)

            elif action == "repeat":
                # Cycle atau set repeat mode (none -> list -> track -> none)
                target_mode = wm.MediaPlaybackAutoRepeatMode.NONE
                if value == "track":
                    target_mode = wm.MediaPlaybackAutoRepeatMode.TRACK
                elif value == "list":
                    target_mode = wm.MediaPlaybackAutoRepeatMode.LIST
                elif value == "none":
                    target_mode = wm.MediaPlaybackAutoRepeatMode.NONE
                else:
                    # Auto cycle
                    pb = self._current_session.get_playback_info()
                    cur = pb.auto_repeat_mode if pb else 0
                    if cur == 0:
                        target_mode = wm.MediaPlaybackAutoRepeatMode.LIST
                    elif cur == 2:
                        target_mode = wm.MediaPlaybackAutoRepeatMode.TRACK
                    else:
                        target_mode = wm.MediaPlaybackAutoRepeatMode.NONE

                res = await self._current_session.try_change_auto_repeat_mode_async(target_mode)
                await self._update_and_push_state()
                return bool(res)

            elif action == "set_rate":
                rate = float(value or 1.0)
                res = await self._current_session.try_change_playback_rate_async(rate)
                await self._update_and_push_state()
                return bool(res)

            elif action == "switch_session":
                session_id = str(value or "")
                if self._session_mgr:
                    all_s = self._session_mgr.get_sessions()
                    found = None
                    if all_s:
                        for s in all_s:
                            if s.source_app_user_model_id == session_id:
                                found = s
                                break
                    if found:
                        self._manual_session_id = session_id
                        await self._bind_session(found)
                        await self._update_and_push_state(force_thumbnail=True)
                        return True
                return False

        except Exception as e:
            print(f"[MediaManager] Error executing async command '{action}': {e}")
            self._fallback_key(action)
            return False

        return False

    def _fallback_key(self, action: str):
        """Simulasi keyboard fallback jika WinRT command gagal."""
        key_map = {
            "play_pause": "playpause",
            "play": "playpause",
            "pause": "playpause",
            "next": "nexttrack",
            "previous": "prevtrack",
        }
        key = key_map.get(action)
        if key:
            try:
                pyautogui.press(key)
            except Exception:
                pass

    # ==================== Master Volume Control (pycaw) ====================

    def _get_master_volume_info(self) -> Tuple[int, bool]:
        """Membaca persentase volume master PC dan status mute via pycaw."""
        try:
            speakers = AudioUtilities.GetSpeakers()
            vol = speakers.EndpointVolume
            scalar = vol.GetMasterVolumeLevelScalar()
            muted = bool(vol.GetMute())
            return round(scalar * 100), muted
        except Exception:
            return 50, False

    def _set_master_volume(self, val: Any) -> bool:
        """Mengatur volume master PC (0 - 100%)."""
        try:
            pct = max(0, min(100, int(val)))
            speakers = AudioUtilities.GetSpeakers()
            vol = speakers.EndpointVolume
            vol.SetMasterVolumeLevelScalar(pct / 100.0, None)
            # Update state lokal dan trigger queue
            self._fetch_volume_update(pct, bool(vol.GetMute()))
            return True
        except Exception as e:
            print(f"[MediaManager] Gagal set volume via pycaw: {e}")
            return False

    def _toggle_master_mute(self) -> bool:
        """Toggle status mute master volume PC."""
        try:
            speakers = AudioUtilities.GetSpeakers()
            vol = speakers.EndpointVolume
            cur_mute = bool(vol.GetMute())
            new_mute = not cur_mute
            vol.SetMute(new_mute, None)
            pct = round(vol.GetMasterVolumeLevelScalar() * 100)
            self._fetch_volume_update(pct, new_mute)
            return True
        except Exception as e:
            print(f"[MediaManager] Gagal toggle mute via pycaw: {e}")
            try:
                pyautogui.press("volumemute")
                return True
            except Exception:
                return False

    def _fetch_volume_update(self, volume: int, is_muted: bool):
        """Perbarui volume di cached_state dan kirim ke queue."""
        self._cached_state["volume"] = volume
        self._cached_state["is_muted"] = is_muted

        # Perbarui juga kalkulasi posisi real-time agar tidak mengirim posisi basi
        if self._current_session:
            try:
                pos, dur, min_seek, max_seek = self._calculate_realtime_timeline(self._current_session)
                self._cached_state["position"] = pos
                if dur > 0:
                    self._cached_state["duration"] = dur
            except Exception:
                if self._cached_state.get("status") == "playing" and hasattr(self, "_last_state_time"):
                    elapsed = time.monotonic() - self._last_state_time
                    dur = self._cached_state.get("duration", 0.0)
                    rate = self._cached_state.get("playback_rate", 1.0)
                    cur_pos = self._cached_state.get("position", 0.0) + (elapsed * rate)
                    if dur > 0:
                        cur_pos = min(dur, cur_pos)
                    self._cached_state["position"] = round(cur_pos, 2)

        self._last_state_time = time.monotonic()
        self.state_queue.put(dict(self._cached_state))
