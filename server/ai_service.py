"""
ByteBridge AI Service
---------------------
Menangani ekstraksi teks via OCR (lokal & offline tanpa boros token) 
dan meneruskan teks tersebut ke Google Gemini LLM menggunakan SDK google-genai terbaru (2025/2026).
"""

import os
import io
import json
import base64
from typing import Optional, Dict, Any

# Inisialisasi RapidOCR untuk ekstraksi teks lokal
try:
    from rapidocr_onnxruntime import RapidOCR
    _ocr_engine = RapidOCR()
except Exception as e:
    _ocr_engine = None
    print(f"[AIService] Warning: RapidOCR gagal dimuat ({e})")

# Inisialisasi SDK Google GenAI terbaru
try:
    from google import genai
    from google.genai import types
    _genai_available = True
except ImportError:
    _genai_available = False
    print("[AIService] Warning: google-genai belum terinstall")

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai_config.json")

# Model Gemini gratis & cepat versi terbaru (prioritas berurutan)
DEFAULT_MODELS = [
    "gemini-2.5-flash",
    "gemini-2.0-flash",
    "gemini-1.5-flash"
]


class AIService:
    def __init__(self):
        self.config = self._load_config()
        self._client: Optional[Any] = None
        self._init_client()

    def _load_config(self) -> Dict[str, Any]:
        """Memuat konfigurasi dari file atau environment variable."""
        cfg = {
            "gemini_api_key": os.environ.get("GEMINI_API_KEY", ""),
            "model": "gemini-2.5-flash",
            "prompt_template": "Tolong jawab, selesaikan, atau jelaskan persoalan ini dengan tepat, padat, terstruktur, dan to the point."
        }
        if os.path.exists(CONFIG_PATH):
            try:
                with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                    saved = json.load(f)
                    cfg.update(saved)
            except Exception as e:
                print(f"[AIService] Gagal membaca {CONFIG_PATH}: {e}")
        return cfg

    def save_config(self, new_cfg: Dict[str, Any]) -> bool:
        """Menyimpan konfigurasi baru ke ai_config.json."""
        try:
            self.config.update(new_cfg)
            with open(CONFIG_PATH, "w", encoding="utf-8") as f:
                json.dump(self.config, f, indent=2)
            self._init_client()
            return True
        except Exception as e:
            print(f"[AIService] Gagal menyimpan config: {e}")
            return False

    def _init_client(self):
        """Inisialisasi klien google-genai resmi dengan format client = genai.Client()."""
        api_key = self.config.get("gemini_api_key") or os.environ.get("GEMINI_API_KEY")
        if not api_key:
            self._client = None
            return
        if not _genai_available:
            print("[AIService] Pustaka google-genai belum tersedia!")
            self._client = None
            return

        try:
            self._client = genai.Client(api_key=api_key)
            print("[AIService] Google GenAI Client berhasil diinisialisasi.")
        except Exception as e:
            print(f"[AIService] Gagal inisialisasi GenAI client: {e}")
            self._client = None

    def extract_text_from_image(self, image_data: str | bytes) -> str:
        """
        Mengekstrak teks dari gambar secara lokal menggunakan RapidOCR.
        Tidak mengirimkan gambar ke LLM sehingga 100% hemat token dan cepat.
        """
        if _ocr_engine is None:
            return "[Error: Mesin OCR lokal belum tersedia di server]"

        try:
            # Jika input berupa base64 string
            if isinstance(image_data, str):
                if "," in image_data:
                    image_data = image_data.split(",", 1)[1]
                raw_bytes = base64.b64decode(image_data)
            else:
                raw_bytes = image_data

            result, _ = _ocr_engine(raw_bytes)
            if not result:
                return ""
            
            # Format teks hasil OCR
            lines = [line[1] for line in result if line and len(line) > 1]
            return "\n".join(lines).strip()
        except Exception as e:
            print(f"[AIService] Error saat ekstraksi OCR: {e}")
            return f"[Error OCR: {e}]"

    def query_gemini(self, text_content: str, custom_instruction: Optional[str] = None) -> Dict[str, Any]:
        """
        Mengirimkan HANYA TEKS HASIL OCR ke Gemini Developer API (Token hemat).
        Mencoba model flash terbaru (gemini-2.5-flash -> gemini-2.0-flash -> gemini-1.5-flash).
        """
        if not self._client:
            api_key = self.config.get("gemini_api_key")
            if not api_key:
                return {
                    "success": False,
                    "error": "GEMINI_API_KEY belum diset. Silakan masukkan API Key di server/ai_config.json atau via aplikasi HP."
                }
            self._init_client()
            if not self._client:
                return {"success": False, "error": "Inisialisasi GenAI client gagal."}

        instruction = custom_instruction or self.config.get("prompt_template", "")
        prompt = (
            f"Berikut adalah teks yang diekstrak dari layar monitor/buku/soal:\n"
            f"\"\"\"\n{text_content}\n\"\"\"\n\n"
            f"Instruksi:\n{instruction}"
        )

        # Coba model berurutan jika ada kuota habis / rate limit
        last_err = ""
        preferred_model = self.config.get("model", "gemini-2.5-flash")
        candidate_models = [preferred_model] + [m for m in DEFAULT_MODELS if m != preferred_model]

        for model_name in candidate_models:
            try:
                response = self._client.models.generate_content(
                    model=model_name,
                    contents=prompt
                )
                if response and response.text:
                    return {
                        "success": True,
                        "answer": response.text.strip(),
                        "model": model_name
                    }
            except Exception as err:
                last_err = str(err)
                print(f"[AIService] Model {model_name} gagal: {err}, mencoba model fallback berikutnya...")

        return {
            "success": False,
            "error": f"Semua model Gemini gagal merespons. Error terakhir: {last_err}"
        }

    def process(self, ocr_text: Optional[str] = None, image_data: Optional[str] = None, prompt: Optional[str] = None) -> Dict[str, Any]:
        """
        Pipeline lengkap:
        - Jika ocr_text sudah dikirim dari HP (misal dari Google ML Kit): langsung pakai!
        - Jika HP mengirim gambar: jalankan RapidOCR lokal untuk ekstraksi teks (tetap 0 vision token).
        - Kirim teks hasil OCR ke Gemini untuk dijawab.
        """
        final_ocr = (ocr_text or "").strip()

        # Jika teks OCR belum ada tapi ada gambar, ekstrak secara lokal
        if not final_ocr and image_data:
            print("[AIService] Memproses OCR lokal dari gambar...")
            final_ocr = self.extract_text_from_image(image_data)

        if not final_ocr:
            return {
                "success": False,
                "error": "Tidak ada teks yang berhasil dideteksi dari gambar.",
                "ocr_text": ""
            }

        print(f"[AIService] Teks OCR didapat ({len(final_ocr)} karakter). Mengirim ke Gemini...")
        llm_res = self.query_gemini(final_ocr, custom_instruction=prompt)

        if not llm_res.get("success"):
            return {
                "success": False,
                "error": llm_res.get("error", "Gagal mendapatkan respon dari AI"),
                "ocr_text": final_ocr
            }

        return {
            "success": True,
            "ocr_text": final_ocr,
            "llm_answer": llm_res.get("answer", ""),
            "model_used": llm_res.get("model", "")
        }
