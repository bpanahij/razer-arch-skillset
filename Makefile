REPO        := $(CURDIR)
PREFIX      := _bpanahij-razer-arch-skillset__skills__
CLAUDE_DIR  := $(HOME)/.claude/skills
UNIV_DIR    := $(HOME)/.agents/skills
SKILLSHARE_CONFIG := $(HOME)/.config/skillshare/config.yaml

TARGETS := \
  claude=$(CLAUDE_DIR) \
  universal=$(UNIV_DIR)

ALL_SKILLS  := $(notdir $(wildcard $(REPO)/skills/*))
SKILLS      := $(if $(SKILL),$(SKILL),$(ALL_SKILLS))

ifeq ($(NO_COLOR)$(filter dumb,$(TERM)),)
GREEN  := \033[32m
YELLOW := \033[33m
CYAN   := \033[36m
DIM    := \033[2m
BOLD   := \033[1m
RESET  := \033[0m
else
GREEN  :=
YELLOW :=
CYAN   :=
DIM    :=
BOLD   :=
RESET  :=
endif

.PHONY: help install test untest sync status

help:
	@printf '$(BOLD)razer-arch-skillset — make targets:$(RESET)\n\n'
	@printf '  $(CYAN)make install$(RESET)             first-time per-machine setup\n'
	@printf '  $(CYAN)make test$(RESET)                point ALL skills at this working tree\n'
	@printf '  $(CYAN)make test SKILL=$(DIM)<name>$(RESET)   point ONE skill at this working tree\n'
	@printf '  $(CYAN)make untest$(RESET)              restore canonical symlinks\n'
	@printf '  $(CYAN)make sync$(RESET)                full refresh via skillshare\n'
	@printf '  $(CYAN)make status$(RESET)              show canonical vs TEST for each skill\n'

install:
	@printf '$(GREEN)Ensuring target directories…$(RESET)\n'
	@for entry in $(TARGETS); do mkdir -p "$${entry##*=}"; done
	@if ! command -v skillshare >/dev/null 2>&1; then \
	  printf '$(GREEN)Installing skillshare CLI…$(RESET)\n'; \
	  curl -fsSL https://raw.githubusercontent.com/runkids/skillshare/main/install.sh | bash; \
	fi
	@if [ ! -f $(SKILLSHARE_CONFIG) ]; then \
	  printf '$(GREEN)Running skillshare init…$(RESET)\n'; \
	  skillshare init; \
	fi
	@printf '$(GREEN)Tracking repo…$(RESET)\n'
	@skillshare install git@github.com:bpanahij/razer-arch-skillset.git --track || true
	@skillshare sync --all || true
	@printf '\n$(BOLD)Done.$(RESET) Open a new Claude session to pick up the skills.\n'

test:
	@branch=$$(git branch --show-current 2>/dev/null || echo '?'); \
	printf '$(GREEN)Pointing skills at $(REPO) (branch: %s)…$(RESET)\n' "$$branch"; \
	for s in $(SKILLS); do \
	  src=$(REPO)/skills/$$s; \
	  [ -f "$$src/SKILL.md" ] || { printf '  $(YELLOW)skip:$(RESET) %s has no SKILL.md\n' "$$s"; continue; }; \
	  for entry in $(TARGETS); do \
	    path=$${entry##*=}; [ -d "$$path" ] || continue; \
	    ln -snf "$$src" "$$path/$(PREFIX)$$s"; \
	  done; \
	  printf '  $(GREEN)✓$(RESET) %s\n' "$$s"; \
	done
	@printf '\n$(BOLD)Open a NEW Claude session$(RESET) to pick up changes.\n'

untest:
	@printf '$(GREEN)Removing test overrides…$(RESET)\n'
	@for s in $(SKILLS); do \
	  for entry in $(TARGETS); do \
	    path=$${entry##*=}; link="$$path/$(PREFIX)$$s"; \
	    [ -L "$$link" ] || continue; \
	    case "$$(readlink $$link)" in $(REPO)/*) rm -f "$$link"; printf '  $(GREEN)✓$(RESET) removed %s\n' "$$s" ;; esac; \
	  done; \
	done
	@skillshare sync --all

sync:
	skillshare update --all && skillshare sync --all

status:
	@printf '$(BOLD)%-30s  %s$(RESET)\n' SKILL SOURCE
	@printf '%-30s  %s\n' '------------------------------' '-----------------------------'
	@for s in $(ALL_SKILLS); do \
	  link="$(CLAUDE_DIR)/$(PREFIX)$$s"; \
	  if [ -L "$$link" ]; then \
	    target=$$(readlink "$$link"); \
	    case "$$target" in \
	      $(REPO)/*) printf '  %-28s  $(YELLOW)TEST$(RESET) → %s\n' "$$s" "$$target" ;; \
	      *)         printf '  %-28s  $(DIM)canonical$(RESET)\n' "$$s" ;; \
	    esac; \
	  else \
	    printf '  %-28s  $(DIM)(not synced)$(RESET)\n' "$$s"; \
	  fi; \
	done
