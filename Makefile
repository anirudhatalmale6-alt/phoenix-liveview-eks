# Convenience targets for building, validating and deploying.
IMAGE ?= phoenix-liveview
TAG   ?= 0.1.0
REGISTRY ?= localhost
CHART := deploy/helm/phoenix-liveview
RELEASE ?= rel
NAMESPACE ?= default

.PHONY: help docker-build docker-push lint helm-lint helm-template kubeconform validate deploy uninstall

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-16s %s\n", $$1, $$2}'

docker-build: ## Build the production image
	docker build -t $(REGISTRY)/$(IMAGE):$(TAG) .

docker-push: ## Push the image
	docker push $(REGISTRY)/$(IMAGE):$(TAG)

lint: ## hadolint the Dockerfile
	hadolint Dockerfile

helm-lint: ## helm lint the chart
	helm lint $(CHART)

helm-template: ## Render manifests to stdout
	helm template $(RELEASE) $(CHART)

kubeconform: ## Schema-validate rendered manifests (k8s 1.29)
	helm template $(RELEASE) $(CHART) --set secret.create=true --set ingress.enabled=true \
	  | kubeconform -kubernetes-version 1.29.0 -strict -summary -ignore-missing-schemas

validate: lint helm-lint kubeconform ## Run all static validations

deploy: ## helm upgrade --install
	helm upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) \
	  --set image.repository=$(REGISTRY)/$(IMAGE) --set image.tag=$(TAG)

uninstall: ## Remove the release
	helm uninstall $(RELEASE) -n $(NAMESPACE)
