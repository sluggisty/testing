# Snail Core VM Testing - Makefile
# =================================

.PHONY: help setup create destroy status run update configure check clean

# Default target
help:
	@echo "Snail Core VM Testing Harness"
	@echo "=============================="
	@echo ""
	@echo "Setup:"
	@echo "  make setup           - Install dependencies and download base image (Fedora 42)"
	@echo "  make base-images-all - Download base images for all Fedora versions"
	@echo ""
	@echo "VM Management:"
	@echo "  make create          - Create 5 test VMs (Fedora 42, default)"
	@echo "  make create-all      - Create VMs for all Fedora versions (42-33)"
	@echo "  make list-versions   - List available Fedora versions"
	@echo "  make destroy         - Remove all test VMs"
	@echo "  make start           - Start all VMs"
	@echo "  make stop            - Stop all VMs"
	@echo "  make status          - Show VM status"
	@echo ""
	@echo "Snail Core:"
	@echo "  make run        - Run snail on all VMs"
	@echo "  make update     - Update snail-core on all VMs"
	@echo "  make check      - Check snail status on all VMs"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean      - Destroy VMs and clean up"

# Setup environment
setup: deps base-image
	@echo "✓ Setup complete!"

deps:
	pip install -r requirements.txt

base-image:
	./scripts/setup-base-image.sh --version 42

base-images-all:
	@for v in 42 41 40 39 38 37 36 35 34 33; do \
		echo "Downloading Fedora $$v..."; \
		./scripts/setup-base-image.sh --version $$v || true; \
	done

# VM management
create:
	./harness.py create

create-all:
	./harness.py create --versions 42,41,40,39,38,37,36,35,34,33

list-versions:
	./harness.py list-versions

destroy:
	./harness.py destroy --force

start:
	./harness.py start

stop:
	./harness.py stop

status:
	./harness.py status

# Snail operations
run:
	./harness.py run

update:
	./harness.py update

check:
	./harness.py check

configure:
	./harness.py configure

# Cleanup
clean: destroy
	rm -rf logs/
	rm -f vm-list.txt
	@echo "✓ Cleanup complete"

# Create specific number of VMs
create-%:
	./harness.py create --count $*

# Execute command on all VMs
exec:
	@read -p "Command to execute: " cmd && ./harness.py exec "$$cmd"

