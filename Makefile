# Snail Core VM Testing - Makefile
# =================================

.PHONY: help setup create destroy status run update configure check clean

# Default target
help:
	@echo "Snail Core VM Testing Harness"
	@echo "=============================="
	@echo ""
	@echo "Setup:"
	@echo "  make setup      - Install dependencies and download base image"
	@echo ""
	@echo "VM Management:"
	@echo "  make create     - Create 10 test VMs"
	@echo "  make destroy    - Remove all test VMs"
	@echo "  make start      - Start all VMs"
	@echo "  make stop       - Stop all VMs"
	@echo "  make status     - Show VM status"
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
	./scripts/setup-base-image.sh

# VM management
create:
	./harness.py create

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

