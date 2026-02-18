.PHONY: help generate create delete status promote demote upgrade \
       infra-install infra-delete template template-infra preview clean check-tools

SCRIPTS_DIR := scripts
CONFS_DIR   := confs

# Default target
help: ## Show this help
	@echo "PGaaS - Postgres as a Service"
	@echo ""
	@echo "Cluster operations (require INS and ENV, optional DC):"
	@echo "  make generate   INS=ic1 ENV=local [DC=local1]  Generate merged values"
	@echo "  make create     INS=ic1 ENV=local [DC=local1]  Generate + deploy cluster"
	@echo "  make delete     INS=ic1 ENV=local [DC=local1]  Destroy cluster (with confirmation)"
	@echo "  make status     INS=ic1 ENV=local [DC=local1]  Show cluster status"
	@echo "  make promote    INS=ic1 ENV=prod  [DC=dc2] DEMOTION_TOKEN=<token>  Promote replica (graceful)"
	@echo "                  INS=ic1 ENV=prod  [DC=dc2]     Promote replica (DR force, no token)"
	@echo "  make demote     INS=ic1 ENV=prod  [DC=dc1] NEW_PRIMARY=prod-ic1-dc2  Demote primary"
	@echo "  make upgrade    INS=ic1 ENV=local [DC=local1]  Upgrade cluster image (rolling update)"
	@echo ""
	@echo "Local infrastructure:"
	@echo "  make infra-install [DC=local1]  Deploy SeaweedFS + OpenLDAP + cert-manager CA"
	@echo "  make infra-delete  [DC=local1]  Destroy local infrastructure"
	@echo ""
	@echo "Development:"
	@echo "  make check-tools     Check required CLI tools"
	@echo "  make template        INS=ic1 ENV=local   Helm template (dry-run)"
	@echo "  make template-infra  INS=ic1              Helm template local-infra"
	@echo "  make preview         [INS=ic1 ENV=local]  Generate + validate values (all scenarios if no args)"
	@echo "  make clean           Remove generated values"

# --- Cluster operations ---

generate: _check-ins-env ## Generate merged values for a client/env
	@$(SCRIPTS_DIR)/generate-values.sh $(INS) $(ENV) $(DC)

create: _check-ins-env ## Generate values + deploy cluster
	@$(SCRIPTS_DIR)/create-cluster.sh $(INS) $(ENV) $(DC)

delete: _check-ins-env ## Destroy cluster (interactive confirmation)
	@$(SCRIPTS_DIR)/delete-cluster.sh $(INS) $(ENV) $(DC)

status: _check-ins-env ## Show cluster status
	@$(SCRIPTS_DIR)/status-cluster.sh $(INS) $(ENV) $(DC)

promote: _check-ins-env ## Promote replica cluster to primary
	@$(SCRIPTS_DIR)/promote-cluster.sh $(INS) $(ENV) $(DC) $(DEMOTION_TOKEN)

demote: _check-ins-env ## Demote primary cluster
	@test -n "$(NEW_PRIMARY)" || (echo "ERROR: NEW_PRIMARY is required"; exit 1)
	@$(SCRIPTS_DIR)/demote-cluster.sh $(INS) $(ENV) $(DC) $(NEW_PRIMARY)

upgrade: _check-ins-env ## Upgrade cluster image (rolling update)
	@$(SCRIPTS_DIR)/upgrade-cluster.sh $(INS) $(ENV) $(DC)

# --- Local infrastructure ---

infra-install: ## Deploy local infrastructure (auto-generates values from admin/user config)
	@$(SCRIPTS_DIR)/install-local-infra.sh $(DC)

infra-delete: ## Destroy local infrastructure
	@$(SCRIPTS_DIR)/delete-local-infra.sh $(DC)

# --- Development helpers ---

template: _check-ins-env generate ## Helm template dry-run for a cluster
	@helm template pgaas-core ./core -f $(CONFS_DIR)/_generated/$(INS)-$(ENV)/values.yaml

template-infra: ## Helm template dry-run for local-infra (generate first with INS)
	@test -n "$(INS)" || (echo "ERROR: INS is required to generate local-infra values"; exit 1)
	@$(SCRIPTS_DIR)/generate-values.sh $(INS) local
	@echo "--- cert-manager CA (plain manifest) ---"
	@cat manifests/cert-manager-ca.yaml
	@echo ""
	@echo "--- SeaweedFS ---"
	@helm template seaweedfs ./local-infra/seaweedfs -f $(CONFS_DIR)/_generated/local-infra/seaweedfs-values.yaml
	@echo ""
	@echo "--- OpenLDAP ---"
	@helm template openldap ./local-infra/openldap -f $(CONFS_DIR)/_generated/local-infra/openldap-values.yaml

preview: ## Generate + validate values (single scenario or all)
ifdef INS
	@$(SCRIPTS_DIR)/preview-values.sh $(INS) $(ENV) $(DC)
else
	@$(SCRIPTS_DIR)/preview-values.sh
endif

check-tools: ## Check required CLI tools
	@$(SCRIPTS_DIR)/check-tools.sh

clean: ## Remove generated values
	@rm -rf $(CONFS_DIR)/_generated/
	@echo "Cleaned $(CONFS_DIR)/_generated/"

# --- Internal targets ---

_check-ins-env:
	@test -n "$(INS)" || (echo "ERROR: INS is required. Usage: make <target> INS=<client> ENV=<env> [DC=<dc>]"; exit 1)
	@test -n "$(ENV)" || (echo "ERROR: ENV is required. Usage: make <target> INS=<client> ENV=<env> [DC=<dc>]"; exit 1)
