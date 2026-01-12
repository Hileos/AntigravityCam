# How to Install AntigravityCam on iPhone

This guide shows how to install the AntigravityCam app using **Sideloadly** on Windows.

## Prerequisites

- iPhone running iOS 14.0 or later (tested on iOS 16.7.12)
- Windows PC
- USB cable to connect your iPhone
- Free Apple ID

## 1. Download the IPA

1. Go to GitHub Actions: [https://github.com/Hileos/AntigravityCam/actions](https://github.com/Hileos/AntigravityCam/actions)
2. Click on the latest successful workflow run (green checkmark)
3. Scroll down to **Artifacts** section
4. Click **AntigravityCam-IPA** to download the zip file
5. Extract the zip to get `AntigravityCam.ipa`

## 2. Install Sideloadly

1. Download from [https://sideloadly.io/](https://sideloadly.io/)
2. Install and launch Sideloadly

## 3. Prepare Your iPhone

### Enable Developer Mode (iOS 16+ only)

1. Go to **Settings → Privacy & Security → Developer Mode**
2. Toggle **Developer Mode ON**
3. **Restart your iPhone** when prompted
4. After restart, tap **Turn On** and enter passcode

> ⚠️ Without Developer Mode enabled, sideloaded apps won't launch!

### Connect iPhone

1. Connect your iPhone to PC via USB cable
2. If prompted on iPhone, tap **Trust** and enter passcode

## 4. Install the App via Sideloadly

1. Open **Sideloadly** on Windows
2. Drag and drop `AntigravityCam.ipa` into Sideloadly (or click the IPA icon)
3. Enter your **Apple ID** (email)
4. Click **Start**
5. When prompted, enter your Apple ID password
6. Wait for installation to complete (should take 1-2 minutes)

## 5. Trust the Developer Profile

1. On iPhone, go to **Settings → General → VPN & Device Management**
2. Tap on your Apple ID under "Developer App"
3. Tap **Trust "[your email]"**
4. Tap **Trust** again to confirm

## 6. Launch the App

1. Find **AntigravityCam** on your home screen
2. Tap to open
3. Allow camera permissions when prompted
4. Enter your PC's IP address and tap **Connect**

> 📝 **Note**: Make sure the Windows receiver app is running before connecting!

## Troubleshooting

### "Developer Mode Required" error
- Enable Developer Mode in Settings → Privacy & Security → Developer Mode
- You MUST restart after enabling

### App crashes on launch
- Make sure you trusted the developer profile
- Try reinstalling via Sideloadly

### "Could not find executable" in Sideloadly
- This means the IPA file is corrupted or improperly built
- Wait for a new build and try again

### App expires after 7 days
- Free Apple IDs only allow 7-day signatures
- Simply reinstall via Sideloadly to refresh
