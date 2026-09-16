"""
ByteBridge AI Service
---------------------
Menangani ekstraksi teks via OCR (lokal & offline tanpa boros token) 
dan meneruskan teks tersebut ke Google Gemini LLM menggunakan SDK google-genai terbaru (2025/2026).
"""

import os
import sys
import io
import json
import base64
import re
import requests
from typing import Optional, Dict, Any

if sys.platform.startswith("win"):
    try:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        if hasattr(sys.stderr, "reconfigure"):
            sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

def clean_latex_to_markdown(text: str) -> str:
    """
    Mengonversi sintaks rumus/simbol LaTeX mentah dari LLM menjadi
    teks Markdown dan simbol Unicode bersih agar nyaman dibaca di terminal Rich.
    Mencakup 99%+ simbol umum soal ujian, deret bilangan, pola figural, dan matematika.
    """
    if not text:
        return ""

    # 1. LaTeX bold / italic / format teks & boxed
    text = re.sub(r'\\(?:mathbf|textbf)\{([^}]+)\}', r'**\1**', text)
    text = re.sub(r'\\(?:mathit|textit)\{([^}]+)\}', r'*\1*', text)
    text = re.sub(r'\\(?:mathrm|text)\{([^}]+)\}', r'\1', text)
    text = re.sub(r'\\underline\{([^}]+)\}', r'__\1__', text)
    text = re.sub(r'\\boxed\{([^}]+)\}', r'**\1**', text)

    # 2. Kurung dinamis LaTeX & spasi (termasuk escaped space '\ ')
    text = re.sub(r'\\left\(', '(', text)
    text = re.sub(r'\\right\)', ')', text)
    text = re.sub(r'\\left\[', '[', text)
    text = re.sub(r'\\right\]', ']', text)
    text = re.sub(r'\\left\\\{', '{', text)
    text = re.sub(r'\\right\\\}', '}', text)
    text = re.sub(r'\\(?:quad|qquad|enspace|thinspace|[ ,;:!])', ' ', text)

    # 3. Panah berlabel / dinamis (extensible arrows: \xrightarrow, \xleftarrow, dsb.)
    def _repl_xarrow(m):
        cmd = m.group(1)
        sub = (m.group(2) or "").strip()
        sup = (m.group(3) or "").strip()

        # Bersihkan spasi dan format teks di dalam label
        sup = re.sub(r'\\(?:mathbf|textbf)\{([^}]+)\}', r'**\1**', sup)
        sup = re.sub(r'\\(?:mathrm|text)\{([^}]+)\}', r'\1', sup)
        sup = re.sub(r'\\(?:quad|qquad|enspace|thinspace|[ ,;:!])', ' ', sup).strip()

        sub = re.sub(r'\\(?:mathbf|textbf)\{([^}]+)\}', r'**\1**', sub)
        sub = re.sub(r'\\(?:mathrm|text)\{([^}]+)\}', r'\1', sub)
        sub = re.sub(r'\\(?:quad|qquad|enspace|thinspace|[ ,;:!])', ' ', sub).strip()

        if sup and sub:
            content = f"{sup} / {sub}"
        elif sup:
            content = sup
        elif sub:
            content = sub
        else:
            content = ""

        is_double = "Rightarrow" in cmd or "Leftarrow" in cmd or "Leftrightarrow" in cmd
        if not content:
            if "leftrightarrow" in cmd.lower():
                return " ⇔ " if is_double else " ↔ "
            elif "left" in cmd.lower():
                return " ⇐ " if is_double else " ← "
            else:
                return " ⇒ " if is_double else " → "

        # Jika sudah berformat kurung (...) atau [...], jangan bungkus dobel
        if (content.startswith("(") and content.endswith(")")) or (content.startswith("[") and content.endswith("]")):
            inner = content
        else:
            inner = f"({content})"

        if "leftrightarrow" in cmd.lower():
            return f" ⇔═{inner}═⇔ " if is_double else f" ←─{inner}─→ "
        elif "left" in cmd.lower():
            return f" ⇐═{inner}═ " if is_double else f" ←─{inner}─ "
        else:
            return f" ═{inner}═⇒ " if is_double else f" ─{inner}─→ "

    text = re.sub(
        r'\\(x[rR]ightarrow|x[lL]eftarrow|x[lL]eftrightarrow|x[rR]ightleftharpoons|xLeftrightarrow|xRightarrow|xLeftarrow)(?:\[([^\]]*)\])?\{([^}]*)\}',
        _repl_xarrow,
        text
    )

    # 4. Simbol panah statis (termasuk fallback \xrightarrow tanpa argumen)
    text = re.sub(r'\\(?:xrightarrow|rightarrow|to|longrightarrow)', '→', text)
    text = re.sub(r'\\(?:xleftarrow|longleftarrow|leftarrow)', '←', text)
    text = re.sub(r'\\(?:xRightarrow|Rightarrow|Longrightarrow|implies)', '⇒', text)
    text = re.sub(r'\\(?:xLeftarrow|Leftarrow|Longleftarrow|impliedby)', '⇐', text)
    text = re.sub(r'\\(?:xleftrightarrow|xLeftrightarrow|leftrightarrow|Leftrightarrow|Longleftrightarrow|iff)', '⇔', text)
    text = re.sub(r'\\uparrow', '↑', text)
    text = re.sub(r'\\downarrow', '↓', text)
    text = re.sub(r'\\updownarrow', '↕', text)
    text = re.sub(r'\\nearrow', '↗', text)
    text = re.sub(r'\\searrow', '↘', text)
    text = re.sub(r'\\swarrow', '↙', text)
    text = re.sub(r'\\nwarrow', '↖', text)
    text = re.sub(r'\\mapsto', '↦', text)

    # 5. Simbol operasi matematika, relasi & perbandingan
    text = re.sub(r'\\times', '×', text)
    text = re.sub(r'\\div', '÷', text)
    text = re.sub(r'\\pm', '±', text)
    text = re.sub(r'\\mp', '∓', text)
    text = re.sub(r'\\neq', '≠', text)
    text = re.sub(r'\\approx', '≈', text)
    text = re.sub(r'\\equiv', '≡', text)
    text = re.sub(r'\\sim', '∼', text)
    text = re.sub(r'\\cong', '≅', text)
    text = re.sub(r'\\propto', '∝', text)
    text = re.sub(r'\\(?:le|leq)', '≤', text)
    text = re.sub(r'\\(?:ge|geq)', '≥', text)
    text = re.sub(r'\\ll', '≪', text)
    text = re.sub(r'\\gg', '≫', text)
    text = re.sub(r'\\parallel', '∥', text)
    text = re.sub(r'\\perp', '⊥', text)
    text = re.sub(r'\\cdot', '·', text)
    text = re.sub(r'\\(?:dots|cdots|ldots)', '...', text)
    text = re.sub(r'\\angle', '∠', text)
    text = re.sub(r'\^?\\circ', '°', text)
    text = re.sub(r'\\infty', '∞', text)

    # 6. Geometri, Figur & Penanda
    text = re.sub(r'\\triangle', '△', text)
    text = re.sub(r'\\square', '□', text)
    text = re.sub(r'\\bullet', '•', text)
    text = re.sub(r'\\star', '★', text)
    text = re.sub(r'\\ast', '*', text)
    text = re.sub(r'\\checkmark', '✓', text)

    # 7. Logika & Himpunan
    text = re.sub(r'\\therefore', '∴', text)
    text = re.sub(r'\\because', '∵', text)
    text = re.sub(r'\\in', '∈', text)
    text = re.sub(r'\\notin', '∉', text)
    text = re.sub(r'\\subset', '⊂', text)
    text = re.sub(r'\\cup', '∪', text)
    text = re.sub(r'\\cap', '∩', text)
    text = re.sub(r'\\(?:emptyset|varnothing)', '∅', text)
    text = re.sub(r'\\forall', '∀', text)
    text = re.sub(r'\\exists', '∃', text)
    text = re.sub(r'\\neg', '¬', text)
    text = re.sub(r'\\land', '∧', text)
    text = re.sub(r'\\lor', '∨', text)

    # 8. Pecahan, Akar, Pangkat & Indeks
    text = re.sub(r'\\(?:frac|dfrac|tfrac)\{([^}]+)\}\{([^}]+)\}', r'(\1/\2)', text)
    text = re.sub(r'\\sqrt\{([^}]+)\}', r'√(\1)', text)
    text = re.sub(r'\\sqrt\[([^\]]+)\]\{([^}]+)\}', r'^\1√(\2)', text)
    text = re.sub(r'\^\{([^}]+)\}', r'^\1', text)
    text = re.sub(r'_\{([^}]+)\}', r'_\1', text)

    # 9. Fungsi & Huruf Yunani umum
    text = re.sub(r'\\(?:sin|cos|tan|log|ln)', lambda m: m.group(0)[1:], text)
    greek_symbols = {
        r'\\alpha': 'α', r'\\beta': 'β', r'\\gamma': 'γ', r'\\delta': 'δ',
        r'\\theta': 'θ', r'\\pi': 'π', r'\\sigma': 'σ', r'\\omega': 'ω',
        r'\\lambda': 'λ', r'\\Delta': 'Δ', r'\\Sigma': 'Σ', r'\\Omega': 'Ω',
        r'\\phi': 'φ', r'\\Phi': 'Φ', r'\\mu': 'μ', r'\\rho': 'ρ',
        r'\\tau': 'τ', r'\\epsilon': 'ε', r'\\eta': 'η', r'\\zeta': 'ζ', r'\\psi': 'ψ'
    }
    for pat, sym in greek_symbols.items():
        text = re.sub(pat, sym, text)

    # 10. Math blocks ($$...$$, \[...\], \(...\))
    text = re.sub(r'\$\$(.*?)\$\$', r'\1', text, flags=re.DOTALL)
    text = re.sub(r'\\\[(.*?)\\\]', r'\1', text, flags=re.DOTALL)
    text = re.sub(r'\\\((.*?)\\\)', r'\1', text, flags=re.DOTALL)

    # 11. Inline math wrapper ($...$)
    text = re.sub(r'\$([^\$\n]+)\$', r'\1', text)

    # 12. Bersihkan spasi ganda sisa pembersihan
    text = re.sub(r'[ \t]{2,}', ' ', text)

    return text.strip()


def strip_think_tags(text: str) -> str:
    """Menghapus blok <think>...</think> dari model reasoning/thinking."""
    if not text:
        return ""
    cleaned = re.sub(r'<think>[\s\S]*?</think>', '', text, flags=re.DOTALL)
    cleaned = re.sub(r'^[\s\S]*?</think>', '', cleaned, flags=re.DOTALL)
    return cleaned.strip()


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

# Inisialisasi SDK OpenAI (untuk DashScope / Qwen API)
try:
    from openai import OpenAI
    _openai_available = True
except ImportError:
    _openai_available = False
    print("[AIService] Warning: openai belum terinstall")

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai_config.json")

# Urutan prioritas model:
# 1. Qwen 3.8 Flash (Default)
# 2. Qwen 3.7 Flash (Fallback 2)
# 3. Gemini 3.5 Flash (Fallback 3)
# 4. Gemini 3.5 Flash Lite (Fallback 4)
# 5. Gemini 3.6 Flash, 3.7 Flash, Flash Latest, 2.5 Flash
DEFAULT_MODELS = [
    "qwen3.8-flash",
    "qwen3.7-flash",
    "gemini-3.5-flash",
    "gemini-3.5-flash-lite",
    "gemini-3.6-flash",
    "gemini-3.7-flash",
    "gemini-flash-latest",
    "gemini-2.5-flash"
]


class AIService:
    def __init__(self):
        self.config = self._load_config()
        self._gemini_client: Optional[Any] = None
        self._qwen_client: Optional[Any] = None
        self._client: Optional[Any] = None  # alias untuk backward compatibility
        self._init_clients()

    def _load_config(self) -> Dict[str, Any]:
        """Memuat konfigurasi dari file atau environment variable."""
        cfg = {
            "dashscope_api_key": os.environ.get("DASHSCOPE_API_KEY") or os.environ.get("QWEN_API_KEY", ""),
            "dashscope_base_url": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            "gemini_api_key": os.environ.get("GEMINI_API_KEY", ""),
            "model": "qwen3.8-flash",
            "qwen_connect_timeout": 10,
            "qwen_chunk_timeout": 15,
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
            self._init_clients()
            return True
        except Exception as e:
            print(f"[AIService] Gagal menyimpan config: {e}")
            return False

    def _init_clients(self):
        """Inisialisasi semua client LLM (Gemini & DashScope Qwen)."""
        self._init_gemini_client()
        self._init_qwen_client()

    def _init_gemini_client(self):
        """Inisialisasi klien google-genai resmi dengan format client = genai.Client()."""
        api_key = (self.config.get("gemini_api_key") or os.environ.get("GEMINI_API_KEY") or "").strip()
        if not api_key:
            self._gemini_client = None
            self._client = None
            return
        if not _genai_available:
            print("[AIService] Pustaka google-genai belum tersedia!")
            self._gemini_client = None
            self._client = None
            return

        try:
            self._gemini_client = genai.Client(api_key=api_key)
            self._client = self._gemini_client
            print("[AIService] Google GenAI Client berhasil diinisialisasi.")
        except Exception as e:
            print(f"[AIService] Gagal inisialisasi GenAI client: {e}")
            self._gemini_client = None
            self._client = None

    def _init_qwen_client(self):
        """Inisialisasi klien DashScope Qwen melalui OpenAI SDK resmi per dokumentasi September 2026."""
        api_key = (
            self.config.get("dashscope_api_key")
            or self.config.get("qwen_api_key")
            or os.environ.get("DASHSCOPE_API_KEY")
            or os.environ.get("QWEN_API_KEY")
            or ""
        ).strip()
        if not api_key:
            self._qwen_client = None
            return
        if not _openai_available:
            print("[AIService] Pustaka openai belum tersedia untuk Qwen!")
            self._qwen_client = None
            return

        base_url = (self.config.get("dashscope_base_url") or "https://dashscope-intl.aliyuncs.com/compatible-mode/v1").strip()
        try:
            self._qwen_client = OpenAI(
                api_key=api_key,
                base_url=base_url
            )
            print(f"[AIService] DashScope Qwen Client berhasil diinisialisasi ({base_url}).")
        except Exception as e:
            print(f"[AIService] Gagal inisialisasi DashScope Qwen client: {e}")
            self._qwen_client = None

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

    def _get_qwen_credentials(self):
        """Ambil API key dan base URL DashScope dari config/env."""
        api_key = (
            self.config.get("dashscope_api_key")
            or self.config.get("qwen_api_key")
            or os.environ.get("DASHSCOPE_API_KEY")
            or os.environ.get("QWEN_API_KEY")
            or ""
        ).strip()
        if not api_key:
            raise ValueError("DashScope API Key belum diset.")
        base_url = (self.config.get("dashscope_base_url") or "https://dashscope-intl.aliyuncs.com/compatible-mode/v1").rstrip("/")
        return api_key, base_url

    def _stream_qwen_request(self, model_name: str, payload: dict, label: str = "") -> str:
        """
        Mengirim request ke DashScope dengan STREAMING (SSE).
        Logika liveness-detection:
        - connect_timeout: batas waktu koneksi awal ke server (default 10s)
        - chunk_timeout: batas waktu antar-chunk data (default 15s)
          → Jika model HIDUP & mikir, chunk terus mengalir → tidak pernah timeout.
          → Jika model MATI/stuck, tidak ada chunk → timeout 15s → langsung fallback.
        Ini jauh lebih cerdas daripada flat timeout karena model yang beneran kerja
        tidak akan pernah di-kill, sementara model yang stuck langsung ketahuan.
        """
        api_key, base_url = self._get_qwen_credentials()
        url = f"{base_url}/chat/completions"

        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        }

        # Aktifkan streaming SSE
        payload["stream"] = True

        connect_timeout = self.config.get("qwen_connect_timeout", 10)
        chunk_timeout = self.config.get("qwen_chunk_timeout", 15)

        tag = label or model_name

        # --- Fase 1: Koneksi & mulai stream ---
        try:
            resp = requests.post(
                url, headers=headers, json=payload,
                stream=True, timeout=(connect_timeout, chunk_timeout)
            )
        except requests.exceptions.ConnectTimeout:
            raise ValueError(f"Gagal terhubung ke DashScope {tag} dalam {connect_timeout}s.")
        except requests.exceptions.ReadTimeout:
            raise ValueError(f"DashScope {tag} tidak merespon sama sekali dalam {chunk_timeout}s.")
        except Exception as e:
            raise ValueError(f"Gagal menghubungi DashScope {tag}: {e}")

        if resp.status_code != 200:
            err_msg = ""
            try:
                err_data = resp.json().get("error", {})
                err_msg = err_data.get("message", resp.text)
            except Exception:
                err_msg = resp.text
            raise ValueError(f"DashScope {tag} Error ({resp.status_code}): {err_msg}")

        # --- Fase 2: Parse SSE stream ---
        # Selama chunk terus datang, kita tunggu (model hidup & mikir).
        # Kalau chunk berhenti > chunk_timeout detik, berarti stuck → ReadTimeout.
        full_content = []
        full_reasoning = []
        got_first_chunk = False

        try:
            for line in resp.iter_lines(decode_unicode=True):
                if not line:
                    continue
                if not line.startswith("data: "):
                    continue
                data_str = line[6:]
                if data_str.strip() == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_str)
                    choices = chunk.get("choices", [])
                    if not choices:
                        continue
                    delta = choices[0].get("delta", {})

                    if not got_first_chunk:
                        got_first_chunk = True
                        print(f"[AIService] ✓ {model_name} merespon — sedang memproses...")

                    content = delta.get("content")
                    reasoning = delta.get("reasoning_content")
                    if content:
                        full_content.append(content)
                    if reasoning:
                        full_reasoning.append(reasoning)
                except json.JSONDecodeError:
                    continue
        except requests.exceptions.ReadTimeout:
            if not got_first_chunk:
                raise ValueError(
                    f"DashScope {tag} tidak mengirim data apapun dalam {chunk_timeout}s — model kemungkinan stuck."
                )
            # Sudah dapat data tapi stream terhenti — gunakan apa yang sudah ada
            print(f"[AIService] ⚠ Stream {model_name} terhenti, menggunakan respon parsial...")
        except requests.exceptions.ChunkedEncodingError as e:
            if not got_first_chunk:
                raise ValueError(f"Koneksi DashScope {tag} terputus sebelum data diterima: {e}")
            print(f"[AIService] ⚠ Stream {model_name} terputus: {e}, menggunakan respon parsial...")
        except Exception as e:
            if not got_first_chunk:
                raise ValueError(f"Error stream DashScope {tag}: {e}")
            print(f"[AIService] ⚠ Stream {model_name} error: {e}, menggunakan respon parsial...")
        finally:
            resp.close()

        raw_answer = "".join(full_content) or "".join(full_reasoning) or ""
        if not raw_answer.strip():
            raise ValueError(f"Respon {model_name} kosong.")

        raw_answer = strip_think_tags(raw_answer)
        return clean_latex_to_markdown(raw_answer)

    def _query_qwen_text(self, model_name: str, prompt: str) -> str:
        """
        Kueri model Qwen teks via DashScope OpenAI-compatible endpoint (streaming).
        Menghindari bug 'maximum recursion depth exceeded' yang terjadi akibat konflik
        antara eventlet.monkey_patch() dan truststore pada pustaka openai/httpx.
        """
        payload = {
            "model": model_name,
            "messages": [{"role": "user", "content": prompt}],
            "enable_thinking": True
        }
        return self._stream_qwen_request(model_name, payload)

    def _query_qwen_multimodal(self, model_name: str, prompt: str, raw_bytes: bytes, mime_type: str) -> str:
        """
        Kueri model Qwen multimodal (vision) via DashScope OpenAI-compatible endpoint (streaming).
        Mendukung analisis soal Figural, gambar, dan diagram secara langsung (0 token lokal OCR).
        """
        b64_str = base64.b64encode(raw_bytes).decode("utf-8")
        data_url = f"data:{mime_type};base64,{b64_str}"

        payload = {
            "model": model_name,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": prompt},
                        {
                            "type": "image_url",
                            "image_url": {"url": data_url}
                        }
                    ]
                }
            ],
            "enable_thinking": True
        }
        return self._stream_qwen_request(model_name, payload, label=f"{model_name} Vision")

    def _query_gemini_text(self, model_name: str, prompt: str) -> str:
        """Kueri model Gemini teks via google-genai SDK."""
        if not self._gemini_client:
            self._init_gemini_client()
        if not self._gemini_client:
            raise ValueError("GEMINI_API_KEY belum diset.")

        gen_config = self._get_thinking_config(model_name)
        response = self._gemini_client.models.generate_content(
            model=model_name,
            contents=prompt,
            config=gen_config
        )
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

        if not answer_text:
            raise ValueError("Respon Gemini teks kosong.")

        answer_text = strip_think_tags(answer_text)
        return clean_latex_to_markdown(answer_text)

    def _query_gemini_multimodal(self, model_name: str, prompt: str, raw_bytes: bytes, mime_type: str) -> str:
        """Kueri model Gemini multimodal (vision) via google-genai SDK."""
        if not self._gemini_client:
            self._init_gemini_client()
        if not self._gemini_client:
            raise ValueError("GEMINI_API_KEY belum diset.")

        if not _genai_available:
            raise ValueError("Pustaka google-genai belum tersedia di server.")

        image_part = types.Part.from_bytes(data=raw_bytes, mime_type=mime_type)
        gen_config = self._get_thinking_config(model_name)
        response = self._gemini_client.models.generate_content(
            model=model_name,
            contents=[image_part, prompt],
            config=gen_config
        )
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

        if not answer_text:
            raise ValueError("Respon Gemini Vision kosong.")

        answer_text = strip_think_tags(answer_text)
        return clean_latex_to_markdown(answer_text)

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

    def query_llm(self, text_content: str, custom_instruction: Optional[str] = None) -> Dict[str, Any]:
        """
        Mengirimkan teks OCR ke LLM dengan urutan fallback:
        1. Model utama (default: qwen3.8-flash)
        2. Fallback 2: qwen3.7-flash
        3. Fallback 3: gemini-3.5-flash
        4. Fallback 4: gemini-3.5-flash-lite
        5. Model Gemini flash lainnya.
        """
        instruction = custom_instruction or self.config.get("prompt_template", "")
        prompt = (
            f"Berikut adalah teks yang diekstrak dari layar monitor/buku/soal:\n"
            f"\"\"\"\n{text_content}\n\"\"\"\n\n"
            f"Instruksi:\n{instruction}"
        )

        preferred_model = self.config.get("model", "qwen3.8-flash")
        candidate_models = [preferred_model] + [m for m in DEFAULT_MODELS if m != preferred_model]

        last_err = ""
        for model_name in candidate_models:
            is_qwen = "qwen" in model_name.lower()
            try:
                if is_qwen:
                    api_key = (
                        self.config.get("dashscope_api_key")
                        or self.config.get("qwen_api_key")
                        or os.environ.get("DASHSCOPE_API_KEY")
                        or os.environ.get("QWEN_API_KEY")
                        or ""
                    ).strip()
                    if not api_key:
                        print(f"[AIService] DashScope API Key belum diset untuk {model_name}. Fallback ke model berikutnya...")
                        continue
                    ans = self._query_qwen_text(model_name, prompt)
                else:
                    api_key = (self.config.get("gemini_api_key") or os.environ.get("GEMINI_API_KEY") or "").strip()
                    if not api_key:
                        print(f"[AIService] GEMINI_API_KEY belum diset untuk {model_name}. Fallback ke model berikutnya...")
                        continue
                    ans = self._query_gemini_text(model_name, prompt)

                if ans:
                    return {
                        "success": True,
                        "answer": ans,
                        "model": model_name
                    }
            except Exception as err:
                last_err = str(err)
                print(f"[AIService] Model {model_name} mengalami kendala: {err}. Langsung fallback ke model berikutnya...")

        return {
            "success": False,
            "error": f"Semua model AI gagal merespons. Pastikan API key terisi di server/ai_config.json. Error terakhir: {last_err}"
        }

    # Backward compatibility
    query_gemini = query_llm

    def query_multimodal(
        self,
        image_data: str | bytes,
        custom_instruction: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Mengirimkan GAMBAR LANGSUNG ke model Vision (Qwen / Gemini)
        Sangat efektif untuk membedah soal FIGURAL, pola deret gambar, matriks visual,
        geometri, atau diagram yang tidak dapat diproses oleh OCR teks biasa.
        """
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
        except Exception as e:
            return {"success": False, "error": f"Gagal membaca byte gambar: {e}"}

        # 2. Susun prompt pembedahan figural & visual
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

        # 3. Urutan fallback
        preferred_model = self.config.get("model", "qwen3.8-flash")
        candidate_models = [preferred_model] + [m for m in DEFAULT_MODELS if m != preferred_model]

        last_err = ""
        for model_name in candidate_models:
            is_qwen = "qwen" in model_name.lower()
            try:
                if is_qwen:
                    api_key = (
                        self.config.get("dashscope_api_key")
                        or self.config.get("qwen_api_key")
                        or os.environ.get("DASHSCOPE_API_KEY")
                        or os.environ.get("QWEN_API_KEY")
                        or ""
                    ).strip()
                    if not api_key:
                        print(f"[AIService] DashScope API Key belum diset untuk vision {model_name}. Fallback ke model berikutnya...")
                        continue
                    ans = self._query_qwen_multimodal(model_name, prompt, raw_bytes, mime_type)
                else:
                    api_key = (self.config.get("gemini_api_key") or os.environ.get("GEMINI_API_KEY") or "").strip()
                    if not api_key:
                        print(f"[AIService] GEMINI_API_KEY belum diset untuk vision {model_name}. Fallback ke model berikutnya...")
                        continue
                    ans = self._query_gemini_multimodal(model_name, prompt, raw_bytes, mime_type)

                if ans:
                    return {
                        "success": True,
                        "answer": ans,
                        "model": model_name
                    }
            except Exception as err:
                last_err = str(err)
                print(f"[AIService] Model {model_name} (Vision) mengalami kendala: {err}. Mencoba fallback berikutnya...")

        return {
            "success": False,
            "error": f"Semua model Vision gagal merespons. Pastikan API key terisi di server/ai_config.json. Error terakhir: {last_err}"
        }

    # Backward compatibility
    query_gemini_multimodal = query_multimodal

    def process(
        self,
        ocr_text: Optional[str] = None,
        image_data: Optional[str] = None,
        prompt: Optional[str] = None,
        mode: Optional[str] = "ocr"
    ) -> Dict[str, Any]:
        """
        Pipeline lengkap:
        - Jika mode == 'vision' dan ada gambar: langsung kirim ke LLM Multimodal (Figural / Visual).
        - Jika mode == 'ocr':
            1. Jika ocr_text sudah dikirim dari HP: langsung pakai!
            2. Jika HP mengirim gambar tanpa ocr_text: jalankan RapidOCR lokal untuk ekstraksi teks.
            3. Kirim teks hasil OCR ke LLM untuk dijawab.
        """
        if mode == "vision" and image_data:
            print("[AIService] 👁️ Mode Vision Langsung (Multimodal Figural) diaktifkan...")
            llm_res = self.query_multimodal(image_data=image_data, custom_instruction=prompt)
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

        print(f"[AIService] Teks OCR didapat ({len(final_ocr)} karakter). Mengirim ke model AI...")
        llm_res = self.query_llm(final_ocr, custom_instruction=prompt)

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

