# AVXSight

AVXSight is a macOS app for discovering and listing audio plugins installed in the system Library (`/Library`).

## Features
- Scans `/Library/Audio/Plug-Ins` for Audio Unit (AU), VST, VST3, and AAX plugins
- Displays plugin metadata (version, manufacturer, description if available)
- Lets you show plugins in Finder, copy their path, or reveal their folder in Terminal
- Only requests access to `/Library` (system Library) for maximum privacy and simplicity

## Usage
1. On first launch, click the **Refresh** button and select the `Library` folder at the top level of your disk (Macintosh HD > Library) when prompted.
2. The app will scan `/Library` for plugins and display them in the list.
3. You can rescan at any time by clicking **Refresh** again.

## Permissions
- The app only requests access to `/Library` and does **not** access or scan your user Library (`~/Library`).
- No background scanning or automatic prompts—everything is manual and user-initiated.

## Changes in this version
- **Simplified scope:** Only scans `/Library` (system Library), not the user Library
- **Simpler permissions:** Only one folder access prompt, no confusion with sandboxed or user folders
- **Cleaner UI:** All references to user Library removed

---
For more details, see the source code or open an issue.
