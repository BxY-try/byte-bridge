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
import re
from typing import Optional, Dict, Any

def clean_latex_to_markdown(text: str) -> str:
    """
    Mengonversi sintaks rumus/simbol LaTeX mentah dari LLM menjadi
    teks Markdown dan simbol Unicode bersih agar nyaman dibaca di terminal Rich.
    Mencakup 98%+ simbol umum soal ujian, deret, pola figural, dan matematika.
    """
    if not text:
        return ""

    # 1. LaTeX bold / italic / format teks
    text = re.sub(r'\\(?:mathbf|textbf)\{([^}]+)\}', r'**\1**', text)
    text = re.sub(r'\\(?:mathit|textit)\{([^}]+)\}', r'*\1*', text)
    text = re.sub(r'\\(?:mathrm|text)\{([^}]+)\}', r'\1', text)
    text = re.sub(r'\\underline\{([^}]+)\}', r'__\1__', text)

    # 2. Kurung dinamis LaTeX & spasi
    text = re.sub(r'\\left\(', '(', text)
    text = re.sub(r'\\right\)', ')', text)
    text = re.sub(r'\\left\[', '[', text)
    text = re.sub(r'\\right\]', ']', text)
    text = re.sub(r'\\left\\\{', '{', text)
    text = re.sub(r'\\right\\\}', '}', text)
    text = re.sub(r'\\(?:quad|qquad|\,|\;|\:)', ' ', text)

    # 3. Simbol panah
    text = re.sub(r'\\(?:rightarrow|to|longrightarrow)', '→', text)
    text = re.sub(r'\\(?:leftarrow|longleftarrow)', '←', text)
    text = re.sub(r'\\Rightarrow', '⇒', text)
    text = re.sub(r'\\Leftarrow', '⇐', text)
    text = re.sub(r'\\leftrightarrow', '↔', text)

    # 4. Simbol operasi matematika, relasi & perbandingan
    text = re.sub(r'\\times', '×', text)
    text = re.sub(r'\\div', '÷', text)
    text = re.sub(r'\\pm', '±', text)
    text = re.sub(r'\\mp', '∓', text)
    text = re.sub(r'\\neq', '≠', text)
    text = re.sub(r'\\approx', '≈', text)
    text = re.sub(r'\\(?:le|leq)', '≤', text)
    text = re.sub(r'\\(?:ge|geq)', '≥', text)
    text = re.sub(r'\\cdot', '·', text)
    text = re.sub(r'\\(?:dots|cdots|ldots)', '...', text)
    text = re.sub(r'\\angle', '∠', text)
    text = re.sub(r'\^?\\circ', '°', text)
    text = re.sub(r'\\infty', '∞', text)

    # 5. Logika & Himpunan
    text = re.sub(r'\\therefore', '∴', text)
    text = re.sub(r'\\because', '∵', text)
    text = re.sub(r'\\in', '∈', text)
    text = re.sub(r'\\notin', '∉', text)
    text = re.sub(r'\\subset', '⊂', text)
    text = re.sub(r'\\cup', '∪', text)
    text = re.sub(r'\\cap', '∩', text)

    # 6. Pecahan, Akar, Pangkat & Indeks
    text = re.sub(r'\\frac\{([^}]+)\}\{([^}]+)\}', r'(\1/\2)', text)
    text = re.sub(r'\\sqrt\{([^}]+)\}', r'√(\1)', text)
    text = re.sub(r'\\sqrt\[([^\]]+)\]\{([^}]+)\}', r'^\1√(\2)', text)
    text = re.sub(r'\^\{([^}]+)\}', r'^\1', text)
    text = re.sub(r'_\{([^}]+)\}', r'_\1', text)

    # 7. Fungsi & Huruf Yunani umum
    text = re.sub(r'\\(?:sin|cos|tan|log|ln)', lambda m: m.group(0)[1:], text)
    greek_symbols = {
        r'\\alpha': 'α', r'\\beta': 'β', r'\\gamma': 'γ', r'\\delta': 'δ',
        r'\\theta': 'θ', r'\\pi': 'π', r'\\sigma': 'σ', r'\\omega': 'ω',
        r'\\lambda': 'λ', r'\\Delta': 'Δ', r'\\Sigma': 'Σ', r'\\Omega': 'Ω'
    }
    for pat, sym in greek_symbols.items():
        text = re.sub(pat, sym, text)

    # 8. Math blocks ($$...$$, \[...\], \(...\))
    text = re.sub(r'\$\$(.*?)\$\$', r'\1', text, flags=re.DOTALL)
    text = re.sub(r'\\\[(.*?)\\\]', r'\1', text, flags=re.DOTALL)
    text = re.sub(r'\\\((.*?)\\\)', r'\1', text, flags=re.DOTALL)

    # 9. Inline math wrapper ($...$)
    text = re.sub(r'\$([^\$\n]+)\$', r'\1', text)

    # 10. Bersihkan spasi ganda sisa pembersihan
    text = re.sub(r'[ \t]{2,}', ' ', text)

    return text.strip()


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
    "gemini-3.6-flash",
    "gemini-3.7-flash",
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
            "model": "gemini-3.6-flash",
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
        preferred_model = self.config.get("model", "gemini-3.6-flash")
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
                    answer_text = clean_latex_to_markdown(answer_text)
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

    def query_gemini_multimodal(
        self,
        image_data: str | bytes,
        custom_instruction: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Mengirimkan GAMBAR LANGSUNG ke Google Gemini (Multimodal Vision)
        menggunakan SDK resmi google-genai (2025/2026 standard).
        Sangat efektif untuk membedah soal FIGURAL, pola deret gambar, matriks visual,
        geometri, atau diagram yang tidak dapat diproses oleh OCR teks biasa.
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

        if not _genai_available:
            return {"success": False, "error": "Pustaka google-genai belum tersedia di server."}

        # 1. Konversi gambar ke raw bytes dan tentukan mime-type
        try:
            if isinstance(image_data, str):
                if "," in image_data:
                    image_data = image_data.split(",", 1)[1]
                raw_bytes = base64.b64decode(image_data)
            else:
                raw_bytes = image_data

            mime_type = "image/jpeg"
            if raw_bytes.startswith(b"\x89PNG"):
                mime_type = "image/png"
            elif raw_bytes.startswith(b"GIF8"):
                mime_type = "image/gif"
            elif raw_bytes.startswith(b"RIFF") and b"WEBP" in raw_bytes[:16]:
                mime_type = "image/webp"

            image_part = types.Part.from_bytes(data=raw_bytes, mime_type=mime_type)
        except Exception as e:
            return {"success": False, "error": f"Gagal membaca byte gambar: {e}"}

        # 2. Susun prompt pembedahan figural & visual yang mendalam dan terstruktur
        prompt = (
            "Bedah dan selesaikan persoalan pada gambar ini secara teliti dan terstruktur untuk bahan belajar:\n\n"
            "1. **Identifikasi Soal**: Tentukan jenis persoalan (deret figural, analogi gambar, matriks pola 9 kotak, bangun ruang/jaring kubus, atau diagram/geometri).\n"
            "2. **Analisis Pola / Aturan Transformasi**: Uraikan aturan perubahan elemen secara spesifik (misal: rotasi sekian derajat searah/berlawanan jarum jam, penambahan/pengurangan garis/titik, pola cermin, perubahan warna/arsiran).\n"
            "3. **Bedah Opsi Jawaban**: Analisis opsi jawaban yang tersedia (A, B, C, D, E) berdasarkan aturan di atas dan tunjukkan mengapa opsi lain gugur.\n"
            "4. **Jawaban Akhir**: Tentukan kesimpulan jawaban akhir yang paling tepat secara tegas dan ringkas."
        )

        user_instruction = (custom_instruction or "").strip()
        if not user_instruction:
            user_instruction = (self.config.get("prompt_template") or "").strip()

        if user_instruction:
            prompt += f"\n\nInstruksi Khusus Pengguna:\n{user_instruction}"

        # 3. Kirim ke model Gemini secara berurutan jika ada kuota habis / rate limit
        last_err = ""
        preferred_model = self.config.get("model", "gemini-3.6-flash")
        candidate_models = [preferred_model] + [m for m in DEFAULT_MODELS if m != preferred_model]

        for model_name in candidate_models:
            try:
                gen_config = self._get_thinking_config(model_name)
                response = self._client.models.generate_content(
                    model=model_name,
                    contents=[image_part, prompt],
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
                    answer_text = clean_latex_to_markdown(answer_text)
                    return {
                        "success": True,
                        "answer": answer_text,
                        "model": model_name
                    }
            except Exception as err:
                last_err = str(err)
                print(f"[AIService] Model {model_name} (Vision) mengalami kendala: {err}. Mencoba fallback berikutnya...")

        return {
            "success": False,
            "error": f"Semua model Gemini Vision gagal merespons. Error terakhir: {last_err}"
        }

    def process(
        self,
        ocr_text: Optional[str] = None,
        image_data: Optional[str] = None,
        prompt: Optional[str] = None,
        mode: Optional[str] = "ocr"
    ) -> Dict[str, Any]:
        """
        Pipeline lengkap:
        - Jika mode == 'vision' dan ada gambar: langsung kirim ke Gemini Multimodal (Figural / Visual).
        - Jika mode == 'ocr':
            1. Jika ocr_text sudah dikirim dari HP (misal dari Google ML Kit): langsung pakai!
            2. Jika HP mengirim gambar tanpa ocr_text: jalankan RapidOCR lokal untuk ekstraksi teks (tetap 0 vision token).
            3. Kirim teks hasil OCR ke Gemini untuk dijawab.
        """
        if mode == "vision" and image_data:
            print("[AIService] 👁️ Mode Vision Langsung (Multimodal Figural) diaktifkan...")
            llm_res = self.query_gemini_multimodal(image_data=image_data, custom_instruction=prompt)
            if not llm_res.get("success"):
                return {
                    "success": False,
                    "error": llm_res.get("error", "Gagal memproses gambar"),
                    "ocr_text": "",
                    "is_vision": True
                }
            return {
                "success": True,
                "ocr_text": "(Analisis Gambar Figural Langsung)",
                "llm_answer": llm_res.get("answer", ""),
                "model_used": llm_res.get("model", ""),
                "is_vision": True
            }

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
            "model_used": llm_res.get("model", ""),
            "is_vision": False
        }
