.PHONY: build run app install dmg clean

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
install: app
	rm -rf /Applications/CodexBarLite.app
	cp -R .build/app/CodexBarLite.app /Applications/
	@echo "Installed to /Applications/CodexBarLite.app — launch it from Spotlight or Finder."

# Build the .app and package it as a DMG in .build/dist/.
dmg:
	./Scripts/make-dmg.sh

clean:
	swift package clean
	rm -rf .build CodexBarLite.app
