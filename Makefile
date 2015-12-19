#!/usr/bin/make -f

all: install

install:
	mkdir -p /opt/dewyatochka
	install -m 755 dewyatochka.pl /opt/dewyatochka/dewyatochka
	install -m 644 setup.ini.sample /opt/dewyatochka/setup.ini

uninstall:
	rm -rv /opt/dewyatochka
