.PHONY: build run app install clean

# Debug build.
build:
	swift build

# Run straight from the terminal (no .app bundle; notifications/login-item need the bundle).
run:
	swift run

# Produce CodexBarLite.app in the project root.
app:
	./Scripts/package_app.sh

# Build the .app and install it into /Applications.
install: app
	rm -rf /Applications/CodexBarLite.app
	cp -R CodexBarLite.app /Applications/
	@echo "Installed to /Applications/CodexBarLite.app — launch it from Spotlight or Finder."

clean:
	swift package clean
	rm -rf .build CodexBarLite.app
