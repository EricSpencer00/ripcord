APP      := Ripcord
BUNDLE   := build/$(APP).app
CONTENTS := $(BUNDLE)/Contents
CONFIG   := release
ARCHS    := --arch arm64 --arch x86_64
VERSION  := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG      := build/$(APP)-$(VERSION).dmg

# Ad-hoc by default. Set SIGN to a Developer ID identity to make a notarisable build, which also
# needs the hardened runtime and a secure timestamp.
SIGN      ?= -
export SIGN
SIGNFLAGS := $(if $(filter -,$(SIGN)),--timestamp=none,--options runtime --timestamp)

.PHONY: app run test cli dmg demo og lint clean

## Build a universal, ad-hoc signed Ripcord.app in build/
app: clean-bundle
	swift build -c $(CONFIG) $(ARCHS) --product $(APP)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $$(swift build -c $(CONFIG) $(ARCHS) --show-bin-path)/$(APP) $(CONTENTS)/MacOS/$(APP)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@swift Tools/makeicon.swift build >/dev/null
	@iconutil -c icns build/AppIcon.iconset -o $(CONTENTS)/Resources/AppIcon.icns
	@rm -rf build/AppIcon.iconset
	@codesign --force --sign "$(SIGN)" --entitlements Resources/$(APP).entitlements $(SIGNFLAGS) $(BUNDLE)
	@codesign --verify --verbose=1 $(BUNDLE) 2>&1 | sed 's/^/  /'
	@echo "→ $(BUNDLE)"

## Build and launch it
run: app
	open $(BUNDLE)

test:
	swift test

## Build the command line harness used to check the chain against real files
cli:
	swift build -c $(CONFIG) --product ripcord-cli
	@echo "→ $$(swift build -c $(CONFIG) --show-bin-path)/ripcord-cli"

## Package the app as a .dmg. With SIGN set, and NOTARY_PROFILE or APPLE_ID/TEAM_ID/APPLE_PASSWORD,
## the image is signed, notarised and stapled.
dmg: app
	@Tools/makedmg.sh $(BUNDLE) $(DMG)

## Render the before/after clip on the landing page
demo: cli
	@mkdir -p docs/audio
	@swift Tools/makedemo.swift build/demo-before.wav
	@$$(swift build -c $(CONFIG) --show-bin-path)/ripcord-cli build/demo-before.wav --out build/demo-after.wav
	@afconvert -f m4af -d aac -b 128000 -q 127 -s 2 build/demo-before.wav docs/audio/before.m4a
	@afconvert -f m4af -d aac -b 128000 -q 127 -s 2 build/demo-after.wav docs/audio/after.m4a
	@echo "→ docs/audio"

## Render the link preview card the landing page points at
og:
	@swift Tools/makeog.swift docs/og.png

clean-bundle:
	@rm -rf $(BUNDLE)

clean:
	rm -rf build .build
