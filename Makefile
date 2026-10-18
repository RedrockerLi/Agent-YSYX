STUID ?= ysyx_261018
STUNAME ?= Gemini-3.8-Flash

YSYX_HOME     ?= $(if $(NEMU_HOME),$(NEMU_HOME)/..,$(shell pwd))

# Empty git_commit: disables auto-commit / tracer on sim, compile, and run
define git_commit
endef

_default:
	@echo "Please run 'make' under subprojects."

.PHONY: _default

