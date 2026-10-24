PREFIX   ?= $(HOME)/.local
BIN      := $(PREFIX)/bin/brightkeys
LABEL    := com.thatbrian.brightkeys
PLIST    := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG      := $(HOME)/Library/Logs/brightkeys.log
DOMAIN   := gui/$(shell id -u)

brightkeys: brightkeys.swift
	swiftc -O -framework CoreDisplay -F /System/Library/PrivateFrameworks $< -o $@
	codesign --force --sign - --identifier $(LABEL) $@

install: brightkeys
	mkdir -p $(dir $(BIN)) $(dir $(PLIST))
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	install -m 0755 brightkeys $(BIN)
	sed -e 's|@BIN@|$(BIN)|' -e 's|@LOG@|$(LOG)|' -e 's|@LABEL@|$(LABEL)|' launchd.plist > $(PLIST)
	launchctl bootstrap $(DOMAIN) $(PLIST)
	@echo "Installed. Grant Accessibility to $(BIN) when prompted."

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	rm -f $(PLIST) $(BIN)

probe: brightkeys
	./brightkeys --probe

logs:
	tail -f $(LOG)

clean:
	rm -f brightkeys

.PHONY: install uninstall probe logs clean
