# eks-resilience-finops
# owner: allaouiyounespro / portfolio: github.com/allaouiyounespro
#
#   make check          everything that runs without an AWS account
#   make up STACK=infra-a   build one architecture
#   make experiment STACK=infra-a
#   make finops

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

STACK        ?= infra-a
STACK_DIR    := terraform/stacks/$(STACK)
MODULES      := $(wildcard terraform/modules/*)
BACKEND      := terraform/backend.hcl

# pytest if it is installed, otherwise the stdlib runner. The tests are written
# against unittest precisely so that a machine with no pip still runs them.
PYTEST := $(shell command -v pytest 2>/dev/null)

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Offline checks - no AWS account, no money spent
# ---------------------------------------------------------------------------

.PHONY: check
check: fmt validate test ## Everything that can be verified without touching AWS

.PHONY: fmt
fmt: ## Format Terraform
	terraform fmt -recursive terraform/

.PHONY: fmt-check
fmt-check: ## Fail if Terraform is not formatted
	terraform fmt -recursive -check terraform/

.PHONY: validate
validate: ## terraform validate every module and both stacks
	@set -e; \
	for dir in $(MODULES) $(STACK_DIR) terraform/stacks/infra-b; do \
		echo "--> $$dir"; \
		terraform -chdir=$$dir init -backend=false -input=false -no-color > /dev/null; \
		terraform -chdir=$$dir validate -no-color; \
	done

.PHONY: test
test: ## Run the Python test suite
ifdef PYTEST
	pytest tests/ -q
else
	@echo "pytest not installed; using the stdlib runner"
	python3 -m unittest discover -s tests
endif

.PHONY: finops
finops: ## Price both architectures and solve the break-even
	python3 -m finops.cost_model

.PHONY: finops-verify
finops-verify: ## Fail if finops/shapes.yaml has drifted from the deployed reality
	@# A cost model that describes an architecture you no longer run is worse than
	@# no cost model, because it is believed. This diffs the mirror against the
	@# live Terraform outputs.
	@python3 scripts/verify_shapes.py

# ---------------------------------------------------------------------------
# The expensive half
# ---------------------------------------------------------------------------

.PHONY: init
init: ## terraform init with the remote backend (needs terraform/backend.hcl)
	@test -f $(BACKEND) || { echo "missing $(BACKEND) - copy backend.hcl.example"; exit 1; }
	terraform -chdir=$(STACK_DIR) init \
		-backend-config=../../backend.hcl \
		-backend-config="key=$(STACK)/terraform.tfstate"

.PHONY: plan
plan: ## terraform plan for STACK
	terraform -chdir=$(STACK_DIR) plan

.PHONY: apply
apply: ## terraform apply for STACK
	terraform -chdir=$(STACK_DIR) apply

.PHONY: up
up: apply ## Apply the stack and bootstrap the cluster onto it
	./scripts/bootstrap-cluster.sh $(STACK)

.PHONY: experiment
experiment: ## Run the AZ-failure experiment against STACK
	./scripts/run-experiment.sh $(STACK)

.PHONY: down
down: ## Destroy STACK
	@# The ALB is created by the AWS Load Balancer Controller, not by Terraform,
	@# so Terraform does not know it exists and will hang for 20 minutes trying to
	@# delete a VPC whose ENIs are still held by a load balancer it cannot see.
	@# Deleting the Gateway first - and waiting for the deletion - is not optional.
	-kubectl delete gateway witness -n witness --ignore-not-found --timeout=5m
	terraform -chdir=$(STACK_DIR) destroy

.PHONY: cost-today
cost-today: ## What the two stacks have actually cost so far, from Cost Explorer
	@./scripts/cost-explorer.sh
