@echo off
setlocal enabledelayedexpansion
title ByteBridge Server
chcp 65001 >nul

echo ===================================================
echo   ByteBridge Launcher
echo ===================================================
echo.

cd /d "%~dp0"

:: Cek Python
where python >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Python tidak ditemukan di sistem Anda!
    echo Silakan install Python 3 dari https://python.org dan centang "Add Python to PATH".
    pause
    exit /b 1
)

:: Cek virtual environment
if not exist "server\.venv\Scripts\python.exe" (
    echo [1/3] Membuat Virtual Environment...
    where uv >nul 2>nul
    if %errorlevel% equ 0 (
        uv venv server\.venv
    ) else (
        python -m venv server\.venv
    )
)

:: Cek / Install dependensi
echo [2/3] Memeriksa paket dependensi...
where uv >nul 2>nul
if %errorlevel% equ 0 (
    uv pip install --python server\.venv\Scripts\python.exe -r server\requirements.txt --quiet
) else (
    server\.venv\Scripts\pip install -r server\requirements.txt --quiet
)

echo [3/3] Menjalankan ByteBridge Server...
echo.
server\.venv\Scripts\python server\server.py

if %errorlevel% neq 0 (
    echo.
    echo [INFO] Server berhenti atau terjadi kesalahan.
    pause
)
