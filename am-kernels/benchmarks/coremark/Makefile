NAME = coremark
SRCS = $(shell find src/ -name "*.c")
ifneq ($(ITERATIONS),)
CFLAGS += -DITERATIONS=$(ITERATIONS)
endif
include $(AM_HOME)/Makefile
