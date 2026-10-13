#!/bin/zsh
# Builds Agent Watch.app and installs it in ~/Applications, set to open at login.
#   ./build.sh            build, install, (re)launch
#   ./build.sh --no-open  build and install only
set -e
cd "${0:A:h}"
swift build -c release
APP=~/Applications/"Agent Watch.app"
pkill -x AgentWatch 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AgentWatch "$APP/Contents/MacOS/AgentWatch"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Agent Watch</string>
  <key>CFBundleDisplayName</key><string>Agent Watch</string>
  <key>CFBundleIdentifier</key><string>com.claude-watcher.agentwatch</string>
  <key>CFBundleExecutable</key><string>AgentWatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Agent Watch links with teammates' Agent Watch on your local network. Nothing is sent over the internet.</string>
  <key>NSBonjourServices</key><array><string>_agentwatch._tcp</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
# open at login
AGENT=~/Library/LaunchAgents/com.claude-watcher.agentwatch.plist
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.claude-watcher.agentwatch</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
echo "installed $APP"
[[ "$1" == "--no-open" ]] || open "$APP"
