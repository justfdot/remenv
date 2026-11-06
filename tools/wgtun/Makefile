.PHONY: build test fmt install-local

build:
	cargo build --release

test:
	cargo test

fmt:
	cargo fmt --check

install-local: build
	mkdir -p "$(HOME)/.local/bin"
	install -m 0755 target/release/wgtun "$(HOME)/.local/bin/wgtun"
