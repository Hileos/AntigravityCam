@echo off
echo ===========================================
echo Antigravity Webcam - Build Helper
echo ===========================================

REM Check for FFmpeg
if not exist "ffmpeg" (
    echo [ERROR] ffmpeg directory not found! 
    echo Please ensure you have the 'ffmpeg' folder in this directory.
    pause
    exit /b
)

REM BaseClasses check skipped for Receiver-only build


echo.
echo Creating Build Directory...
if not exist build mkdir build
cd build

echo.
echo Running CMake...
cmake -G "Visual Studio 18 2026" -A x64 ..

echo.
echo ===========================================
echo Solution Generated at build/AntigravityCam.sln
echo ===========================================
echo 1. Open build/AntigravityCam.sln
echo 2. Select 'Release' configuration
echo 3. Build Solution
echo.
pause
