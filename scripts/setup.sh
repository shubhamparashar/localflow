#!/bin/bash
# One-time setup: install whisper.cpp and download the transcription model.
set -euo pipefail

MODEL_DIR="$HOME/Library/Application Support/LocalFlow/models"
MODEL_FILE="$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew is required (https://brew.sh)" >&2
    exit 1
fi

if ! command -v whisper-server >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/whisper-server ]; then
    echo "==> Installing whisper-cpp via Homebrew"
    brew install whisper-cpp
else
    echo "==> whisper-cpp already installed"
fi

mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_FILE" ]; then
    echo "==> Model already present: $MODEL_FILE"
else
    echo "==> Downloading ggml-large-v3-turbo-q5_0 (~574 MB)"
    curl -L --fail -C - -o "$MODEL_FILE" "$MODEL_URL"
fi

VAD_FILE="$MODEL_DIR/ggml-silero-v5.1.2.bin"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
if [ -f "$VAD_FILE" ]; then
    echo "==> VAD model already present: $VAD_FILE"
else
    echo "==> Downloading Silero VAD model (~1 MB)"
    curl -L --fail -o "$VAD_FILE" "$VAD_URL"
fi

echo "==> Setup complete"
