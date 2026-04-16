#!/bin/bash
# Auto build, install and test script for AI Gallery
# This script runs locally to:
# 1. Push to remote
# 2. Wait for GitHub Actions build
# 3. Download artifact
# 4. Install on Android device
# 5. Test the API

set -e

REPO="Snbig/gallery"
BRANCH="main"
DEVICE_IP="192.168.1.101"
ADB_PATH="/d/Program Files/Microvirt/MEmu/adb.exe"

echo "=== AI Gallery Build, Install & Test Script ==="

# Function to run adb commands
run_adb() {
    "$ADB_PATH" "$@"
}

# Check if device is connected
check_device() {
    echo "Checking device connection..."
    if ! "$ADB_PATH" devices | grep -q "device$"; then
        echo "No device connected. Trying to connect..."
        "$ADB_PATH" connect "$DEVICE_IP" || true
        sleep 2
        if ! "$ADB_PATH" devices | grep -q "device$"; then
            echo "ERROR: No Android device connected"
            exit 1
        fi
    fi
    echo "Device connected"
}

# Step 1: Push to remote
echo ""
echo "=== Step 1: Pushing to remote ==="
cd "$(dirname "$0")"
git push origin "$BRANCH"
echo "Push complete"

# Step 2: Trigger workflow dispatch and wait for build
echo ""
echo "=== Step 2: Triggering build ==="
gh workflow run android.yml -f test_on_device=true

# Wait for build to complete
echo "Waiting for build to complete..."
MAX_WAIT=600  # 10 minutes
INTERVAL=10
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Check latest run status
    RUN_STATUS=$(gh run list --repo "$REPO" --branch "$BRANCH" --limit 1 --json status conclusion 2>/dev/null | jq -r '.[0].status')
    RUN_CONCLUSION=$(gh run list --repo "$REPO" --branch "$BRANCH" --limit 1 --json status conclusion 2>/dev/null | jq -r '.[0].conclusion')
    
    echo "Build status: $RUN_STATUS (elapsed: ${ELAPSED}s)"
    
    if [ "$RUN_STATUS" == "completed" ]; then
        if [ "$RUN_CONCLUSION" == "success" ]; then
            echo "Build succeeded!"
            break
        else
            echo "Build failed with conclusion: $RUN_CONCLUSION"
            exit 1
        fi
    fi
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "ERROR: Build timed out"
    exit 1
fi

# Step 3: Download artifact
echo ""
echo "=== Step 3: Downloading artifact ==="
ARTIFACT_ID=$(gh api repos/$REPO/actions/artifacts --jq '.artifacts[0].id // empty')
if [ -z "$ARTIFACT_ID" ]; then
    echo "ERROR: No artifact found"
    exit 1
fi

gh api repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip -o artifact.zip
unzip -o artifact.zip -d ./apk_download
APK_PATH=$(find ./apk_download -name "*.apk" | head -1)
echo "Downloaded: $APK_PATH"

# Step 4: Install on phone
echo ""
echo "=== Step 4: Installing on device ==="
check_device

# Uninstall existing app first
run_adb shell pm uninstall com.google.aiedge.gallery 2>/dev/null || true

# Install new APK
run_adb install -r "$APK_PATH"
echo "APK installed"

# Step 5: Test the app
echo ""
echo "=== Step 5: Testing API functionality ==="

# Start the app
run_adb shell am start -n com.google.aiedge.gallery/com.google.ai.edge.gallery.MainActivity
sleep 3

# Start the EdgeServerService
run_adb shell am startservice -n com.google.aiedge.gallery/com.google.ai.edge.gallery.edgeserver.EdgeServerService
sleep 2

# Test API
echo "Testing API on port 8888..."
RESPONSE=$(run_adb shell "curl -s -X POST http://127.0.0.1:8888/v1/chat/completions -H 'Content-Type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'")

if echo "$RESPONSE" | grep -q "error"; then
    echo "ERROR: API returned error"
    echo "$RESPONSE"
    
    # Check for model loaded error
    if echo "$RESPONSE" | grep -q "No model loaded"; then
        echo ""
        echo "Model not loaded. Please load a model in the app and start the service again."
    fi
    exit 1
else
    echo "API test successful!"
    echo "Response: $RESPONSE"
fi

echo ""
echo "=== All tests passed! ==="

# Cleanup
rm -rf artifact.zip ./apk_download