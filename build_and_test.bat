@echo off
REM Auto build, install and test script for AI Gallery
REM This script:
REM 1. Pushes to remote
REM 2. Waits for GitHub Actions build
REM 3. Downloads artifact
REM 4. Installs on Android device
REM 5. Tests the API

setlocal enabledelayedexpansion

set "REPO=Snbig/gallery"
set "ADB_PATH=D:\Program Files\Microvirt\MEmu\adb.exe"
set "GITHUB_CLI=C:\Program Files\Git\cmd\gh.exe"

echo === AI Gallery Build, Install & Test Script ===

REM Check if gh is available
where %GITHUB_CLI% >nul 2>&1
if errorlevel 1 (
    echo ERROR: GitHub CLI (gh) not found. Please install from https://cli.github.com/
    exit /b 1
)

REM Check if adb is available
where %ADB_PATH% >nul 2>&1
if errorlevel 1 (
    echo ERROR: ADB not found at %ADB_PATH%
    exit /b 1
)

REM Check device connection
echo.
echo === Step 0: Checking device ===
"%ADB_PATH%" devices | findstr /R "device$" >nul
if errorlevel 1 (
    echo No device connected. Trying to connect...
    "%ADB_PATH%" connect 192.168.1.101:43443
    timeout /t 3 >nul
)
"%ADB_PATH%" devices | findstr /R "device$" >nul
if errorlevel 1 (
    echo ERROR: No Android device connected
    exit /b 1
)
echo Device connected

REM Step 1: Push to remote
echo.
echo === Step 1: Pushing to remote ===
git push origin main
if errorlevel 1 (
    echo ERROR: Failed to push
    exit /b 1
)
echo Push complete

REM Step 2: Wait for build to complete
echo.
echo === Step 2: Waiting for GitHub Actions build ===
set "MAX_WAIT=600"
set "INTERVAL=15"
set "ELAPSED=0"

:wait_loop
timeout /t %INTERVAL% >nul
set /a ELAPSED+=INTERVAL

for /f "delims=" %%i in ('"%GITHUB_CLI%" run list --repo %REPO% --branch main --limit 1 --json status --jq ".[0].status"') do set RUN_STATUS=%%i
for /f "delims=" %%i in ('"%GITHUB_CLI%" run list --repo %REPO% --branch main --limit 1 --json conclusion --jq ".[0].conclusion"') do set RUN_CONCLUSION=%%i

echo Build status: %RUN_STATUS% (elapsed: !ELAPSED!s)

if "%RUN_STATUS%"=="completed" (
    if "%RUN_CONCLUSION%"=="success" (
        echo Build succeeded!
        goto :build_done
    ) else (
        echo Build failed with conclusion: %RUN_CONCLUSION%
        exit /b 1
    )
)

if !ELAPSED! GEQ %MAX_WAIT% (
    echo ERROR: Build timed out
    exit /b 1
)

goto :wait_loop

:build_done

REM Step 3: Download artifact
echo.
echo === Step 3: Downloading artifact ===
"%GITHUB_CLI%" api repos/%REPO%/actions/artifacts --jq ".artifacts[0].id" > artifact_id.txt
set /p ARTIFACT_ID=<artifact_id.txt

if not defined ARTIFACT_ID (
    echo ERROR: No artifact found
    del artifact_id.txt
    exit /b 1
)

"%GITHUB_CLI%" api repos/%REPO%/actions/artifacts/%ARTIFACT_ID%/zip -o artifact.zip
powershell -command "Expand-Archive -Force -Path artifact.zip -DestinationPath .\apk_download"
del artifact_id.txt

for /f "delims=" %%i in ('dir /b /s apk_download\*.apk 2^>nul') do set APK_PATH=%%i
echo Downloaded: %APK_PATH%

REM Step 4: Install on phone
echo.
echo === Step 4: Installing on device ===
"%ADB_PATH%" shell pm uninstall com.google.aiedge.gallery 2>nul
"%ADB_PATH%" install -r "%APK_PATH%"
echo APK installed

REM Step 5: Test the app
echo.
echo === Step 5: Testing API functionality ===

REM Start the app
"%ADB_PATH%" shell am start -n com.google.aiedge.gallery/com.google.ai.edge.gallery.MainActivity
timeout /t 3 >nul

REM Start the EdgeServerService
"%ADB_PATH%" shell am startservice -n com.google.aiedge.gallery/com.google.ai.edge.gallery.edgeserver.EdgeServerService
timeout /t 2 >nul

REM Test API
echo Testing API on port 8888...
"%ADB_PATH%" shell "curl -s -X POST http://127.0.0.1:8888/v1/chat/completions -H ""Content-Type: application/json"" -d ""{\""messages\"":[{\""role\"":\""user\"",\""content\"":\""Hello\""}]}""" > api_response.txt

set /p RESPONSE=<api_response.txt
echo Response: !RESPONSE!

echo !RESPONSE! | findstr /C:"error" >nul
if not errorlevel 1 (
    echo ERROR: API returned error
    echo !RESPONSE! | findstr /C:"No model loaded" >nul
    if not errorlevel 1 (
        echo.
        echo Model not loaded. Please load a model in the app and start the service again.
    )
    del api_response.txt
    exit /b 1
)

echo API test successful!

echo.
echo === All tests passed! ===

REM Cleanup
del api_response.txt
del artifact.zip
rmdir /s /q apk_download 2>nul

endlocal