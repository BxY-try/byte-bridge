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
    "gemini-3.7-flash",
    "gemini-3.6-flash",
    "gemini-3.5-flash",
    "gemini-3.5-flash-lite",
    "gemini-flash-latest",
    "gemini-2.5-flash"
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
            "model": "gemini-3.7-flash",
            "prompt_template": "Tolong jawab, selesaikan, atau jelaskan persoalan ini dengan tepat, padat, terstruktur, dan to the point. Gunakan format teks biasa yang mudah dibaca. Gunakan heading (#) atau bold (**) hanya jika benar-benar membantu, jangan di setiap baris. Untuk rumus matematika, tulis dalam bentuk teks biasa (misal: x^2 + 3x = 0)."
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
        preferred_model = self.config.get("model", "gemini-3.7-flash")
        candidate_models = [preferred_model] + [m for m in DEFAULT_MODELS if m != preferred_model]

        for model_name in candidate_models:
            try:
                gen_config = self._get_thinking_config(model_name)
                response = self._client.models.generate_content(
                    model=model_name,
                    contents=prompt,
                    config=gen_config
                )

                # Ambil teks jawaban bersih (hanya teks non-thought)
                answer_text = ""
                if response and hasattr(response, "candidates") and response.candidates:
                    parts = getattr(response.candidates[0].content, "parts", [])
                    answer_parts = [
                        p.text for p in parts
                        if getattr(p, "text", None) and not getattr(p, "thought", False)
                    ]
                    if answer_parts:
                        answer_text = "".join(answer_parts).strip()

                if not answer_text and response and getattr(response, "text", None):
                    answer_text = response.text.strip()

                if answer_text:
                    return {
                        "success": True,
                        "answer": answer_text,
                        "model": model_name
                    }
            except Exception as err:
                last_err = str(err)
                print(f"[AIService] Model {model_name} mengalami kendala: {err}. Langsung fallback ke model berikutnya...")

        return {
            "success": False,
            "error": f"Semua model Gemini gagal merespons. Error terakhir: {last_err}"
        }

    def _get_thinking_config(self, model_name: str) -> Optional[Any]:
        """
        Mendapatkan GenerateContentConfig dengan konfigurasi thinking yang tepat
        sesuai standar arsitektur Google Gemini (per 2026):
        - Gemini 3.x series (3.8, 3.7, 3.6, 3.5, 3.5-lite, flash-latest):
          Thinking AKTIF dengan thinking_level="HIGH" tanpa menyertakan raw thoughts (include_thoughts=False).
        - Gemini 2.5 series (legacy):
          Thinking AKTIF dengan thinking_budget=-1 (dinamis) tanpa menyertakan thoughts.
        - Model lain / non-thinking (misal Gemini 1.5/2.0):
          Hanya GenerateContentConfig dasar tanpa thinking_config.

        ========================================================================================
        PENTING - JANGAN DIHAPUS SAAT REFACTOR:
        Semua GenerateContentConfig di bawah WAJIB menyertakan:
            automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True)
        
        Alasan:
        Pada SDK resmi google-genai, jika `config` bernilai None atau AFC tidak di-disable
        secara eksplisit, SDK menganggap AFC (Automatic Function Calling) aktif secara default.
        Ketika dipanggil via `client.models.generate_content()`, SDK akan mengeluarkan warning:
            "Direct use of automatic function calling (AFC) in Models.generate_content is not recommended.
             Instead, we recommend to use AFC in Chat.send_message..."
        Dengan menyertakan `disable=True`, warning ini dicegah langsung dari konfigurasi SDK tanpa
        perlu mematikan logger secara membabi buta.
        ========================================================================================
        """
        if not _genai_available:
            return None

        afc_config = types.AutomaticFunctionCallingConfig(disable=True)
        m = model_name.lower()
        if any(v in m for v in ["gemini-3", "flash-latest"]):
            return types.GenerateContentConfig(
                thinking_config=types.ThinkingConfig(
                    thinking_level="HIGH",
                    include_thoughts=False
                ),
                automatic_function_calling=afc_config
            )
        elif "gemini-2.5" in m:
            return types.GenerateContentConfig(
                thinking_config=types.ThinkingConfig(
                    thinking_budget=-1,
                    include_thoughts=False
                ),
                automatic_function_calling=afc_config
            )
        return types.GenerateContentConfig(
            automatic_function_calling=afc_config
        )

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
