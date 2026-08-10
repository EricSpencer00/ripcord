APP      := Ripcord
BUNDLE   := build/$(APP).app
CONTENTS := $(BUNDLE)/Contents
CONFIG   := release
ARCHS    := --arch arm64 --arch x86_64

.PHONY: app run test cli lint clean

## Build a universal, ad-hoc signed Ripcord.app in build/
app: clean-bundle
	swift build -c $(CONFIG) $(ARCHS) --product $(APP)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $$(swift build -c $(CONFIG) $(ARCHS) --show-bin-path)/$(APP) $(CONTENTS)/MacOS/$(APP)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@swift Tools/makeicon.swift build >/dev/null
	@iconutil -c icns build/AppIcon.iconset -o $(CONTENTS)/Resources/AppIcon.icns
	@rm -rf build/AppIcon.iconset
	@codesign --force --sign - --entitlements Resources/$(APP).entitlements --timestamp=none $(BUNDLE)
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

clean-bundle:
	@rm -rf $(BUNDLE)

clean:
	rm -rf build .build
