STUID ?= ysyx_261018
STUNAME ?= Gemini-3.8-Flash

YSYX_HOME     ?= $(if $(NEMU_HOME),$(NEMU_HOME)/..,$(shell pwd))

_default:
	@echo "Please run 'make' under subprojects."

.PHONY: _default

