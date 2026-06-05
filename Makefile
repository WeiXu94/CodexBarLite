.PHONY: build run app install dmg icon clean

# Debug build.
build:
	swift build

# Run straight from the terminal (no .app bundle; notifications/login-item need the bundle).
run:
	swift run

# Produce .build/app/CodexBarLite.app (env: BUILD_ARCHS, SIGNING_IDENTITY).
app:
	./Scripts/build-app.sh

# Build the .app and install it into /Applications.
# Set SKIP_BUILD=1 to skip building (e.g. after tweaking the icon).
install:
	@if [ -z "$(SKIP_BUILD)" ]; then $(MAKE) app; fi
	@pkill -x CodexBarLite 2>/dev/null || true
	rm -rf /Applications/CodexBarLite.app
	cp -R .build/app/CodexBarLite.app /Applications/
	open /Applications/CodexBarLite.app

# Build the .app and package it as a DMG in .build/dist/.
dmg:
	./Scripts/make-dmg.sh

icon:
	python3 Scripts/generate-app-icon.py

clean:
	swift package clean
	rm -rf .build CodexBarLite.app
