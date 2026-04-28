APP_NAME := WebAppViewer
DISPLAY_NAME := Web App Viewer
BUILD_DIR := .build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
EXECUTABLE := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
SHARE_EXTENSION_NAME := WebAppViewerShare
SHARE_EXTENSION_BUNDLE := $(APP_BUNDLE)/Contents/PlugIns/$(SHARE_EXTENSION_NAME).appex
SHARE_EXTENSION_STAGING := $(BUILD_DIR)/$(SHARE_EXTENSION_NAME).appex
SHARE_EXTENSION_EXECUTABLE := $(SHARE_EXTENSION_BUNDLE)/Contents/MacOS/$(SHARE_EXTENSION_NAME)
SHARE_EXTENSION_STAGING_EXECUTABLE := $(SHARE_EXTENSION_STAGING)/Contents/MacOS/$(SHARE_EXTENSION_NAME)
SHARE_EXTENSION_ENTITLEMENTS := ShareExtensionEntitlements.plist
MODULE_CACHE := $(BUILD_DIR)/ModuleCache
ICON := Resources/AppIcon.icns
ENTITLEMENTS := Entitlements.plist
DIST_DIR := dist
RELEASE_ZIP := $(DIST_DIR)/$(APP_NAME).zip
CONFIG ?= release
DEPLOYMENT_TARGET ?= 14.0
SWIFTC_FLAGS_debug := -Onone -g
SWIFTC_FLAGS_release := -O
SWIFTC_FLAGS = $(SWIFTC_FLAGS_$(CONFIG))
SIGN_IDENTITY ?= -
SIGN_FLAGS := --force --sign "$(SIGN_IDENTITY)" --timestamp=none --entitlements "$(ENTITLEMENTS)"

.PHONY: all clean debug release package run sign verify

all: $(APP_BUNDLE)
release: CONFIG := release
release: clean $(APP_BUNDLE) verify package

debug: CONFIG := debug
debug: clean $(APP_BUNDLE) verify

$(ICON): Scripts/GenerateAppIcon.swift
	mkdir -p Resources "$(MODULE_CACHE)"
	CLANG_MODULE_CACHE_PATH="$(MODULE_CACHE)" \
	xcrun swift \
		-module-cache-path "$(MODULE_CACHE)" \
		Scripts/GenerateAppIcon.swift

$(APP_BUNDLE): Sources/WebAppViewer/main.swift Info.plist $(ICON) $(ENTITLEMENTS) $(SHARE_EXTENSION_STAGING)
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources" "$(APP_BUNDLE)/Contents/PlugIns" "$(MODULE_CACHE)"
	cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp "$(ICON)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	cp -R "$(SHARE_EXTENSION_STAGING)" "$(APP_BUNDLE)/Contents/PlugIns/"
	printf "APPL????" > "$(APP_BUNDLE)/Contents/PkgInfo"
	CLANG_MODULE_CACHE_PATH="$(MODULE_CACHE)" \
	xcrun swiftc \
		-module-cache-path "$(MODULE_CACHE)" \
		-target arm64-apple-macosx$(DEPLOYMENT_TARGET) \
		$(SWIFTC_FLAGS) \
		-framework AppKit \
		-framework WebKit \
		-framework UniformTypeIdentifiers \
		-o "$(EXECUTABLE)" \
		Sources/WebAppViewer/main.swift
	if [ -d "$(EXECUTABLE).dSYM" ]; then \
		rm -rf "$(BUILD_DIR)/$(APP_NAME).dSYM"; \
		mv "$(EXECUTABLE).dSYM" "$(BUILD_DIR)/$(APP_NAME).dSYM"; \
	fi
	$(MAKE) sign

$(SHARE_EXTENSION_STAGING): Sources/ShareExtension/ShareViewController.swift ShareExtensionInfo.plist $(SHARE_EXTENSION_ENTITLEMENTS) $(ICON)
	rm -rf "$(SHARE_EXTENSION_STAGING)"
	mkdir -p "$(SHARE_EXTENSION_STAGING)/Contents/MacOS" "$(SHARE_EXTENSION_STAGING)/Contents/Resources" "$(MODULE_CACHE)"
	cp ShareExtensionInfo.plist "$(SHARE_EXTENSION_STAGING)/Contents/Info.plist"
	cp "$(ICON)" "$(SHARE_EXTENSION_STAGING)/Contents/Resources/AppIcon.icns"
	CLANG_MODULE_CACHE_PATH="$(MODULE_CACHE)" \
	xcrun swiftc \
		-module-cache-path "$(MODULE_CACHE)" \
		-target arm64-apple-macosx$(DEPLOYMENT_TARGET) \
		-application-extension \
		-emit-library \
		-parse-as-library \
		$(SWIFTC_FLAGS) \
		-module-name "$(SHARE_EXTENSION_NAME)" \
		-framework AppKit \
		-framework UniformTypeIdentifiers \
		-o "$(SHARE_EXTENSION_STAGING_EXECUTABLE)" \
		Sources/ShareExtension/ShareViewController.swift
	codesign --force --sign "$(SIGN_IDENTITY)" --timestamp=none --entitlements "$(SHARE_EXTENSION_ENTITLEMENTS)" "$(SHARE_EXTENSION_STAGING)"

run: $(APP_BUNDLE)
	open -n "$(CURDIR)/$(APP_BUNDLE)"

sign:
	codesign $(SIGN_FLAGS) "$(APP_BUNDLE)"

verify:
	plutil -lint Info.plist "$(APP_BUNDLE)/Contents/Info.plist" "$(ENTITLEMENTS)" ShareExtensionInfo.plist "$(SHARE_EXTENSION_BUNDLE)/Contents/Info.plist" "$(SHARE_EXTENSION_ENTITLEMENTS)"
	test -x "$(EXECUTABLE)"
	test -x "$(SHARE_EXTENSION_EXECUTABLE)"
	codesign --verify --deep --strict --verbose=4 "$(APP_BUNDLE)"

package: $(APP_BUNDLE)
	mkdir -p "$(DIST_DIR)"
	rm -f "$(RELEASE_ZIP)"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(RELEASE_ZIP)"

clean:
	rm -rf "$(BUILD_DIR)"
