#!/bin/bash

set -e

echo "🔍 Detecting OS..."

OS=""
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if grep -qi microsoft /proc/version; then
        OS="wsl"
    elif [ -f /etc/lsb-release ]; then
        OS="ubuntu"
    fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
else
    echo "❌ Unsupported OS: $OSTYPE"
    exit 1
fi

echo "✅ OS detected: $OS"

RUNTIME=""

# Check for Podman
if command -v podman &>/dev/null && podman info &>/dev/null; then
    echo "✅ Podman is available and working."
    RUNTIME="podman"

# If no Podman, check Docker
elif command -v docker &>/dev/null && docker info &>/dev/null; then
    echo "✅ Docker is available and working."
    RUNTIME="docker"

# Try to install Podman
else
    echo "⚠️ Neither Podman nor Docker is installed. Attempting to install Podman..."

    case "$OS" in
        ubuntu)
            sudo apt update && sudo apt install -y podman || {
                echo "❌ Failed to install Podman on Ubuntu. Exiting."
                exit 1
            }
            ;;
        macos)
            if ! command -v brew &>/dev/null; then
                echo "❌ Homebrew is required to install Podman on macOS. Install it from https://brew.sh"
                exit 1
            fi
            echo "🍺 Installing Podman via Homebrew..."
            brew install podman || {
                echo "❌ Failed to install Podman."
                exit 1
            }

            echo "⚙️ Setting up Podman machine..."
            if ! podman machine list | grep -q "podman-machine-default"; then
                podman machine init || {
                    echo "❌ Failed to initialize Podman machine."
                    exit 1
                }
            fi
            podman machine start || {
                echo "❌ Failed to start Podman machine."
                exit 1
            }
            ;;
        wsl)
            echo "⚠️ Podman installation on WSL requires manual setup."
            echo "   Visit: https://podman.io/getting-started/installation"
            exit 1
            ;;
    esac

    if command -v podman &>/dev/null && podman info &>/dev/null; then
        echo "✅ Podman installed and working."
        RUNTIME="podman"
    else
        echo "❌ Podman installation failed or not configured properly."
        exit 1
    fi
fi

# ------------------------
# Proceed with container workflow
# ------------------------

# Create temp directory and ensure cleanup on exit
TMPDIR=$(mktemp -d)
echo "📁 Created temp directory: $TMPDIR"

cleanup() {
    echo "🧹 Cleaning up temporary files..."
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

cd "$TMPDIR" || exit

# Choose image source
echo "📦 How would you like to load the image?"
echo "1) Download from URL"
echo "2) Use existing .tar file from local machine"
read -p "Enter your choice [1 or 2]: " IMAGE_SOURCE_CHOICE

case "$IMAGE_SOURCE_CHOICE" in
    1)
        read -p "🌐 Enter the URL of the image tar file to download: " IMAGE_URL
        echo "📥 Downloading image..."
        wget "$IMAGE_URL" -O image.tar || { echo "❌ Failed to download image."; exit 1; }
        ;;
    2)
        read -p "📁 Enter full path to your local image tar file: " LOCAL_IMAGE_PATH
        if [[ ! -f "$LOCAL_IMAGE_PATH" ]]; then
            echo "❌ File does not exist: $LOCAL_IMAGE_PATH"
            exit 1
        fi
        echo "📋 Copying $LOCAL_IMAGE_PATH to temporary directory..."
        cp "$LOCAL_IMAGE_PATH" ./image.tar || { echo "❌ Failed to copy file."; exit 1; }
        ;;
    *)
        echo "❌ Invalid choice."
        exit 1
        ;;
esac

# Load image
echo "📦 Loading image with $RUNTIME..."
IMAGE_OUTPUT=$($RUNTIME load -i image.tar) || { echo "❌ Failed to load image."; exit 1; }
echo "$IMAGE_OUTPUT"

# Extract image SHA ID
if [[ "$RUNTIME" == "podman" ]]; then
    IMAGE_NAME=$($RUNTIME images --noheading --sort created --format "{{.ID}}" | head -n1)
else
    IMAGE_NAME=$($RUNTIME images --noheading --format "{{.ID}}" | head -n1)
fi

if [[ -z "$IMAGE_NAME" ]]; then
    echo "❌ Failed to get image ID."
    exit 1
fi

# Prompt for volume paths
read -p "📁 Enter absolute path to webmon repo (host): " WEBMON_REPO
read -p "📁 Enter absolute path to webmon lib folder (host): " WEBMON_LIB

# Confirm summary
echo "⚙️  Summary:"
echo "   Runtime: $RUNTIME"
echo "   Image SHA: $IMAGE_NAME"
echo "   Webmon Repo: $WEBMON_REPO"
echo "   Webmon Lib: $WEBMON_LIB"

read -p "Proceed to run the container? (y/n): " confirm_run
[[ "$confirm_run" != "y" ]] && { echo "❌ Aborted."; exit 0; }

# Ask for port mapping
read -p "🔌 Enter host port to map (default 3000): " HOST_PORT
HOST_PORT=${HOST_PORT:-3000}
CONTAINER_PORT=3000

echo "🚀 Running container with port mapping $HOST_PORT:$CONTAINER_PORT..."

if $RUNTIME run -p "$HOST_PORT":"$CONTAINER_PORT" \
    -v "$WEBMON_REPO":/webmon \
    -v "$WEBMON_LIB":/prod_lib \
    -e HOST_HOSTNAME="$(hostname)" \
    "$IMAGE_NAME"; then
    echo "✅ Container is running at http://localhost:$HOST_PORT"
else
    echo "❌ Failed to run container. Possible issues:"
    echo "   - Port $HOST_PORT may already be in use"
    echo "   - Volume paths may be incorrect"
    exit 1
fi
