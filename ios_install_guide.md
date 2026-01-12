# How to Install AntigravityCam on iPhone

Since you don't have a Mac, we are building the app using GitHub Actions (in the cloud) and installing it using **AltStore** (or Sideloadly) on Windows.

## 1. Download the IPA
1.  Go to your GitHub repository: [https://github.com/Hileos/AntigravityCam/actions](https://github.com/Hileos/AntigravityCam/actions)
2.  Click on the latest workflow run (it should be running or recently completed).
3.  Scroll down to the **Artifacts** section at the bottom.
4.  Click **AntigravityCam-IPA** to download the zip file.
5.  Extract the zip file to get `AntigravityCam.ipa`.

## 2. Install via AltStore (Recommended)
**Prerequisites:** You need [AltServer](https://altstore.io/) installed on your Windows PC and iCloud for Windows (non-Microsoft Store version).

1.  Connect your iPhone to your PC via USB.
2.  Click the AltServer icon in your system tray (bottom right).
3.  Select **Install AltStore** -> **[Your iPhone]**.
4.  Enter your Apple ID and Password when prompted.
5.  Trust the developer profile on your iPhone (**Settings -> General -> VPN & Device Management**).
6.  **[iOS 16+ ONLY]** Enable Developer Mode:
    *   Go to **Settings -> Privacy & Security -> Developer Mode**.
    *   Toggle **Developer Mode ON**.
    *   **Restart your iPhone** when prompted (required!).
    *   After restart, tap **Turn On** and enter your passcode to confirm.
    *   ⚠️ **You MUST complete this step or AltStore will show "Developer Mode Required" error.**
7.  Once AltStore is on your phone:
    *   Copy `AntigravityCam.ipa` to your iPhone (via iCloud Drive, or email it to yourself).
    *   Open **AltStore** on your phone.
    *   Tap the **My Apps** tab.
    *   Tap the **+** icon in the top left.
    *   Select the `AntigravityCam.ipa` file.
    *   The app will install!

## Alternative: Sideloadly
If AltStore is too complex, you can use [Sideloadly](https://sideloadly.io/).
1.  Open Sideloadly on Windows.
2.  Drag and drop `AntigravityCam.ipa`.
3.  Enter your Apple ID.
4.  Click **Start**.
