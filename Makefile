VER=v0.9.123
PLATFORM=linux/arm64,linux/amd64
DEST=--push

CONTAINER_ENV = -v "`pwd`/here:/here" --network host --ulimit core=-1

all: alpine-tcl

ubuntu-tcl: Dockerfile.ubuntu
	docker buildx build $(DEST) --target ubuntu-tcl-build-base --platform $(PLATFORM) -t cyanogilvie/ubuntu-tcl:$(VER)-stripped -f Dockerfile.ubuntu .

alpine-tcl: Dockerfile
	#docker buildx build --target tcl-build --platform linux/amd64 -t alpine-tcl-build .
	#docker buildx build --target tcl --platform linux/amd64 -t cyanogilvie/alpine-tcl:$(VER) .
	docker buildx build $(EXTRA) $(DEST) --provenance=false --target tcl-stripped --platform $(PLATFORM) -t cyanogilvie/alpine-tcl:$(VER)-stripped -t cyanogilvie/alpine-tcl:latest .

alpine-tcl-build-base: Dockerfile
	docker buildx build $(EXTRA) $(DEST) --target tcl-build-base --platform $(PLATFORM) -t alpine-tcl-build-base .

alpine-tcl-build-base-arm64: Dockerfile
	docker buildx build $(EXTRA) $(DEST) --target tcl-build-base --platform linux/arm64 -t alpine-tcl-build-base-arm64 .

alpine-tcl-gdb: Makefile Dockerfile
	docker buildx build $(EXTRA) $(DEST) --target tcl-gdb --platform $(PLATFORM) -t cyanogilvie/alpine-tcl:$(VER)-gdb .

alpine-tcl-test: Dockerfile
	docker buildx build --load --target tcl -t alpine-tcl:test .
	touch alpine-tcl-test

al2023-tcl: Dockerfile
	docker buildx build --build-arg DIST=al2023 $(EXTRA) $(DEST) --provenance=false --target tcl-stripped --platform $(PLATFORM) -t cyanogilvie/al2023-tcl:$(VER)-stripped -t cyanogilvie/al2023-tcl:latest -f Dockerfile .

m2: Dockerfile
	docker buildx build --target m2 --platform linux/amd64 -t cyanogilvie/m2:$(VER) .
	docker buildx build --target m2-stripped --platform linux/amd64 -t cyanogilvie/m2:$(VER)-stripped .

upload: alpine-tcl m2
	docker push cyanogilvie/alpine-tcl:$(VER)-stripped
	#docker push cyanogilvie/alpine-tcl:$(VER)
	docker push cyanogilvie/m2:$(VER)-stripped

package_report: alpine-tcl
	docker run --rm -v "`pwd`/tools:/tools" alpine-tcl-build /tools/package_report

gdb:
	echo "/tmp/cores" | sudo tee /proc/sys/kernel/core_pattern
	docker buildx build --target tcl-gdb --platform linux/amd64 -t alpine-tcl-gdb .
	docker run --rm -it --init --name rl-nsadmin --cap-add=SYS_PTRACE --security-opt seccomp=unconfined $(CONTAINER_ENV) alpine-tcl-gdb

aws-lambda-rie-arm64:
	wget https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/download/v1.9/aws-lambda-rie-arm64
	chmod +x aws-lambda-rie-arm64

aws-lambda-rie-x86_64:
	wget https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/download/v1.9/aws-lambda-rie-x86_64
	chmod +x aws-lambda-rie-x86_64

lambdatest-arm64: aws-lambda-rie-arm64
	VER="$(VER)" PLATFORM=linux/arm64 RIE=aws-lambda-rie-arm64 docker-compose down
	VER="$(VER)" PLATFORM=linux/arm64 RIE=aws-lambda-rie-arm64 docker-compose run --rm test tests/all.tcl $(TESTFLAGS)
	VER="$(VER)" PLATFORM=linux/arm64 RIE=aws-lambda-rie-arm64 docker-compose logs lambda
	VER="$(VER)" PLATFORM=linux/arm64 RIE=aws-lambda-rie-arm64 docker-compose down

lambdatest-amd64: aws-lambda-rie-x86_64
	VER="$(VER)" PLATFORM=linux/amd64 RIE=aws-lambda-rie-x86_64 docker-compose down
	VER="$(VER)" PLATFORM=linux/amd64 RIE=aws-lambda-rie-x86_64 docker-compose run --rm test tests/all.tcl $(TESTFLAGS)
	VER="$(VER)" PLATFORM=linux/amd64 RIE=aws-lambda-rie-x86_64 docker-compose logs lambda
	VER="$(VER)" PLATFORM=linux/amd64 RIE=aws-lambda-rie-x86_64 docker-compose down

BUILDER=
PLATFORM=

DIST=ubuntu
TCLVER=9.0
DESTDIR=/opt/tcl9g
TCLCOPYTARGET=debug
copy_build:
	docker buildx build $(BUILDER) $(PLATFORM) --load --provenance=false -t copy_build_$(TCLCOPYTARGET) \
		--target		tcl-copy \
		--build-arg		"TCLCOPYTARGET=$(TCLCOPYTARGET)" \
		--build-arg		"DIST=$(DIST)" \
		--build-arg		"TCLVER=$(TCLVER)" \
		--build-arg		"TCLROOT=$(DESTDIR)" \
		.
	docker run --rm \
		$(PLATFORM) \
		-v "$(DESTDIR)":/copyout \
		copy_build_$(TCLCOPYTARGET) \
		bash -c "cp -a /out${DESTDIR}/* /copyout/"
	docker rmi copy_build_$(TCLCOPYTARGET)

DOCKERARCH=amd64
LAMBDAARCH=x86_64
REV=latest
lambda_builder:
	docker buildx build $(BUILDER) $(PLATFORM) --push \
		--target		lambda-builder \
		--build-arg		"DIST=$(DIST)" \
		--build-arg		TCLCOPYTARGET=optimized \
		--build-arg		"TARGETARCH=$(DOCKERARCH)" \
		-t				"$(shell aws cloudformation describe-stacks --stack-name lambda-builder-ecr --query "Stacks[0].Outputs[?OutputKey=='RepositoryUri'].OutputValue" --output text):$(DIST)-$(LAMBDAARCH)-$(REV)" \
		--platform		linux/$(DOCKERARCH) \
		--provenance=false \
		--output type=image,push=true,oci-mediatypes=false \
		.

# ------------------------------------------------------------------------
# pkgrepo: package-hosting stack and tooling. Two CFN stacks:
#
#   alpine-tcl-pkgrepo-bootstrap   (us-east-1)  — ECR repo for the index
#                                                 lambda. Created first
#                                                 so the image can be
#                                                 pushed before the main
#                                                 stack references it.
#   alpine-tcl-pkgrepo              (us-east-1)  — S3 + CloudFront + ACM
#                                                 cert + Route53 alias +
#                                                 SecretsManager signing
#                                                 secret + index lambda.
#
# us-east-1 is required: CloudFront's ACM cert lives in us-east-1, the
# Lambda must share the region of the ECR image it pulls, and S3+the
# Lambda+the secret are co-located for latency.
#
# Targets:
#   pkgrepo_bootstrap         - deploy the bootstrap (ECR) stack
#   pkgrepo_index_lambda      - build+push the index image (auto-finds
#                               the ECR URI from bootstrap stack)
#   pkgrepo_deploy            - deploy the main stack (auto-finds the
#                               image URI; needs DOMAIN + HOSTED_ZONE_ID
#                               on first deploy only — CFN remembers
#                               them on subsequent re-deploys)
#   pkgrepo_init_signing_key  - one-shot: generate an RSA-4096 keypair
#                               and seed the SecretsManager secret.
#                               Refuses if the secret already has a
#                               value (signing key loss = repo break).
#   pkgrepo_apk               - build a signed .apk locally
#   pkgrepo_apk_upload        - upload .apk(s) to S3 (triggers index)
#
# All targets auto-discover whatever they need from stack outputs; the
# only inputs you ever supply are DOMAIN + HOSTED_ZONE_ID (once, at
# first deploy), VER, and arch flags.
PKGREPO_BOOTSTRAP_STACK ?= alpine-tcl-pkgrepo-bootstrap
PKGREPO_STACK           ?= alpine-tcl-pkgrepo
PKGREPO_REGION          ?= us-east-1
SIGNING_KEY_NAME        ?= cftcl.rsa
PKGNAME                 ?= cftcl
PKGREL                  ?= 0
# Alpine spells arm as aarch64; LAMBDAARCH is AWS-style (arm64). Translate.
APK_ARCH                ?= $(if $(filter arm64,$(LAMBDAARCH)),aarch64,$(LAMBDAARCH))

# Shell snippet expanded by targets that need to read a stack output.
# Usage: $(call cfn_output,<stack>,<output-key>)
cfn_output = $$(aws cloudformation describe-stacks --region $(PKGREPO_REGION) \
	--stack-name $(1) \
	--query "Stacks[0].Outputs[?OutputKey=='$(2)'].OutputValue" \
	--output text)

pkgrepo_bootstrap:
	cd bld/sam/pkgrepo/bootstrap && \
	sam deploy --no-confirm-changeset

pkgrepo_index_lambda: Dockerfile bld/sam/pkgrepo/index_builder/bootstrap.sh bld/sam/pkgrepo/index_builder/handler.sh
	@repo=$(call cfn_output,$(PKGREPO_BOOTSTRAP_STACK),RepositoryUri); \
	test -n "$$repo" || { echo "bootstrap stack has no RepositoryUri — run 'make pkgrepo_bootstrap' first"; exit 1; }; \
	echo "pushing to $$repo:pkgrepo-index-$(LAMBDAARCH)-$(VER)"; \
	aws ecr get-login-password --region $(PKGREPO_REGION) \
		| docker login --username AWS --password-stdin $${repo%%/*}; \
	docker buildx build --push \
		--target		pkgrepo-index-lambda \
		--platform		linux/$(DOCKERARCH) \
		--provenance=false \
		--output		type=image,push=true,oci-mediatypes=false \
		-t				"$$repo:pkgrepo-index-$(LAMBDAARCH)-$(VER)" \
		.

pkgrepo_deploy:
	@repo=$(call cfn_output,$(PKGREPO_BOOTSTRAP_STACK),RepositoryUri); \
	test -n "$$repo" || { echo "bootstrap stack has no RepositoryUri — run 'make pkgrepo_bootstrap' first"; exit 1; }; \
	image="$$repo:pkgrepo-index-$(LAMBDAARCH)-$(VER)"; \
	stack_exists=0; \
	aws cloudformation describe-stacks --region $(PKGREPO_REGION) --stack-name $(PKGREPO_STACK) >/dev/null 2>&1 && stack_exists=1; \
	if [ $$stack_exists -eq 0 ] && { [ -z "$(DOMAIN)" ] || [ -z "$(HOSTED_ZONE_ID)" ]; }; then \
		echo "first deploy needs DOMAIN=... HOSTED_ZONE_ID=..."; exit 1; \
	fi; \
	cd bld/sam/pkgrepo && \
	sam deploy --no-confirm-changeset \
		--image-repository "$$repo" \
		--parameter-overrides \
			IndexLambdaImageUri="$$image" \
			IndexLambdaArchitecture=$(LAMBDAARCH) \
			SigningKeyName=$(SIGNING_KEY_NAME) \
			ApkRepoBranch=v1 \
			$(if $(DOMAIN),DomainName=$(DOMAIN)) \
			$(if $(HOSTED_ZONE_ID),HostedZoneId=$(HOSTED_ZONE_ID))

pkgrepo_init_signing_key:
	@secret=$(call cfn_output,$(PKGREPO_STACK),SigningSecretArn); \
	test -n "$$secret" || { echo "main stack not deployed — run 'make pkgrepo_deploy' first"; exit 1; }; \
	current=$$(aws secretsmanager get-secret-value --region $(PKGREPO_REGION) \
		--secret-id "$$secret" --query SecretString --output text 2>/dev/null || true); \
	if [ -n "$$current" ] && [ "$$current" != "null" ] && echo "$$current" | jq -e '.private_key | length > 0' >/dev/null 2>&1; then \
		echo "secret $$secret already has a signing key — REFUSING TO OVERWRITE"; \
		echo "(losing the existing key bricks every client that installed the old pubkey.)"; \
		exit 1; \
	fi; \
	tmp=$$(mktemp -d) && trap "shred -u $$tmp/* 2>/dev/null; rmdir $$tmp" EXIT; \
	openssl genrsa -out "$$tmp/priv.pem" 4096 2>/dev/null; \
	openssl rsa -in "$$tmp/priv.pem" -pubout -out "$$tmp/pub.pem" 2>/dev/null; \
	aws secretsmanager put-secret-value --region $(PKGREPO_REGION) \
		--secret-id "$$secret" \
		--secret-string "$$(jq -n \
			--arg name "$(SIGNING_KEY_NAME)" \
			--arg priv "$$(cat $$tmp/priv.pem)" \
			--arg pub  "$$(cat $$tmp/pub.pem)" \
			'{name:$$name, private_key:$$priv, public_key:$$pub}')" \
		>/dev/null; \
	echo "seeded $$secret with a fresh RSA-4096 keypair as $(SIGNING_KEY_NAME)"

pkgrepo_apk: Dockerfile tools/build_apk.tcl
	@test -d "$(HOME)/.aws" || { echo "no $(HOME)/.aws — aws cli credentials must be configured locally"; exit 1; }
	docker buildx build --load --provenance=false \
		$(BUILDER) \
		--build-arg		"TCLCOPYTARGET=$(TCLCOPYTARGET)" \
		--build-arg		"DIST=alpine" \
		--build-arg		"TCLVER=$(TCLVER)" \
		--build-arg		"TCLROOT=$(DESTDIR)" \
		--target package-apk-prep \
		--platform linux/$(DOCKERARCH) \
		-t pkgrepo-apk-prep:$(VER)-$(LAMBDAARCH) \
		. \
	&& docker run --rm \
		-v "$(HOME)/.aws:/root/.aws:ro" \
		-v "$(CURDIR)/bld/pkgrepo-out:/host-out" \
		-e PKGREPO_STACK="$(PKGREPO_STACK)" \
		-e VER="$(VER)" \
		-e PKGREL="$(PKGREL)" \
		-e PKGNAME="$(PKGNAME)" \
		-e AWS_REGION="$(PKGREPO_REGION)" \
		-e TCLROOT="$(DESTDIR)" \
		-e REPO_BUCKET="$(call cfn_output,$(PKGREPO_STACK),BucketName)" \
		$(if $(AWS_PROFILE),-e AWS_PROFILE="$(AWS_PROFILE)") \
		--platform linux/$(DOCKERARCH) \
		--entrypoint /bootstrap/bin/tclsh \
		pkgrepo-apk-prep:$(VER)-$(LAMBDAARCH) \
		/var/task/build_apk.tcl

#pkgrepo_apk_upload: pkgrepo_apk
#	@bucket=$(call cfn_output,$(PKGREPO_STACK),BucketName); \
#	test -n "$$bucket" || { echo "main stack not deployed"; exit 1; }; \
#	dist=$(call cfn_output,$(PKGREPO_STACK),DistributionId); \
#	for f in bld/pkgrepo-out/*.apk; do \
#		echo "uploading $$f -> s3://$$bucket/alpine/v1/$(APK_ARCH)/" ; \
#		aws s3 cp --region $(PKGREPO_REGION) "$$f" \
#			"s3://$$bucket/alpine/v1/$(APK_ARCH)/" \
#			--content-type application/octet-stream ; \
#	done; \
#	if [ -n "$$dist" ]; then \
#		echo "invalidating CloudFront cache for /alpine/v1/$(APK_ARCH)/*"; \
#		aws cloudfront create-invalidation --distribution-id "$$dist" \
#			--paths "/alpine/v1/$(APK_ARCH)/*" \
#			--query 'Invalidation.Id' --output text; \
#	fi

# ---- cftcl-release stack ---------------------------------------------------
# Single stack at the project root (template.json) — supersedes the
# alpine-tcl-pkgrepo stack. CodeBuild does the per-arch build + sign +
# upload + APKINDEX regen + CF invalidate; tag-push webhook drives it.

RELEASE_STACK              ?= cftcl-release
RELEASE_REGION             ?= us-east-1
RELEASE_BUILDER_IMAGE_TAG  ?= latest

# release_cfn_output mirrors cfn_output but targets RELEASE_REGION.
# Usage: $(call release_cfn_output,<stack>,<output-key>)
release_cfn_output = $$(aws cloudformation describe-stacks --region $(RELEASE_REGION) \
	--stack-name $(1) \
	--query "Stacks[0].Outputs[?OutputKey=='$(2)'].OutputValue" \
	--output text)

# Required on first deploy:
#   DOMAIN HOSTED_ZONE_ID CERT_ARN SIGNING_SECRET_ARN GH_OWNER GH_REPO
# Optional (template defaults used otherwise):
#   SIGNING_KEY_NAME TAG_PATTERN RELEASE_BUILDER_IMAGE_TAG ENABLE_WEBHOOKS
# Subsequent deploys reuse previous parameter values.
# ENABLE_WEBHOOKS must stay unset/false until the GitHub connection is
# authorized (make release_authorize_github), then redeploy with
# ENABLE_WEBHOOKS=true to create the tag-push webhooks.
release_deploy: template.json
	@stack_exists=0; \
	aws cloudformation describe-stacks --region $(RELEASE_REGION) --stack-name $(RELEASE_STACK) >/dev/null 2>&1 && stack_exists=1; \
	if [ $$stack_exists -eq 0 ]; then \
		missing=; \
		for v in DOMAIN HOSTED_ZONE_ID CERT_ARN SIGNING_SECRET_ARN GH_OWNER GH_REPO; do \
			eval "val=\$$$$v"; \
			[ -z "$$val" ] && missing="$$missing $$v"; \
		done; \
		if [ -n "$$missing" ]; then echo "first deploy requires:$$missing"; exit 1; fi; \
	fi; \
	sam deploy --no-confirm-changeset --no-fail-on-empty-changeset \
		--stack-name $(RELEASE_STACK) \
		--region $(RELEASE_REGION) \
		--template-file template.json \
		--capabilities CAPABILITY_IAM \
		--parameter-overrides \
			SigningKeyName=$(SIGNING_KEY_NAME) \
			ApkRepoBranch=v1 \
			BuilderImageTag=$(RELEASE_BUILDER_IMAGE_TAG) \
			$(if $(DOMAIN),DomainName=$(DOMAIN)) \
			$(if $(HOSTED_ZONE_ID),HostedZoneId=$(HOSTED_ZONE_ID)) \
			$(if $(CERT_ARN),AcmCertificateArn=$(CERT_ARN)) \
			$(if $(SIGNING_SECRET_ARN),SigningSecretArn=$(SIGNING_SECRET_ARN)) \
			$(if $(GH_OWNER),GitHubOwner=$(GH_OWNER)) \
			$(if $(GH_REPO),GitHubRepo=$(GH_REPO)) \
			$(if $(TAG_PATTERN),TagPattern=$(TAG_PATTERN)) \
			$(if $(ENABLE_WEBHOOKS),EnableWebhooks=$(ENABLE_WEBHOOKS)) \
			$(if $(COMPUTE_TYPE),BuildComputeType=$(COMPUTE_TYPE))

# Build the Alpine-based CodeBuild env image, push one per-arch tag.
# CodeBuild references <repo>:$(RELEASE_BUILDER_IMAGE_TAG).
release_builder_images: builder/Dockerfile
	@x86_uri=$(call release_cfn_output,$(RELEASE_STACK),BuilderRepoX86Uri); \
	arm_uri=$(call release_cfn_output,$(RELEASE_STACK),BuilderRepoArm64Uri); \
	test -n "$$x86_uri" || { echo "release stack not deployed — run 'make release_deploy' first"; exit 1; }; \
	registry=$${x86_uri%%/*}; \
	echo "logging into $$registry"; \
	aws ecr get-login-password --region $(RELEASE_REGION) \
		| docker login --username AWS --password-stdin "$$registry"; \
	echo "building + pushing $$x86_uri:$(RELEASE_BUILDER_IMAGE_TAG)"; \
	docker buildx build --platform linux/amd64 --push \
		-t "$$x86_uri:$(RELEASE_BUILDER_IMAGE_TAG)" builder; \
	echo "building + pushing $$arm_uri:$(RELEASE_BUILDER_IMAGE_TAG)"; \
	docker buildx build --platform linux/arm64 --push \
		-t "$$arm_uri:$(RELEASE_BUILDER_IMAGE_TAG)" builder

# CodeConnections::Connection deploys in PENDING state; the OAuth handshake
# can only happen interactively. Print the console URL to click once.
release_authorize_github:
	@arn=$(call release_cfn_output,$(RELEASE_STACK),GitHubConnectionArn); \
	test -n "$$arn" || { echo "release stack not deployed"; exit 1; }; \
	echo "Open this URL in a browser and complete the GitHub OAuth handshake:"; \
	echo "  https://$(RELEASE_REGION).console.aws.amazon.com/codesuite/settings/connections/redirect?connectionArn=$$arn"

# Manual trigger (e.g. retry a release without re-pushing the tag).
# Reads VER from the Makefile to set the source-version.
release_trigger_x86:
	@name=$(call release_cfn_output,$(RELEASE_STACK),BuildX86Name); \
	test -n "$$name" || { echo "release stack not deployed"; exit 1; }; \
	echo "starting build for $$name @ refs/tags/$(VER)"; \
	aws codebuild start-build --region $(RELEASE_REGION) \
		--project-name "$$name" \
		--source-version "refs/tags/$(VER)" \
		--query 'build.id' --output text

release_trigger_arm64:
	@name=$(call release_cfn_output,$(RELEASE_STACK),BuildArm64Name); \
	test -n "$$name" || { echo "release stack not deployed"; exit 1; }; \
	echo "starting build for $$name @ refs/tags/$(VER)"; \
	aws codebuild start-build --region $(RELEASE_REGION) \
		--project-name "$$name" \
		--source-version "refs/tags/$(VER)" \
		--query 'build.id' --output text

# Sync the static landing page to the release bucket. Currently sources
# from bld/sam/pkgrepo/site/ — move when the old pkgrepo tree is retired.
release_site_upload:
	@bucket=$(call release_cfn_output,$(RELEASE_STACK),BucketName); \
	test -n "$$bucket" || { echo "release stack not deployed"; exit 1; }; \
	dist=$(call release_cfn_output,$(RELEASE_STACK),DistributionId); \
	aws s3 sync --region $(RELEASE_REGION) \
		bld/sam/pkgrepo/site/ "s3://$$bucket/" \
		--exclude 'alpine/*' --exclude 'deb/*' --exclude 'rpm/*' --exclude 'zip/*' \
		--cache-control "public, max-age=300" \
		--delete; \
	if [ -n "$$dist" ]; then \
		aws cloudfront create-invalidation --distribution-id "$$dist" \
			--paths '/index.html' '/' --query 'Invalidation.Id' --output text; \
	fi

clean:
	-rm -r aws-lambda-rie-arm64 aws-lamda-rie-x86_64

.PHONY: alpine-tcl alpine-tcl-gdb m2 package_report upload gdb clean \
	lambdatest-arm64 lambdatest-amd64 copy_build \
	pkgrepo_bootstrap pkgrepo_index_lambda pkgrepo_deploy \
	pkgrepo_init_signing_key pkgrepo_apk pkgrepo_apk_upload \
	release_deploy release_builder_images release_authorize_github \
	release_trigger_x86 release_trigger_arm64 release_site_upload
