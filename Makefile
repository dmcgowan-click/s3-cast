.PHONY: help prepare-infra prepare-server build-server deploy-server build-authorizer build-client deploy-client preview-infra up-infra set-credentials migrate-state bootstrap

.DEFAULT_GOAL := help
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

WORK_DIR := /home/ubuntu/workspace
PULUMI_DIR := $(WORK_DIR)/pulumi
SERVER_DIR := $(WORK_DIR)/server
AUTHORIZER_DIR := $(WORK_DIR)/authorizer
CLIENT_DIR := $(WORK_DIR)/client
PULUMI_STACK ?= organization/local-cast/prod
AWS_REGION ?= ap-southeast-2
AWS_ACCOUNT_ID ?= 
ECR_REPO := local-cast-backend
IMAGE_TAG ?= latest
ECR_URI := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPO)
PULUMI_STATE_BUCKET ?=
export PULUMI_CONFIG_PASSPHRASE :=

# Login to S3 backend if PULUMI_STATE_BUCKET is set, otherwise use default (local/Pulumi Cloud)
define pulumi_login
$(if $(PULUMI_STATE_BUCKET),cd $(PULUMI_DIR) && pulumi login s3://$(PULUMI_STATE_BUCKET)?region=$(AWS_REGION),)
endef

prepare-infra: ## [auto] Sync Pulumi code and install deps (called by up-infra, preview-infra)
	mkdir -p $(PULUMI_DIR)
	rsync -a --delete --exclude=node_modules pulumi/ $(PULUMI_DIR)/
	cd $(PULUMI_DIR) && npm install

prepare-server: ## [auto] Sync server code and install deps (called by build-server)
	mkdir -p $(SERVER_DIR)
	rsync -a --delete --exclude=node_modules app/server/ $(SERVER_DIR)/
	cp app/Dockerfile $(SERVER_DIR)/
	cd $(SERVER_DIR) && npm install

build-server: prepare-server ## Build backend Docker image (arm64)
	cd $(SERVER_DIR) && docker build --platform linux/arm64 -t $(ECR_REPO):$(IMAGE_TAG) .

deploy-server: build-server ## Build and push Docker image to ECR, update Lambda
	mkdir -p ~/.docker && echo '{}' > ~/.docker/config.json
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(ECR_URI)
	docker tag $(ECR_REPO):$(IMAGE_TAG) $(ECR_URI):$(IMAGE_TAG)
	docker push $(ECR_URI):$(IMAGE_TAG)
	$(eval LAMBDA_FN := $(shell cd $(PULUMI_DIR) && pulumi stack output lambdaFunctionName 2>/dev/null))
	@if [ -n "$(LAMBDA_FN)" ]; then \
		echo "Updating Lambda function $(LAMBDA_FN) to use new image..."; \
		aws lambda update-function-code --function-name $(LAMBDA_FN) --image-uri $(ECR_URI):$(IMAGE_TAG) --region $(AWS_REGION) > /dev/null; \
		echo "Waiting for Lambda update to complete..."; \
		aws lambda wait function-updated --function-name $(LAMBDA_FN) --region $(AWS_REGION); \
		echo "Lambda function updated."; \
	else \
		echo "ERROR: Could not determine Lambda function name. Run 'make up-infra' first." >&2; \
		exit 1; \
	fi

build-authorizer: ## [auto] Bundle the API Gateway authorizer Lambda (called by up-infra, preview-infra)
	mkdir -p $(AUTHORIZER_DIR)
	rsync -a --delete --exclude=node_modules --exclude=dist app/authorizer/ $(AUTHORIZER_DIR)/
	cd $(AUTHORIZER_DIR) && npm install
	cd $(AUTHORIZER_DIR) && npm run build

build-client: ## [auto] Build the Vue.js frontend (called by deploy-client)
	mkdir -p $(CLIENT_DIR)
	rsync -a --delete --exclude=node_modules --exclude=dist app/client/ $(CLIENT_DIR)/
	cd $(CLIENT_DIR) && npm install
	cd $(CLIENT_DIR) && npm run build

deploy-client: build-client up-infra ## Build and deploy frontend to S3 + invalidate CloudFront
	$(eval BUCKET := $(shell cd $(PULUMI_DIR) && pulumi stack output frontendBucketName))
	$(eval CF_ID := $(shell cd $(PULUMI_DIR) && pulumi stack output cloudfrontDistributionId))
	aws s3 sync $(CLIENT_DIR)/dist s3://$(BUCKET) --delete --region $(AWS_REGION)
	aws cloudfront create-invalidation --distribution-id $(CF_ID) --paths '/*' --region $(AWS_REGION)

up-infra: prepare-infra build-authorizer ## Deploy infrastructure with Pulumi
	mkdir -p $(PULUMI_DIR)/authorizer-bundle
	cp $(AUTHORIZER_DIR)/dist/index.js $(PULUMI_DIR)/authorizer-bundle/index.js
	$(call pulumi_login)
	cd $(PULUMI_DIR) && pulumi stack select $(PULUMI_STACK) --create 2>/dev/null; \
	pulumi up --yes --refresh --cwd $(PULUMI_DIR)

preview-infra: prepare-infra build-authorizer ## Preview infrastructure changes
	mkdir -p $(PULUMI_DIR)/authorizer-bundle
	cp $(AUTHORIZER_DIR)/dist/index.js $(PULUMI_DIR)/authorizer-bundle/index.js
	$(call pulumi_login)
	cd $(PULUMI_DIR) && pulumi stack select $(PULUMI_STACK) --create 2>/dev/null; \
	pulumi preview --refresh --cwd $(PULUMI_DIR)

set-credentials: ## Set username, password and JWT secret in Secrets Manager
	@scripts/set-credentials.sh $(PULUMI_DIR) $(AWS_REGION)

bootstrap: prepare-infra build-authorizer build-server ## First-time deploy: create ECR, push image, then full infra
	mkdir -p $(PULUMI_DIR)/authorizer-bundle
	cp $(AUTHORIZER_DIR)/dist/index.js $(PULUMI_DIR)/authorizer-bundle/index.js
	$(call pulumi_login)
	cd $(PULUMI_DIR) && pulumi stack select $(PULUMI_STACK) --create 2>/dev/null; \
	pulumi up --yes --cwd $(PULUMI_DIR) || true
	@echo "── Pushing container image to ECR ──"
	mkdir -p ~/.docker && echo '{}' > ~/.docker/config.json
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(ECR_URI)
	docker tag $(ECR_REPO):$(IMAGE_TAG) $(ECR_URI):$(IMAGE_TAG)
	docker push $(ECR_URI):$(IMAGE_TAG)
	@echo "── Completing infrastructure deployment ──"
	cd $(PULUMI_DIR) && pulumi up --yes --cwd $(PULUMI_DIR)

migrate-state: prepare-infra ## Migrate local Pulumi state to S3 backend (requires PULUMI_STATE_BUCKET)
ifndef PULUMI_STATE_BUCKET
	$(error PULUMI_STATE_BUCKET is required. Usage: make migrate-state PULUMI_STATE_BUCKET=my-bucket)
endif
	cd $(PULUMI_DIR) && pulumi login --local
	cd $(PULUMI_DIR) && pulumi stack select $(PULUMI_STACK) 2>/dev/null || \
		(echo "ERROR: Stack $(PULUMI_STACK) not found in local state"; exit 1)
	cd $(PULUMI_DIR) && pulumi stack export --file /tmp/pulumi-state-export.json
	cd $(PULUMI_DIR) && pulumi login s3://$(PULUMI_STATE_BUCKET)?region=$(AWS_REGION)
	cd $(PULUMI_DIR) && pulumi stack select $(PULUMI_STACK) --create 2>/dev/null
	cd $(PULUMI_DIR) && pulumi stack import --file /tmp/pulumi-state-export.json
	@rm -f /tmp/pulumi-state-export.json
	@echo "State migrated successfully to s3://$(PULUMI_STATE_BUCKET)"