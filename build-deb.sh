#!/bin/bash
set -e

# Get version from pubspec.yaml
VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //' | sed 's/+.*//')
ARCH="amd64"
PACKAGE_NAME="meeting-notes"
DEB_DIR="/tmp/${PACKAGE_NAME}-deb"
DEB_FILE="${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"

echo "Building .deb package for ${PACKAGE_NAME} version ${VERSION}..."

# Build Flutter app in release mode
echo "Building Flutter app..."
flutter build linux --release

# Clean and create directory structure
echo "Creating package structure..."
rm -rf "$DEB_DIR"
mkdir -p "$DEB_DIR/DEBIAN"
mkdir -p "$DEB_DIR/opt/${PACKAGE_NAME}"
mkdir -p "$DEB_DIR/usr/bin"
mkdir -p "$DEB_DIR/usr/share/applications"
mkdir -p "$DEB_DIR/usr/share/icons/hicolor/256x256/apps"

# Copy bundle
echo "Copying application files..."
cp -r build/linux/x64/release/bundle/* "$DEB_DIR/opt/${PACKAGE_NAME}/"

# Copy scripts directory (needed for transcription)
echo "Copying scripts directory..."
if [ -d "scripts" ]; then
  cp -r scripts "$DEB_DIR/opt/${PACKAGE_NAME}/"
else
  echo "Warning: scripts directory not found"
fi

# Create launcher script
echo "Creating launcher script..."
cat > "$DEB_DIR/usr/bin/${PACKAGE_NAME}" << 'EOF'
#!/bin/bash
# Ensure PATH includes common binary directories
export PATH="/usr/bin:/bin:/usr/local/bin:$PATH"
cd /opt/meeting-notes
exec ./meeting_notes "$@"
EOF
chmod +x "$DEB_DIR/usr/bin/${PACKAGE_NAME}"

# Copy desktop file and icon
echo "Copying desktop file and icon..."
cp linux/net.joemazzone.meetingnotes.desktop "$DEB_DIR/usr/share/applications/"
cp linux/net.joemazzone.meetingnotes.png "$DEB_DIR/usr/share/icons/hicolor/256x256/apps/"

# Update desktop file to use correct paths
sed -i 's|Exec=meeting_notes|Exec=meeting-notes|g' "$DEB_DIR/usr/share/applications/net.joemazzone.meetingnotes.desktop"

# Create control file
echo "Creating control file..."
cat > "$DEB_DIR/DEBIAN/control" << EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Depends: libgtk-3-0, libglib2.0-0, pulseaudio-utils
Maintainer: Joe Mazzone <joe@joemazzone.net>
Description: AI-generated meeting notes app for Linux desktop
 Meeting Notes is an application that records audio from microphone and
 system speakers, transcribes it using faster-whisper, and generates
 AI-powered summaries using Claude.
 .
 Features:
  - Real-time audio recording (microphone + system audio)
  - Progressive transcription with faster-whisper
  - AI-powered meeting summaries using Anthropic Claude
  - Automatic file organization by timestamp
EOF

# Build .deb
echo "Building .deb package..."
dpkg-deb --build "$DEB_DIR" "$DEB_FILE"

echo ""
echo "✓ Successfully built: ${DEB_FILE}"
echo ""
echo "To install, run:"
echo "  sudo dpkg -i ${DEB_FILE}"
echo ""
echo "If you get dependency errors, run:"
echo "  sudo apt-get install -f"
